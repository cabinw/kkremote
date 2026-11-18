package com.kkremote.android

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.luminance
import com.kkremote.android.ui.DeckGeometry
import com.kkremote.android.ui.KeyHaptic
import com.kkremote.android.ui.KeyId
import com.kkremote.android.ui.KeyRef
import com.kkremote.android.ui.KeySpec
import com.kkremote.android.ui.MacKeyCode
import com.kkremote.android.ui.ModifierLatchMode
import com.kkremote.android.ui.OmniKeyTouchEngine
import com.kkremote.android.ui.OmniKeyboardTheme
import com.kkremote.android.ui.OmniMacLayouts
import com.kkremote.android.ui.OmniModifier
import com.kkremote.android.ui.OmniModifierController
import com.kkremote.android.ui.compactRows
import com.kkremote.android.ui.skin
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class OmniKeyboardEngineTest {

    private val rows = OmniMacLayouts.compactRows
    private fun ref(r: Int, c: Int) = KeyRef(KeyId(0, r, c), rows[r][c])
    private fun keyOf(code: Int): KeyRef {
        rows.forEachIndexed { r, row ->
            row.forEachIndexed { c, spec ->
                if (spec is KeySpec.CharOrAction && spec.keyCode == code) return ref(r, c)
            }
        }
        error("missing $code")
    }
    private fun modOf(tag: String): KeyRef {
        rows.forEachIndexed { r, row -> row.forEachIndexed { c, spec -> if (spec.tag == tag) return ref(r, c) } }
        error("missing $tag")
    }

    private class Harness {
        var now = 1_000L
        var enabled = true
        val sent = mutableListOf<Pair<Int, List<String>>>()
        val haptics = mutableListOf<KeyHaptic>()
        var imeToggles = 0
        val controller = OmniModifierController()
        val engine = OmniKeyTouchEngine(
            modifiers = controller,
            clock = { now },
            isEnabled = { enabled },
            sendKey = { code, mods -> sent += code to mods },
            toggleInputSource = { imeToggles++ },
            toggleLayer = {},
            haptic = { haptics += it },
            onChanged = {},
        ).apply {
            cursorStartPx = 20f
            cursorStepPx = 10f
        }
    }

    @Test
    fun geometryHitTestIsGaplessAndPicksNearestKey() {
        val g = DeckGeometry(0, rows, widthPx = 1000f, heightPx = 500f, hGapPx = 10f, vGapPx = 10f)
        // Every sampled point resolves to some key: no dead zones between caps or at edges.
        var y = -5f
        while (y <= 505f) {
            var x = -5f
            while (x <= 1005f) {
                val hit = g.hit(Offset(x, y))
                assertTrue("no key at $x,$y", hit != null)
                x += 3f
            }
            y += 3f
        }
        // A point in the gap just right of Q resolves to Q, just left of W resolves to W.
        val q = g.rects[1][1]
        val w = g.rects[1][2]
        assertEquals(KeyId(0, 1, 1), g.hit(Offset(q.right + 4f, q.center.y))!!.id)
        assertEquals(KeyId(0, 1, 2), g.hit(Offset(w.left - 4f, w.center.y))!!.id)
        // Vertical gap splits at the midpoint between rows.
        val a = g.rects[2][1]
        assertEquals(2, g.hit(Offset(a.center.x, a.top - 4f))!!.id.row)
        assertEquals(1, g.hit(Offset(a.center.x, a.top - 6f))!!.id.row)
        // Rows are justified to the full deck width.
        for (rowRects in g.rects) assertEquals(1000f, rowRects.last().right, 0.5f)
    }

    @Test
    fun characterCommitsOnReleaseAndSlideCorrects() {
        val h = Harness()
        h.engine.onDown(1, keyOf(MacKeyCode.F), 0f)
        assertTrue("nothing sent on touch-down", h.sent.isEmpty())
        h.engine.onMove(1, keyOf(MacKeyCode.G), 5f)
        h.engine.onUp(1)
        assertEquals(listOf(MacKeyCode.G to emptyList<String>()), h.sent)
        assertTrue(h.haptics.contains(KeyHaptic.TICK))
    }

    @Test
    fun rolloverPreservesTypingOrder() {
        val h = Harness()
        h.engine.onDown(1, keyOf(MacKeyCode.T), 0f)
        h.engine.onDown(2, keyOf(MacKeyCode.H), 0f) // second thumb lands before first lifts
        h.engine.onUp(1)
        h.engine.onDown(3, keyOf(MacKeyCode.E), 0f)
        h.engine.onUp(2)
        h.engine.onUp(3)
        assertEquals(listOf(MacKeyCode.T, MacKeyCode.H, MacKeyCode.E), h.sent.map { it.first })
    }

    @Test
    fun sloppyChordStillCarriesModifier() {
        val h = Harness()
        val cmd = modOf("mod_cmd_l")
        h.engine.onDown(1, cmd, 0f)
        h.engine.onDown(2, keyOf(MacKeyCode.C), 0f)
        h.now += 120
        h.engine.onUp(1) // ⌘ released first
        h.engine.onUp(2)
        assertEquals(listOf(MacKeyCode.C to listOf("cmd")), h.sent)
        assertEquals(ModifierLatchMode.OFF, h.controller.modeOf(OmniModifier.CMD))
    }

    @Test
    fun repeatableKeysFireImmediatelyAndRepeat() {
        val h = Harness()
        val needsRepeat = h.engine.onDown(1, keyOf(MacKeyCode.DELETE), 0f)
        assertTrue(needsRepeat)
        assertEquals(1, h.sent.size)
        assertTrue(h.engine.onRepeat(1))
        assertTrue(h.engine.onRepeat(1))
        h.engine.onUp(1)
        assertFalse(h.engine.onRepeat(1))
        assertEquals(3, h.sent.size)
        assertTrue(h.sent.all { it.first == MacKeyCode.DELETE })
    }

    @Test
    fun spaceDragBecomesCursorStripWithHeldShiftSelection() {
        val h = Harness()
        val shift = modOf("mod_shift_l")
        h.engine.onDown(9, shift, 0f) // hold ⇧ with the other thumb
        h.engine.onDown(1, keyOf(MacKeyCode.SPACE), 100f)
        h.engine.onMove(1, keyOf(MacKeyCode.SPACE), 115f) // below start threshold
        assertTrue(h.sent.isEmpty())
        h.engine.onMove(1, keyOf(MacKeyCode.SPACE), 125f) // enters cursor mode, anchor = 125
        h.engine.onMove(1, keyOf(MacKeyCode.SPACE), 147f) // 2 steps right, anchor = 145
        h.engine.onMove(1, keyOf(MacKeyCode.SPACE), 124f) // 2 steps back left, anchor = 125
        h.engine.onUp(1)
        h.engine.onUp(9)
        assertEquals(
            listOf(MacKeyCode.RIGHT, MacKeyCode.RIGHT, MacKeyCode.LEFT, MacKeyCode.LEFT),
            h.sent.map { it.first },
        )
        assertTrue(h.sent.all { it.second == listOf("shift") })
        assertFalse("no space typed after a cursor drag", h.sent.any { it.first == MacKeyCode.SPACE })
    }

    @Test
    fun spaceTapStillTypesSpace() {
        val h = Harness()
        h.engine.onDown(1, keyOf(MacKeyCode.SPACE), 100f)
        h.engine.onMove(1, keyOf(MacKeyCode.SPACE), 104f)
        h.engine.onUp(1)
        assertEquals(listOf(MacKeyCode.SPACE), h.sent.map { it.first })
    }

    @Test
    fun inputSourceToggleCancelsWhenFingerSlidesOff() {
        val h = Harness()
        val ime = rows[2].indexOfFirst { it is KeySpec.InputSourceKey }.let { ref(2, it) }
        h.engine.onDown(1, ime, 0f)
        h.engine.onUp(1)
        assertEquals(1, h.imeToggles)
        h.engine.onDown(2, ime, 0f)
        h.engine.onMove(2, keyOf(MacKeyCode.A), 30f)
        h.engine.onUp(2)
        assertEquals(1, h.imeToggles)
    }

    @Test
    fun disabledKeyboardSendsNothingAndLockedModifierHapticConfirms() {
        val h = Harness()
        h.enabled = false
        h.engine.onDown(1, keyOf(MacKeyCode.A), 0f)
        h.engine.onUp(1)
        assertTrue(h.sent.isEmpty())

        val shift = modOf("mod_shift_l")
        h.engine.onDown(2, shift, 0f); h.now += 40; h.engine.onUp(2)
        h.now += 100
        h.engine.onDown(3, shift, 0f); h.now += 40; h.engine.onUp(3)
        assertEquals(ModifierLatchMode.LOCKED, h.controller.modeOf(OmniModifier.SHIFT))
        assertTrue(h.haptics.contains(KeyHaptic.CONFIRM))
    }

    @Test
    fun themesMapToDistinctSkinsAndSerialiseByName() {
        val graphite = OmniKeyboardTheme.GRAPHITE.skin()
        val mech = OmniKeyboardTheme.MECHANICAL_LIGHT.skin()
        assertFalse(graphite.mechanical)
        assertTrue(mech.mechanical)
        // Light skin: dark legends on light caps, light tray.
        assertTrue(mech.letter.faceBottom.luminance() > 0.8f)
        assertTrue(mech.letter.legend.luminance() < 0.1f)
        assertTrue(graphite.trayBottom.luminance() < 0.05f)
        val json = Json.encodeToString(OmniKeyboardTheme.MECHANICAL_LIGHT)
        assertEquals("\"MECHANICAL_LIGHT\"", json)
        assertEquals(OmniKeyboardTheme.MECHANICAL_LIGHT, Json.decodeFromString<OmniKeyboardTheme>(json))
    }

    @Test
    fun thumbSplitHalvesAreMirroredSoGAndHAreEquidistantFromTheirEdges() {
        val left = OmniMacLayouts.splitLeftRows
        val right = OmniMacLayouts.splitRightRows
        for (rows in listOf(left, right, OmniMacLayouts.splitLeftSymbolRows, OmniMacLayouts.splitRightSymbolRows)) {
            assertEquals(5, rows.size)
            // Ortholinear 6-unit rows: every column lines up and no row is stretched.
            for (row in rows) assertEquals(6f, row.sumOf { it.weight.toDouble() }.toFloat(), 0.001f)
        }
        val unit = 50f
        val gl = DeckGeometry(0, left, widthPx = 6 * unit, heightPx = 250f, hGapPx = 6f, vGapPx = 6f)
        val gr = DeckGeometry(1, right, widthPx = 6 * unit, heightPx = 250f, hGapPx = 6f, vGapPx = 6f)
        fun rectOf(g: DeckGeometry, rows: List<List<KeySpec>>, code: Int) = rows.withIndex().firstNotNullOf { (r, row) ->
            row.indexOfFirst { it is KeySpec.CharOrAction && it.keyCode == code }.takeIf { it >= 0 }?.let { g.rects[r][it] }
        }
        val g = rectOf(gl, left, MacKeyCode.G)
        val h = rectOf(gr, right, MacKeyCode.H)
        val distG = g.center.x // from the left screen edge
        val distH = gr.widthPx - h.center.x // from the right screen edge
        assertEquals(distG, distH, 0.5f)
        assertEquals(g.center.y, h.center.y, 0.5f)
        // Same for the other inner columns (T/Y, B/N).
        assertEquals(rectOf(gl, left, MacKeyCode.T).center.x, gr.widthPx - rectOf(gr, right, MacKeyCode.Y).center.x, 0.5f)
        assertEquals(rectOf(gl, left, MacKeyCode.B).center.x, gr.widthPx - rectOf(gr, right, MacKeyCode.N).center.x, 0.5f)
    }

    @Test
    fun thumbSplitUnitStaysThumbSizedOnWideScreensAndLeavesCentreForTrackpad() {
        val wide = com.kkremote.android.ui.ThumbSplitMetrics.unit(androidx.compose.ui.unit.Dp(1100f))
        assertEquals(50f, wide.value, 0.01f) // capped: halves do not stretch on tablets
        val foldable = com.kkremote.android.ui.ThumbSplitMetrics.unit(androidx.compose.ui.unit.Dp(840f))
        assertTrue(foldable.value in 44f..50f)
        assertTrue(840f - foldable.value * 12 >= 120f) // centre trackpad still fits
    }

    @Test
    fun comboAndSymbolKeysCarryForcedModifiers() {
        val h = Harness()
        val voiceRows = OmniMacLayouts.voiceLeftRows + OmniMacLayouts.voiceRightRows
        val undo = voiceRows.flatten().first { it.tag == "voice_undo" }
        val redo = voiceRows.flatten().first { it.tag == "voice_redo" }
        h.engine.onDown(1, KeyRef(KeyId(0, 0, 1), undo), 0f); h.engine.onUp(1)
        h.engine.onDown(2, KeyRef(KeyId(0, 0, 2), redo), 0f); h.engine.onUp(2)
        assertEquals(MacKeyCode.Z to listOf("cmd"), h.sent[0])
        assertEquals(MacKeyCode.Z, h.sent[1].first)
        assertEquals(setOf("cmd", "shift"), h.sent[1].second.toSet())

        val brace = OmniMacLayouts.splitRightSymbolRows.flatten().first { it.tag == "sym_lbrace" }
        h.engine.onDown(3, KeyRef(KeyId(1, 1, 3), brace), 0f); h.engine.onUp(3)
        assertEquals(MacKeyCode.LEFT_BRACKET to listOf("shift"), h.sent[2])

        // A latched ⇧ plus a forced ⇧ is sent once.
        val shift = modOf("mod_shift_l")
        h.engine.onDown(4, shift, 0f); h.now += 30; h.engine.onUp(4)
        h.engine.onDown(5, KeyRef(KeyId(1, 1, 3), brace), 0f); h.engine.onUp(5)
        assertEquals(listOf("shift"), h.sent[3].second)
    }

    @Test
    fun voiceKeyReportsPressAndReleaseAndCancel() {
        val events = mutableListOf<Boolean>()
        val engine = OmniKeyTouchEngine(
            modifiers = OmniModifierController(),
            clock = { 0L },
            isEnabled = { true },
            sendKey = { _, _ -> },
            toggleInputSource = {},
            toggleLayer = {},
            haptic = {},
            onChanged = {},
            voiceKey = { events += it },
        )
        val mic = KeyRef(KeyId(1, 4, 0), OmniMacLayouts.voiceRightRows[4][0])
        assertTrue(mic.spec is KeySpec.VoiceKey)
        engine.onDown(1, mic, 0f)
        engine.onUp(1)
        engine.onDown(2, mic, 0f)
        engine.cancelAll()
        assertEquals(listOf(true, false, true, false), events)
    }

    @Test
    fun voiceDeckKeepsEditingEssentialsUnderBothThumbs() {
        val left = OmniMacLayouts.voiceLeftRows.flatten()
        val right = OmniMacLayouts.voiceRightRows.flatten()
        assertTrue(left.any { it is KeySpec.VoiceKey })
        assertTrue(right.any { it is KeySpec.VoiceKey })
        val rightCodes = right.filterIsInstance<KeySpec.CharOrAction>().map { it.keyCode }.toSet()
        assertTrue(rightCodes.containsAll(listOf(MacKeyCode.DELETE, MacKeyCode.RETURN, MacKeyCode.SPACE, MacKeyCode.LEFT, MacKeyCode.RIGHT, MacKeyCode.UP, MacKeyCode.DOWN)))
        assertTrue(left.any { it is KeySpec.InputSourceKey })
        for (rows in listOf(OmniMacLayouts.voiceLeftRows, OmniMacLayouts.voiceRightRows)) {
            for (row in rows) assertEquals(3f, row.sumOf { it.weight.toDouble() }.toFloat(), 0.001f)
        }
    }

    @Test
    fun cancelReleasesHeldModifierWithoutLatching() {
        val h = Harness()
        h.engine.onDown(1, modOf("mod_cmd_l"), 0f)
        h.engine.onDown(2, keyOf(MacKeyCode.V), 0f)
        h.engine.cancelAll()
        assertTrue(h.sent.isEmpty())
        assertEquals(ModifierLatchMode.OFF, h.controller.modeOf(OmniModifier.CMD))
        assertTrue(h.engine.pressedKeyIds().isEmpty())
    }
}
