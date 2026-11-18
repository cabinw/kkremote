package com.kkremote.keyboardtest

import com.kkremote.android.ui.MacKeyCode

/**
 * A tiny stand-in for a Mac text field: interprets the raw CGKeyCode + modifier events the Omni
 * keyboard emits (US layout) and the voice deck's insertText, so the playground shows real
 * editing results instead of a raw event dump.
 */
class MacTextSimulator {
    private data class Snapshot(val text: String, val cursor: Int, val anchor: Int?)

    var text: String = ""
        private set
    var cursor: Int = 0
        private set
    var anchor: Int? = null
        private set
    var chineseInput: Boolean = false
        private set
    var clipboard: String = ""
        private set

    private val undo = ArrayDeque<Snapshot>()
    private val redo = ArrayDeque<Snapshot>()
    private val events = ArrayDeque<String>()

    val recentEvents: List<String> get() = events.toList()

    val selection: IntRange?
        get() = anchor?.takeIf { it != cursor }?.let { minOf(it, cursor) until maxOf(it, cursor) }

    fun onRawKey(keyCode: Int, modifiers: List<String>) {
        val cmd = "cmd" in modifiers
        val opt = "opt" in modifiers
        val shift = "shift" in modifiers
        val ctrl = "ctrl" in modifiers
        log(describe(keyCode, modifiers))

        if (cmd) {
            when (keyCode) {
                MacKeyCode.A -> { anchor = 0; cursor = text.length }
                MacKeyCode.C -> selectedText()?.let { clipboard = it }
                MacKeyCode.X -> selectedText()?.let { clipboard = it; edit { replaceSelection("") } }
                MacKeyCode.V -> if (clipboard.isNotEmpty()) edit { replaceSelection(clipboard) }
                MacKeyCode.Z -> if (shift) redoOnce() else undoOnce()
                MacKeyCode.LEFT -> move(lineStart(cursor), shift)
                MacKeyCode.RIGHT -> move(lineEnd(cursor), shift)
                MacKeyCode.UP -> move(0, shift)
                MacKeyCode.DOWN -> move(text.length, shift)
                MacKeyCode.DELETE -> edit {
                    if (selection == null) anchor = lineStart(cursor)
                    replaceSelection("")
                }
                else -> Unit // ⌘Tab, ⌘Space, ⌘S…: system shortcuts, shown in the event log only
            }
            return
        }
        if (ctrl) return

        when (keyCode) {
            MacKeyCode.LEFT -> when {
                opt -> move(prevWord(cursor), shift)
                !shift && selection != null -> move(selection!!.first, false)
                else -> move((cursor - 1).coerceAtLeast(0), shift)
            }
            MacKeyCode.RIGHT -> when {
                opt -> move(nextWord(cursor), shift)
                !shift && selection != null -> move(selection!!.last + 1, false)
                else -> move((cursor + 1).coerceAtMost(text.length), shift)
            }
            MacKeyCode.UP -> move(verticalTarget(-1), shift)
            MacKeyCode.DOWN -> move(verticalTarget(+1), shift)
            MacKeyCode.HOME -> move(0, shift)
            MacKeyCode.END -> move(text.length, shift)
            MacKeyCode.PAGE_UP -> move(0, shift)
            MacKeyCode.PAGE_DOWN -> move(text.length, shift)
            MacKeyCode.ESCAPE -> anchor = null
            MacKeyCode.DELETE -> edit {
                if (selection == null) anchor = if (opt) prevWord(cursor) else (cursor - 1).coerceAtLeast(0)
                replaceSelection("")
            }
            MacKeyCode.FORWARD_DELETE -> edit {
                if (selection == null) anchor = if (opt) nextWord(cursor) else (cursor + 1).coerceAtMost(text.length)
                replaceSelection("")
            }
            MacKeyCode.RETURN -> edit { replaceSelection("\n") }
            MacKeyCode.TAB -> edit { replaceSelection("    ") }
            else -> charFor(keyCode, shift)?.let { ch -> edit { replaceSelection(ch.toString()) } }
        }
    }

