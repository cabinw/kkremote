package com.kkremote.android.gesture

import kotlin.math.abs
import kotlin.math.hypot

data class TouchPoint(val x: Float, val y: Float)

data class TouchDelta(val dx: Float, val dy: Float)

data class TouchContact(val id: Int, val point: TouchPoint)

sealed interface GestureAction {
    data class Tap(val point: TouchPoint) : GestureAction
    data class SecondaryClick(val point: TouchPoint) : GestureAction
    data class RelativeMove(val delta: TouchDelta) : GestureAction
    data class ScrollBegan(val origin: TouchPoint) : GestureAction
    data class Scroll(val delta: TouchDelta) : GestureAction
    data object ScrollEnded : GestureAction
    data class Pan(val delta: TouchDelta) : GestureAction
    data class Zoom(val factor: Float, val anchor: TouchPoint) : GestureAction
    data object Cancel : GestureAction
}

/**
 * Deterministic multi-touch gesture arbitrator ported from KKRemote's iOS InteractionGestureMachine.
 * Once two fingers commit to pinch-zoom or scroll, that intent stays locked until all fingers lift,
 * preventing pinch-zoom from leaking unintended remote scroll events.
 */
class InteractionGestureMachine(
    var directScroll: Boolean = true,
    var relativeTrackpad: Boolean = false,
    var panInspectMode: Boolean = false,
    private val touchSlopPx: Float = 16f,
    private val longPressSeconds: Double = 0.40,
) {
    private enum class TwoFingerIntent { PENDING, SCROLL, ZOOM, PAN }

    private var initial: List<TouchContact> = emptyList()
    private var last: List<TouchContact> = emptyList()
    private var beganAtSeconds: Double = 0.0
    private var moved: Boolean = false
    private var scrolling: Boolean = false
    private var suppressed: Boolean = false
    private var intent: TwoFingerIntent = TwoFingerIntent.PENDING

    fun update(contacts: List<TouchContact>, timeSeconds: Double): List<GestureAction> {
        val points = contacts.sortedBy { it.id }
        if (points.isEmpty()) {
            val wasSuppressed = suppressed
            val prevInitial = initial
            val prevScrolling = scrolling
            val prevIntent = intent
            val prevMoved = moved
            val heldSeconds = timeSeconds - beganAtSeconds
            clear()
            if (wasSuppressed) return emptyList()
            if (prevInitial.size == 2) {
                return if (prevIntent == TwoFingerIntent.SCROLL) listOf(GestureAction.ScrollEnded) else emptyList()
            }
            if (prevScrolling) return listOf(GestureAction.ScrollEnded)
            val start = prevInitial.firstOrNull() ?: return emptyList()
            if (prevMoved) return emptyList()
            return listOf(
                if (heldSeconds >= longPressSeconds) GestureAction.SecondaryClick(start.point)
                else GestureAction.Tap(start.point)
            )
        }

        if (suppressed) return emptyList()
        if (points.size > 2) return cancel()

        if (initial.isEmpty()) {
            initial = points
            last = points
            beganAtSeconds = timeSeconds
            return emptyList()
        }

        if (initial.size == 1 && points.size == 2) {
            val events = if (scrolling) listOf(GestureAction.ScrollEnded) else emptyList()
            scrolling = false
            initial = points
            last = points
            intent = TwoFingerIntent.PENDING
            return events
        }

        if (initial.size == 2 && points.size == 1) {
            suppressed = true
            return if (intent == TwoFingerIntent.SCROLL) listOf(GestureAction.ScrollEnded) else emptyList()
        }

        if (points.map { it.id } != initial.map { it.id }) return cancel()

        val previous = last
        last = points

        if (points.size == 1) {
            val origin = initial[0].point
            val current = points[0].point
            val prev = previous[0].point
            val dist = hypot(current.x - origin.x, current.y - origin.y)
            if (dist > touchSlopPx && !moved) {
                moved = true
            }
            if (!moved) return emptyList()

            if (panInspectMode) {
                return listOf(GestureAction.Pan(delta(current, prev)))
            }
            if (relativeTrackpad) {
                return listOf(GestureAction.RelativeMove(delta(current, prev)))
            }
            if (directScroll) {
                if (scrolling) {
                    return listOf(GestureAction.Scroll(delta(current, prev)))
                }
                scrolling = true
                return listOf(GestureAction.ScrollBegan(origin), GestureAction.Scroll(delta(current, origin)))
            }
            return emptyList()
        }

        // Two-finger arbitration: Zoom vs Scroll/Pan
        val center = midpoint(points)
        val oldCenter = midpoint(previous)
        val startCenter = midpoint(initial)
        val startSep = maxOf(1f, separation(initial))
        val curSep = maxOf(1f, separation(points))
        val prevSep = maxOf(1f, separation(previous))

        if (intent == TwoFingerIntent.PENDING) {
            if (abs(curSep / startSep - 1f) > 0.08f) {
                intent = TwoFingerIntent.ZOOM
                return listOf(
                    GestureAction.Zoom(curSep / startSep, startCenter),
                    GestureAction.Pan(delta(center, startCenter)),
                )
            }
            if (hypot(center.x - startCenter.x, center.y - startCenter.y) > touchSlopPx * 1.1f) {
                return if (panInspectMode) {
                    intent = TwoFingerIntent.PAN
                    listOf(GestureAction.Pan(delta(center, startCenter)))
                } else {
                    intent = TwoFingerIntent.SCROLL
                    listOf(GestureAction.ScrollBegan(startCenter), GestureAction.Scroll(delta(center, startCenter)))
                }
            }
            return emptyList()
        }

        return when (intent) {
            TwoFingerIntent.ZOOM -> listOf(
                GestureAction.Zoom(curSep / prevSep, oldCenter),
                GestureAction.Pan(delta(center, oldCenter)),
            )
            TwoFingerIntent.PAN -> listOf(GestureAction.Pan(delta(center, oldCenter)))
            TwoFingerIntent.SCROLL -> listOf(GestureAction.Scroll(delta(center, oldCenter)))
            TwoFingerIntent.PENDING -> emptyList()
        }
    }

    fun cancel(): List<GestureAction> {
        clear()
        suppressed = true
        return listOf(GestureAction.Cancel)
    }

    fun reset() {
        clear()
    }

    private fun clear() {
        initial = emptyList()
        last = emptyList()
        moved = false
        scrolling = false
        suppressed = false
        intent = TwoFingerIntent.PENDING
    }

    private fun midpoint(pts: List<TouchContact>): TouchPoint =
        TouchPoint((pts[0].point.x + pts[1].point.x) * 0.5f, (pts[0].point.y + pts[1].point.y) * 0.5f)

    private fun separation(pts: List<TouchContact>): Float =
        hypot(pts[0].point.x - pts[1].point.x, pts[0].point.y - pts[1].point.y)

    private fun delta(cur: TouchPoint, prev: TouchPoint): TouchDelta =
        TouchDelta(cur.x - prev.x, cur.y - prev.y)
}
