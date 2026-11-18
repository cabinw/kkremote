package com.kkremote.android.ui

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import kotlin.math.abs

/**
 * Stable identity of one key cap inside the keyboard: (deck, row, column).
 * Split layouts own two decks that share one [OmniKeyTouchEngine].
 */
internal data class KeyId(val deck: Int, val row: Int, val col: Int)

internal data class KeyRef(val id: KeyId, val spec: KeySpec)

/**
 * Pure geometry for a justified grid of key rows.
 *
 * Every row spans the full deck width (weights are normalised per row), so the familiar Mac
 * stagger falls out of the per-key weights. Hit-testing is gapless: the boundary between two
 * neighbours sits in the middle of their gap, the outermost keys own the deck edges and the
 * first/last rows own the top/bottom margins. A thumb that lands between caps therefore always
 * resolves to the nearest key instead of being dropped.
 */
internal class DeckGeometry(
    val deck: Int,
    val rows: List<List<KeySpec>>,
    val widthPx: Float,
    val heightPx: Float,
    val hGapPx: Float,
    val vGapPx: Float,
) {
    val rowPitchPx: Float = if (rows.isEmpty()) 0f else (heightPx + vGapPx) / rows.size
    val keyHeightPx: Float = (rowPitchPx - vGapPx).coerceAtLeast(1f)
    val unitWidthPx: Float

    /** rects[row][col] in deck-local pixels. */
    val rects: List<List<Rect>>

    init {
        var minUnit = Float.MAX_VALUE
        rects = rows.mapIndexed { r, row ->
            val top = r * rowPitchPx
            val totalWeight = row.sumOf { it.weight.toDouble() }.toFloat().coerceAtLeast(0.0001f)
            val usable = (widthPx - hGapPx * (row.size - 1)).coerceAtLeast(1f)
            val unit = usable / totalWeight
            if (unit < minUnit) minUnit = unit
            var x = 0f
            row.map { spec ->
                val w = unit * spec.weight
                val rect = Rect(x, top, x + w, top + keyHeightPx)
                x += w + hGapPx
                rect
            }
        }
        unitWidthPx = if (minUnit == Float.MAX_VALUE) 0f else minUnit
    }

    fun rectOf(id: KeyId): Rect? = rects.getOrNull(id.row)?.getOrNull(id.col)

    fun hit(p: Offset): KeyRef? {
        if (rows.isEmpty()) return null
        val r = ((p.y + vGapPx * 0.5f) / rowPitchPx).toInt().coerceIn(0, rows.size - 1)
        val rowRects = rects[r]
        if (rowRects.isEmpty()) return null
        var c = rowRects.size - 1
        for (i in 0 until rowRects.size - 1) {
            if (p.x < rowRects[i].right + hGapPx * 0.5f) {
                c = i
                break
            }
        }
        return KeyRef(KeyId(deck, r, c), rows[r][c])
    }
}

internal enum class KeyHaptic { TAP, TICK, CONFIRM, TOGGLE }

/**
 * Multi-touch keyboard behaviour, independent of Compose so it can be unit tested.
 *
 * - Character keys light up on touch-down and commit on release with the key currently under
 *   the finger, so a near-miss can be corrected by sliding before lifting.
 * - Rollover: a new touch-down commits every still-pending character first, preserving the
 *   order of fast two-thumb typing.
 * - Repeatable keys (⌫, arrows) fire immediately on touch-down and auto-repeat via [onRepeat].
 * - Space-bar trackpad: dragging horizontally on Space turns it into a cursor strip that emits
 *   ←/→ steps (held ⇧ selects). Releasing after a drag never types a space.
 * - Releasing a modifier first commits characters pressed while it was held, so a sloppy chord
 *   (⌘ down, C down, ⌘ up, C up) still delivers ⌘C.
 */