    fun insertText(value: String) {
        if (value.isEmpty()) return
        log("insertText “${value.trim().take(18)}${if (value.trim().length > 18) "…" else ""}”")
        edit { replaceSelection(value) }
    }

    fun toggleInputSource() {
        chineseInput = !chineseInput
        log(if (chineseInput) "输入法 → 中" else "输入法 → 英")
    }

    fun clear() {
        edit { anchor = 0; cursor = text.length; replaceSelection("") }
        events.clear()
    }

    // --- editing primitives ------------------------------------------------------------------

    private inline fun edit(block: () -> Unit) {
        val before = Snapshot(text, cursor, anchor)
        block()
        if (text != before.text) {
            undo.addLast(before)
            while (undo.size > 200) undo.removeFirst()
            redo.clear()
        }
    }

    private fun replaceSelection(insert: String) {
        val sel = selection
        val start = sel?.first ?: cursor
        val endExclusive = sel?.let { it.last + 1 } ?: cursor
        text = text.substring(0, start) + insert + text.substring(endExclusive)
        cursor = start + insert.length
        anchor = null
    }

    private fun selectedText(): String? = selection?.let { text.substring(it.first, it.last + 1) }

    private fun move(target: Int, extend: Boolean) {
        val t = target.coerceIn(0, text.length)
        if (extend) {
            if (anchor == null) anchor = cursor
        } else {
            anchor = null
        }
        cursor = t
        if (anchor == cursor) anchor = null
    }

    private fun undoOnce() {
        val s = undo.removeLastOrNull() ?: return
        redo.addLast(Snapshot(text, cursor, anchor))
        text = s.text; cursor = s.cursor; anchor = s.anchor
    }

    private fun redoOnce() {
        val s = redo.removeLastOrNull() ?: return
        undo.addLast(Snapshot(text, cursor, anchor))
        text = s.text; cursor = s.cursor; anchor = s.anchor
    }

    private fun lineStart(pos: Int): Int = text.lastIndexOf('\n', (pos - 1).coerceAtLeast(-1)).let { if (pos == 0) 0 else it + 1 }

    private fun lineEnd(pos: Int): Int = text.indexOf('\n', pos).let { if (it < 0) text.length else it }

    private fun verticalTarget(direction: Int): Int {
        val start = lineStart(cursor)
        val column = cursor - start
        return if (direction < 0) {
            if (start == 0) 0 else {
                val prevStart = lineStart(start - 1)
                minOf(prevStart + column, start - 1)
            }
        } else {
            val end = lineEnd(cursor)
            if (end >= text.length) text.length else {
                val nextStart = end + 1
                minOf(nextStart + column, lineEnd(nextStart))
            }
        }
    }

    private fun prevWord(pos: Int): Int {
        var i = pos
        while (i > 0 && !text[i - 1].isLetterOrDigit()) i--
        while (i > 0 && text[i - 1].isLetterOrDigit()) i--
        return i
    }

    private fun nextWord(pos: Int): Int {
        var i = pos
        while (i < text.length && !text[i].isLetterOrDigit()) i++
        while (i < text.length && text[i].isLetterOrDigit()) i++
        return i
    }

    private fun log(entry: String) {
        events.addLast(entry)
        while (events.size > 40) events.removeFirst()
    }

