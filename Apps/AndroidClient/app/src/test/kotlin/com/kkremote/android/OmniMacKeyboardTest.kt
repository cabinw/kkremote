package com.kkremote.android

import com.kkremote.android.ui.KeySpec
import com.kkremote.android.ui.MacKeyCode
import com.kkremote.android.ui.ModifierLatchMode
import com.kkremote.android.ui.OmniKeyboardStyle
import com.kkremote.android.ui.OmniMacLayouts
import com.kkremote.android.ui.OmniModifier
import com.kkremote.android.ui.OmniModifierController
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class OmniMacKeyboardTest {

    @Test
    fun macKeyCodesAreUniqueAndWithinWireProtocolBounds() {
        val allNamedCodes = listOf(
            MacKeyCode.A, MacKeyCode.B, MacKeyCode.C, MacKeyCode.D, MacKeyCode.E,
            MacKeyCode.F, MacKeyCode.G, MacKeyCode.H, MacKeyCode.I, MacKeyCode.J,
            MacKeyCode.K, MacKeyCode.L, MacKeyCode.M, MacKeyCode.N, MacKeyCode.O,
            MacKeyCode.P, MacKeyCode.Q, MacKeyCode.R, MacKeyCode.S, MacKeyCode.T,
            MacKeyCode.U, MacKeyCode.V, MacKeyCode.W, MacKeyCode.X, MacKeyCode.Y,
            MacKeyCode.Z,
            MacKeyCode.NUM_0, MacKeyCode.NUM_1, MacKeyCode.NUM_2, MacKeyCode.NUM_3, MacKeyCode.NUM_4,
            MacKeyCode.NUM_5, MacKeyCode.NUM_6, MacKeyCode.NUM_7, MacKeyCode.NUM_8, MacKeyCode.NUM_9,
            MacKeyCode.GRAVE, MacKeyCode.MINUS, MacKeyCode.EQUAL,
            MacKeyCode.LEFT_BRACKET, MacKeyCode.RIGHT_BRACKET, MacKeyCode.BACKSLASH,
            MacKeyCode.SEMICOLON, MacKeyCode.QUOTE, MacKeyCode.COMMA, MacKeyCode.PERIOD, MacKeyCode.SLASH,
            MacKeyCode.TAB, MacKeyCode.SPACE, MacKeyCode.RETURN, MacKeyCode.DELETE,
            MacKeyCode.FORWARD_DELETE, MacKeyCode.ESCAPE,
            MacKeyCode.LEFT, MacKeyCode.RIGHT, MacKeyCode.UP, MacKeyCode.DOWN,
            MacKeyCode.HOME, MacKeyCode.END, MacKeyCode.PAGE_UP, MacKeyCode.PAGE_DOWN,
            MacKeyCode.F1, MacKeyCode.F2, MacKeyCode.F3, MacKeyCode.F4, MacKeyCode.F5, MacKeyCode.F6,
            MacKeyCode.F7, MacKeyCode.F8, MacKeyCode.F9, MacKeyCode.F10, MacKeyCode.F11, MacKeyCode.F12,
        )
        assertTrue(allNamedCodes.all { it in 0..127 })
        assertEquals(allNamedCodes.size, allNamedCodes.toSet().size)
    }

    @Test
    fun modifierControllerSupportsHoldChordOneShotAndDoubleTapLock() {
        val ctrl = OmniModifierController()

        // 1. Multi-touch hold chord: hold Cmd, tap C then V, release Cmd -> clears cleanly
        ctrl.onModifierDown(OmniModifier.CMD, nowMs = 1000L)
        assertEquals(ModifierLatchMode.HELD, ctrl.modeOf(OmniModifier.CMD))
        assertEquals(listOf("cmd"), ctrl.consumeForKeystroke())
        assertEquals(listOf("cmd"), ctrl.consumeForKeystroke())
        ctrl.onModifierUp(OmniModifier.CMD, nowMs = 1150L)
        assertEquals(ModifierLatchMode.OFF, ctrl.modeOf(OmniModifier.CMD))
        assertTrue(ctrl.consumeForKeystroke().isEmpty())

        // 2. Quick single tap -> ONE_SHOT -> consumed by next keystroke
        ctrl.onModifierDown(OmniModifier.OPT, nowMs = 2000L)
        ctrl.onModifierUp(OmniModifier.OPT, nowMs = 2080L)
        assertEquals(ModifierLatchMode.ONE_SHOT, ctrl.modeOf(OmniModifier.OPT))
        assertEquals(listOf("opt"), ctrl.consumeForKeystroke())
        assertEquals(ModifierLatchMode.OFF, ctrl.modeOf(OmniModifier.OPT))

        // 3. Double tap -> LOCKED -> persists across multiple keys until tapped again
        ctrl.onModifierDown(OmniModifier.SHIFT, nowMs = 3000L)
        ctrl.onModifierUp(OmniModifier.SHIFT, nowMs = 3060L)
        assertEquals(ModifierLatchMode.ONE_SHOT, ctrl.modeOf(OmniModifier.SHIFT))
        ctrl.onModifierDown(OmniModifier.SHIFT, nowMs = 3220L)
        ctrl.onModifierUp(OmniModifier.SHIFT, nowMs = 3280L)
        assertEquals(ModifierLatchMode.LOCKED, ctrl.modeOf(OmniModifier.SHIFT))
        assertEquals(listOf("shift"), ctrl.consumeForKeystroke())
        assertEquals(listOf("shift"), ctrl.consumeForKeystroke())
        ctrl.onModifierDown(OmniModifier.SHIFT, nowMs = 4000L)
        ctrl.onModifierUp(OmniModifier.SHIFT, nowMs = 4060L)
        assertEquals(ModifierLatchMode.OFF, ctrl.modeOf(OmniModifier.SHIFT))

        // 4. Fn morph layer consumes one-shot fn while preserving Cmd for Cmd+F1
        ctrl.onModifierDown(OmniModifier.CMD, nowMs = 5000L)
        ctrl.onModifierUp(OmniModifier.CMD, nowMs = 5050L)
        ctrl.onModifierDown(OmniModifier.FN, nowMs = 5100L)
        ctrl.onModifierUp(OmniModifier.FN, nowMs = 5150L)
        assertEquals(listOf("cmd"), ctrl.consumeForKeystroke(omitFnWireFlag = true))
        assertFalse(ctrl.isActive(OmniModifier.FN))
        assertFalse(ctrl.isActive(OmniModifier.CMD))
    }

    @Test
    fun allTypingLayoutsCoverFullAlphabetDigitsAndImeSwitch() {
        assertEquals(4, OmniKeyboardStyle.entries.size)

        val compactAll = listOf(
            OmniMacLayouts.rowNumberCompact,
            OmniMacLayouts.rowQwertyCompact,
            OmniMacLayouts.rowHomeCompact,
            OmniMacLayouts.rowZxcvCompact,
            OmniMacLayouts.rowBottomCompact,
        ).flatten()

        val slimAll = listOf(
            OmniMacLayouts.slimRow1Alpha,
            OmniMacLayouts.slimRow1Symbols,
            OmniMacLayouts.slimRow2Alpha,
            OmniMacLayouts.slimRow2Symbols,
            OmniMacLayouts.slimRow3,
            OmniMacLayouts.slimRow4,
        ).flatten()

        val splitAll = (
            OmniMacLayouts.splitLeftRows + OmniMacLayouts.splitRightRows +
                OmniMacLayouts.splitLeftSymbolRows + OmniMacLayouts.splitRightSymbolRows
            ).flatten()

        val expectedLetters = listOf(
            MacKeyCode.A, MacKeyCode.B, MacKeyCode.C, MacKeyCode.D, MacKeyCode.E,
            MacKeyCode.F, MacKeyCode.G, MacKeyCode.H, MacKeyCode.I, MacKeyCode.J,
            MacKeyCode.K, MacKeyCode.L, MacKeyCode.M, MacKeyCode.N, MacKeyCode.O,
            MacKeyCode.P, MacKeyCode.Q, MacKeyCode.R, MacKeyCode.S, MacKeyCode.T,
            MacKeyCode.U, MacKeyCode.V, MacKeyCode.W, MacKeyCode.X, MacKeyCode.Y,
            MacKeyCode.Z,
        )

        for (deck in listOf(compactAll, slimAll, splitAll)) {
            val codes = deck.filterIsInstance<KeySpec.CharOrAction>().map { it.keyCode }.toSet()
            assertTrue(codes.containsAll(expectedLetters))
            assertTrue(codes.contains(MacKeyCode.SPACE))
            assertTrue(codes.contains(MacKeyCode.RETURN))
            assertTrue(codes.contains(MacKeyCode.DELETE))
            assertTrue(deck.any { it is KeySpec.InputSourceKey })
        }
    }
}