internal class OmniKeyTouchEngine(
    private val modifiers: OmniModifierController,
    private val clock: () -> Long,
    private val isEnabled: () -> Boolean,
    private val sendKey: (keyCode: Int, modifiers: List<String>) -> Unit,
    private val toggleInputSource: () -> Unit,
    private val toggleLayer: () -> Unit,
    private val haptic: (KeyHaptic) -> Unit,
    private val onChanged: () -> Unit,
) {
    var cursorStartPx: Float = 24f
    var cursorStepPx: Float = 18f

    class Touch internal constructor(
        val pointer: Long,
        val origin: KeyRef,
        var key: KeyRef,
        val downX: Float,
        var anchorX: Float,
        var committed: Boolean = false,
        var cursorMode: Boolean = false,
        var leftOrigin: Boolean = false,
        var cursorMods: List<String> = emptyList(),
    )

    private val touches = LinkedHashMap<Long, Touch>()

    val activeTouches: Collection<Touch> get() = touches.values

    fun pressedKeyIds(): Set<KeyId> = touches.values.mapTo(HashSet()) { it.key.id }

    fun isCursorDragging(): Boolean = touches.values.any { it.cursorMode }

    /** @return true when the caller should start an auto-repeat loop for this pointer. */
    fun onDown(pointer: Long, key: KeyRef, x: Float): Boolean {
        touches.remove(pointer)?.let { cancelTouch(it) }
        flushPending(exceptPointer = pointer)
        val t = Touch(pointer = pointer, origin = key, key = key, downX = x, anchorX = x)
        touches[pointer] = t
        haptic(KeyHaptic.TAP)
        var repeat = false
        when (val spec = key.spec) {
            is KeySpec.ModifierKey -> modifiers.onModifierDown(spec.modifier, clock())
            is KeySpec.CharOrAction -> if (spec.repeatable) {
                fire(spec)
                t.committed = true
                repeat = true
            }
            is KeySpec.InputSourceKey, is KeySpec.LayerToggleKey -> Unit
        }
        onChanged()
        return repeat
    }

    fun onMove(pointer: Long, key: KeyRef?, x: Float) {
        val t = touches[pointer] ?: return
        val origin = t.origin.spec
        if (origin is KeySpec.CharOrAction && origin.keyCode == MacKeyCode.SPACE && !t.committed) {
            if (!t.cursorMode && abs(x - t.downX) >= cursorStartPx) {
                t.cursorMode = true
                t.anchorX = x
                t.cursorMods = if (isEnabled()) modifiers.consumeForKeystroke() else emptyList()
                haptic(KeyHaptic.TICK)
                onChanged()
            }
            if (t.cursorMode) {
                var stepped = false
                while (x - t.anchorX >= cursorStepPx) {
                    t.anchorX += cursorStepPx
                    if (isEnabled()) sendKey(MacKeyCode.RIGHT, t.cursorMods)
                    stepped = true
                }
                while (t.anchorX - x >= cursorStepPx) {
                    t.anchorX -= cursorStepPx
                    if (isEnabled()) sendKey(MacKeyCode.LEFT, t.cursorMods)
                    stepped = true
                }
                if (stepped) haptic(KeyHaptic.TICK)
            }
            return
        }
        if (key == null || key.id == t.key.id) return
        when (origin) {
            is KeySpec.CharOrAction -> {
                if (t.committed || origin.repeatable) return
                val target = key.spec
                if (target is KeySpec.CharOrAction && !target.repeatable && target.keyCode != MacKeyCode.SPACE) {
                    t.key = key
                    haptic(KeyHaptic.TICK)
                    onChanged()
                }
            }
            is KeySpec.InputSourceKey, is KeySpec.LayerToggleKey -> {
                if (!t.leftOrigin) {
                    t.leftOrigin = true
                    onChanged()
                }
            }
            is KeySpec.ModifierKey -> Unit
        }
    }

    fun onUp(pointer: Long) {
        val t = touches[pointer] ?: return
        when (val spec = t.origin.spec) {
            is KeySpec.ModifierKey -> {
                flushPending(exceptPointer = pointer)
                touches.remove(pointer)
                modifiers.onModifierUp(spec.modifier, clock())
                if (modifiers.modeOf(spec.modifier) == ModifierLatchMode.LOCKED) haptic(KeyHaptic.CONFIRM)
            }
            is KeySpec.CharOrAction -> {
                touches.remove(pointer)
                if (!t.committed && !t.cursorMode) {
                    (t.key.spec as? KeySpec.CharOrAction)?.let(::fire)
                }
            }
            is KeySpec.InputSourceKey -> {
                touches.remove(pointer)
                if (!t.leftOrigin && isEnabled()) {
                    haptic(KeyHaptic.TOGGLE)
                    toggleInputSource()
                }
            }
            is KeySpec.LayerToggleKey -> {
                touches.remove(pointer)
                if (!t.leftOrigin) {
                    haptic(KeyHaptic.TOGGLE)
                    toggleLayer()
                }
            }
        }
        onChanged()
    }

    fun onCancel(pointer: Long) {
        val t = touches.remove(pointer) ?: return
        cancelTouch(t)
        onChanged()
    }

    /** Auto-repeat tick from the UI layer; returns false when the pointer is gone. */
    fun onRepeat(pointer: Long): Boolean {
        val t = touches[pointer] ?: return false
        val spec = t.origin.spec as? KeySpec.CharOrAction ?: return false
        if (!spec.repeatable) return false
        fire(spec)
        haptic(KeyHaptic.TAP)
        return true
    }

    fun cancelAll() {
        if (touches.isEmpty()) return
        val all = touches.values.toList()
        touches.clear()
        all.forEach(::cancelTouch)
        onChanged()
    }

    private fun cancelTouch(t: Touch) {
        val spec = t.origin.spec
        if (spec is KeySpec.ModifierKey) modifiers.onModifierUp(spec.modifier, clock(), cancelled = true)
    }

    private fun flushPending(exceptPointer: Long) {
        for (t in touches.values) {
            if (t.pointer == exceptPointer || t.committed || t.cursorMode) continue
            val spec = t.key.spec as? KeySpec.CharOrAction ?: continue
            if (spec.repeatable) continue
            t.committed = true
            fire(spec)
        }
    }

    private fun fire(spec: KeySpec.CharOrAction) {
        if (!isEnabled()) return
        val fnCode = spec.fnKeyCode
        val useFn = fnCode != null && modifiers.isActive(OmniModifier.FN)
        val code = if (useFn) fnCode!! else spec.keyCode
        val mods = modifiers.consumeForKeystroke(omitFnWireFlag = useFn)
        sendKey(code, mods)
    }
}
