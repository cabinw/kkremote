package com.kkremote.keyboardtest

import com.kkremote.android.ui.MacKeyCode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class MacTextSimulatorTest {

    private fun MacTextSimulator.type(s: String) {
        for (c in s) {
            val code = when (c) {
                'h' -> MacKeyCode.H; 'e' -> MacKeyCode.E; 'l' -> MacKeyCode.L; 'o' -> MacKeyCode.O
                'w' -> MacKeyCode.W; 'r' -> MacKeyCode.R; 'd' -> MacKeyCode.D; ' ' -> MacKeyCode.SPACE
                else -> error("unmapped $c")
            }
            onRawKey(code, emptyList())
        }
    }

    @Test
    fun typesWithShiftAndSymbols() {
        val s = MacTextSimulator()
        s.onRawKey(MacKeyCode.H, listOf("shift"))
        s.type("ello")
        s.onRawKey(MacKeyCode.NUM_1, listOf("shift"))
        s.onRawKey(MacKeyCode.LEFT_BRACKET, listOf("shift"))
        assertEquals("Hello!{", s.text)
        assertEquals(7, s.cursor)
    }

    @Test
    fun optionDeleteRemovesWordAndCmdZUndoes() {
        val s = MacTextSimulator()
        s.type("hello world")
        s.onRawKey(MacKeyCode.DELETE, listOf("opt"))
        assertEquals("hello ", s.text)
        s.onRawKey(MacKeyCode.Z, listOf("cmd"))
        assertEquals("hello world", s.text)
        s.onRawKey(MacKeyCode.Z, listOf("cmd", "shift"))
        assertEquals("hello ", s.text)
    }

    @Test
    fun shiftArrowSelectsAndTypingReplacesSelection() {
        val s = MacTextSimulator()
        s.type("hello world")
        repeat(5) { s.onRawKey(MacKeyCode.LEFT, listOf("shift")) }
        assertEquals(6 until 11, s.selection)
        s.insertText("你好")
        assertEquals("hello 你好", s.text)
        assertNull(s.selection)
    }

    @Test
    fun selectAllCopyPasteAndLineNavigation() {
        val s = MacTextSimulator()
        s.type("hello")
        s.onRawKey(MacKeyCode.RETURN, emptyList())
        s.type("world")
        s.onRawKey(MacKeyCode.LEFT, listOf("cmd"))
        assertEquals(6, s.cursor)
        s.onRawKey(MacKeyCode.UP, emptyList())
        assertEquals(0, s.cursor)
        s.onRawKey(MacKeyCode.A, listOf("cmd"))
        s.onRawKey(MacKeyCode.C, listOf("cmd"))
        s.onRawKey(MacKeyCode.DOWN, listOf("cmd"))
        s.onRawKey(MacKeyCode.V, listOf("cmd"))
        assertEquals("hello\nworldhello\nworld", s.text)
    }

    @Test
    fun describesChordsInMacModifierOrder() {
        assertEquals("⇧⌘Z", MacTextSimulator.describe(MacKeyCode.Z, listOf("cmd", "shift")))
        assertEquals("⌥⌫", MacTextSimulator.describe(MacKeyCode.DELETE, listOf("opt")))
        assertEquals("A", MacTextSimulator.describe(MacKeyCode.A, emptyList()))
    }
}