    companion object {
        private val usLayout: Map<Int, Pair<Char, Char>> = buildMap {
            val letters = mapOf(
                MacKeyCode.A to 'a', MacKeyCode.B to 'b', MacKeyCode.C to 'c', MacKeyCode.D to 'd',
                MacKeyCode.E to 'e', MacKeyCode.F to 'f', MacKeyCode.G to 'g', MacKeyCode.H to 'h',
                MacKeyCode.I to 'i', MacKeyCode.J to 'j', MacKeyCode.K to 'k', MacKeyCode.L to 'l',
                MacKeyCode.M to 'm', MacKeyCode.N to 'n', MacKeyCode.O to 'o', MacKeyCode.P to 'p',
                MacKeyCode.Q to 'q', MacKeyCode.R to 'r', MacKeyCode.S to 's', MacKeyCode.T to 't',
                MacKeyCode.U to 'u', MacKeyCode.V to 'v', MacKeyCode.W to 'w', MacKeyCode.X to 'x',
                MacKeyCode.Y to 'y', MacKeyCode.Z to 'z',
            )
            letters.forEach { (code, c) -> put(code, c to c.uppercaseChar()) }
            put(MacKeyCode.NUM_1, '1' to '!'); put(MacKeyCode.NUM_2, '2' to '@'); put(MacKeyCode.NUM_3, '3' to '#')
            put(MacKeyCode.NUM_4, '4' to '$'); put(MacKeyCode.NUM_5, '5' to '%'); put(MacKeyCode.NUM_6, '6' to '^')
            put(MacKeyCode.NUM_7, '7' to '&'); put(MacKeyCode.NUM_8, '8' to '*'); put(MacKeyCode.NUM_9, '9' to '(')
            put(MacKeyCode.NUM_0, '0' to ')')
            put(MacKeyCode.GRAVE, '`' to '~'); put(MacKeyCode.MINUS, '-' to '_'); put(MacKeyCode.EQUAL, '=' to '+')
            put(MacKeyCode.LEFT_BRACKET, '[' to '{'); put(MacKeyCode.RIGHT_BRACKET, ']' to '}')
            put(MacKeyCode.BACKSLASH, '\\' to '|'); put(MacKeyCode.SEMICOLON, ';' to ':')
            put(MacKeyCode.QUOTE, '\'' to '"'); put(MacKeyCode.COMMA, ',' to '<'); put(MacKeyCode.PERIOD, '.' to '>')
            put(MacKeyCode.SLASH, '/' to '?'); put(MacKeyCode.SPACE, ' ' to ' ')
        }

        fun charFor(keyCode: Int, shift: Boolean): Char? = usLayout[keyCode]?.let { if (shift) it.second else it.first }

        private val keyNames: Map<Int, String> = mapOf(
            MacKeyCode.RETURN to "⏎", MacKeyCode.TAB to "⇥", MacKeyCode.SPACE to "Space", MacKeyCode.DELETE to "⌫",
            MacKeyCode.FORWARD_DELETE to "⌦", MacKeyCode.ESCAPE to "Esc", MacKeyCode.LEFT to "←", MacKeyCode.RIGHT to "→",
            MacKeyCode.UP to "↑", MacKeyCode.DOWN to "↓", MacKeyCode.HOME to "Home", MacKeyCode.END to "End",
            MacKeyCode.PAGE_UP to "PgUp", MacKeyCode.PAGE_DOWN to "PgDn",
            MacKeyCode.F1 to "F1", MacKeyCode.F2 to "F2", MacKeyCode.F3 to "F3", MacKeyCode.F4 to "F4",
            MacKeyCode.F5 to "F5", MacKeyCode.F6 to "F6", MacKeyCode.F7 to "F7", MacKeyCode.F8 to "F8",
            MacKeyCode.F9 to "F9", MacKeyCode.F10 to "F10", MacKeyCode.F11 to "F11", MacKeyCode.F12 to "F12",
        )

        /** Mac-style chord label, modifiers in ⌃⌥⇧⌘ order, e.g. "⌘⇧Z" → "⇧⌘Z". */
        fun describe(keyCode: Int, modifiers: List<String>): String {
            val prefix = buildString {
                if ("ctrl" in modifiers) append('⌃')
                if ("opt" in modifiers) append('⌥')
                if ("shift" in modifiers) append('⇧')
                if ("cmd" in modifiers) append('⌘')
                if ("fn" in modifiers) append("fn ")
            }
            val name = keyNames[keyCode] ?: usLayout[keyCode]?.first?.uppercaseChar()?.toString() ?: "#$keyCode"
            return prefix + name
        }
    }
}
