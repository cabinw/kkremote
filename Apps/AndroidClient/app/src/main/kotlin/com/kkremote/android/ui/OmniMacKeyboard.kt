package com.kkremote.android.ui

import kotlinx.serialization.Serializable
import kotlin.math.max

/**
 * Compact self-drawn virtual Mac keyboard styles for Omni-Desktop mode.
 * Never invokes Android's system IME — all key events emit raw macOS CGKeyCodes + modifiers.
 */
@Serializable
enum class OmniKeyboardStyle(val shortLabel: String, val fullLabel: String) {
    COMPACT_5_ROW("5行全键", "紧凑 5 行全键位"),
    SLIM_4_ROW("4行超薄", "极简 4 行超薄配列"),
    /** Mirrored, edge-anchored thumb layout for tablets / unfolded foldables (+ centre trackpad). */
    SPLIT_TRACKPAD("拇指分体", "对称拇指分体 + 中置触控板"),
    /** Voice-first profile: dictation panel + common keys and Mac combos under each thumb. */
    VOICE_DECK("语音", "语音输入 + 常用组合键"),
}

/** Visual skin of the self-drawn keyboard. */
@Serializable
enum class OmniKeyboardTheme(val shortLabel: String, val fullLabel: String) {
    GRAPHITE("石墨深色", "石墨深色 · 低光环境"),
    MECHANICAL_LIGHT("机械浅色", "机械浅色 · 拟物键帽"),
}

/**
 * Complete macOS Carbon HIToolbox virtual key codes (kVK_ANSI_* / kVK_*), all within 0..127.
 */
object MacKeyCode {
    const val A = 0x00
    const val S = 0x01
    const val D = 0x02
    const val F = 0x03
    const val H = 0x04
    const val G = 0x05
    const val Z = 0x06
    const val X = 0x07
    const val C = 0x08
    const val V = 0x09
    const val B = 0x0B
    const val Q = 0x0C
    const val W = 0x0D
    const val E = 0x0E
    const val R = 0x0F
    const val Y = 0x10
    const val T = 0x11
    const val NUM_1 = 0x12
    const val NUM_2 = 0x13
    const val NUM_3 = 0x14
    const val NUM_4 = 0x15
    const val NUM_6 = 0x16
    const val NUM_5 = 0x17
    const val EQUAL = 0x18
    const val NUM_9 = 0x19
    const val NUM_7 = 0x1A
    const val MINUS = 0x1B
    const val NUM_8 = 0x1C
    const val NUM_0 = 0x1D
    const val RIGHT_BRACKET = 0x1E
    const val O = 0x1F
    const val U = 0x20
    const val LEFT_BRACKET = 0x21
    const val I = 0x22
    const val P = 0x23
    const val RETURN = 0x24
    const val L = 0x25
    const val J = 0x26
    const val QUOTE = 0x27
    const val K = 0x28
    const val SEMICOLON = 0x29
    const val BACKSLASH = 0x2A
    const val COMMA = 0x2B
    const val SLASH = 0x2C
    const val N = 0x2D
    const val M = 0x2E
    const val PERIOD = 0x2F
    const val TAB = 0x30
    const val SPACE = 0x31
    const val GRAVE = 0x32
    const val DELETE = 0x33 // Backspace ⌫
    const val ESCAPE = 0x35

    const val F5 = 0x60
    const val F6 = 0x61
    const val F7 = 0x62
    const val F3 = 0x63
    const val F8 = 0x64
    const val F9 = 0x65
    const val F11 = 0x67
    const val F10 = 0x6D
    const val F12 = 0x6F

    const val HOME = 0x73
    const val PAGE_UP = 0x74
    const val FORWARD_DELETE = 0x75
    const val F4 = 0x76
    const val END = 0x77
    const val F2 = 0x78
    const val PAGE_DOWN = 0x79
    const val F1 = 0x7A
    const val LEFT = 0x7B
    const val RIGHT = 0x7C
    const val DOWN = 0x7D
    const val UP = 0x7E
}

enum class OmniModifier(val wireName: String, val symbol: String) {
    SHIFT("shift", "⇧"),
    CTRL("ctrl", "⌃"),
    OPT("opt", "⌥"),
    CMD("cmd", "⌘"),
    FN("fn", "fn"),
}

enum class ModifierLatchMode {
    OFF,
    HELD,
    ONE_SHOT,
    LOCKED,
}

/**
 * Pure state machine supporting:
 * 1. Multi-touch hold chord (hold ⌘ + tap C -> emits ["cmd"], clears ⌘ on release).
 * 2. Single quick tap sticky one-shot (tap ⌘, then tap C -> emits ["cmd"], clears one-shot).
 * 3. Double quick tap lock (tap ⇧ twice within 380ms -> locks ⇧ until tapped again).
 */
class OmniModifierController {
    private data class Slot(
        var heldPointers: Int = 0,
        var latch: ModifierLatchMode = ModifierLatchMode.OFF,
        var usedWhileHeld: Boolean = false,
        var downTimeMs: Long = 0L,
        var lastTapReleaseMs: Long = 0L,
    )

    private val slots = OmniModifier.entries.associateWith { Slot() }

    fun modeOf(mod: OmniModifier): ModifierLatchMode {
        val s = slots.getValue(mod)
        return if (s.heldPointers > 0) ModifierLatchMode.HELD else s.latch
    }

    fun isActive(mod: OmniModifier): Boolean = modeOf(mod) != ModifierLatchMode.OFF

    fun onModifierDown(mod: OmniModifier, nowMs: Long) {
        val s = slots.getValue(mod)
        s.heldPointers += 1
        if (s.heldPointers == 1) {
            s.downTimeMs = nowMs
            s.usedWhileHeld = false
        }
    }

    fun onModifierUp(mod: OmniModifier, nowMs: Long, cancelled: Boolean = false) {
        val s = slots.getValue(mod)
        s.heldPointers = max(0, s.heldPointers - 1)
        if (s.heldPointers > 0) return
        if (cancelled) {
            if (s.latch != ModifierLatchMode.LOCKED) s.latch = ModifierLatchMode.OFF
            return
        }
        val heldDuration = nowMs - s.downTimeMs
        if (s.usedWhileHeld || heldDuration > 360L) {
            // Was held as part of a chord or long hold -> return to OFF unless previously LOCKED
            if (s.latch != ModifierLatchMode.LOCKED) {
                s.latch = ModifierLatchMode.OFF
            }
            return
        }
        // Quick tap behavior: OFF -> ONE_SHOT -> (double-tap) LOCKED -> OFF
        when (s.latch) {
            ModifierLatchMode.OFF -> {
                s.latch = ModifierLatchMode.ONE_SHOT
                s.lastTapReleaseMs = nowMs
            }
            ModifierLatchMode.ONE_SHOT -> {
                if (nowMs - s.lastTapReleaseMs <= 420L) {
                    s.latch = ModifierLatchMode.LOCKED
                } else {
                    s.latch = ModifierLatchMode.OFF
                }
                s.lastTapReleaseMs = nowMs
            }
            ModifierLatchMode.LOCKED -> {
                s.latch = ModifierLatchMode.OFF
                s.lastTapReleaseMs = 0L
            }
            ModifierLatchMode.HELD -> {
                s.latch = ModifierLatchMode.ONE_SHOT
                s.lastTapReleaseMs = nowMs
            }
        }
    }

    /**
     * Returns wire modifier names active for this keystroke and consumes any ONE_SHOT latches.
     * Note: when [omitFnWireFlag] is true (e.g. fn morphed 1->F1 or ⌫->ForwardDelete), "fn" is
     * consumed as a layer shift rather than attached as a redundant secondaryFn flag unless needed.
     */
    fun consumeForKeystroke(omitFnWireFlag: Boolean = false): List<String> {
        val result = ArrayList<String>(4)
        for (mod in OmniModifier.entries) {
            val s = slots.getValue(mod)
            val active = s.heldPointers > 0 || s.latch != ModifierLatchMode.OFF
            if (!active) continue
            if (s.heldPointers > 0) {
                s.usedWhileHeld = true
            } else if (s.latch == ModifierLatchMode.ONE_SHOT) {
                s.latch = ModifierLatchMode.OFF
            }
            if (mod == OmniModifier.FN && omitFnWireFlag) continue
            result.add(mod.wireName)
        }
        return result
    }

    fun resetAll() {
        for (s in slots.values) {
            s.heldPointers = 0
            s.latch = ModifierLatchMode.OFF
            s.usedWhileHeld = false
        }
    }
}

internal sealed interface KeySpec {
    val weight: Float
    val tag: String

    data class CharOrAction(
        val keyCode: Int,
        val primary: String,
        val shifted: String? = null,
        val subHint: String? = null,
        val fnKeyCode: Int? = null,
        val fnLabel: String? = null,
        override val weight: Float = 1f,
        val repeatable: Boolean = false,
        val isAccent: Boolean = false,
        val isUtility: Boolean = false,
        override val tag: String = "key_${keyCode}_${primary}",
        /** Modifiers always sent with this key (combo keys such as ⌘Z, shifted symbols such as {). */
        val forcedModifiers: List<OmniModifier> = emptyList(),
        /** Small second line under [primary], e.g. "撤销" for ⌘Z. */
        val caption: String? = null,
    ) : KeySpec

    data class ModifierKey(
        val modifier: OmniModifier,
        val caption: String = modifier.symbol,
        override val weight: Float = 1.2f,
        override val tag: String = "mod_${modifier.wireName}",
    ) : KeySpec

    data class InputSourceKey(
        val label: String = "中/英",
        override val weight: Float = 1.45f,
        override val tag: String = "key_ime_toggle",
    ) : KeySpec

    data class LayerToggleKey(
        val labelActive: String = "ABC",
        val labelInactive: String = "123",
        override val weight: Float = 1.25f,
        override val tag: String = "key_layer_123",
    ) : KeySpec

    /** Dictation trigger: tap toggles hands-free listening, hold = push-to-talk. */
    data class VoiceKey(
        val label: String = "按住说话",
        override val weight: Float = 2f,
        override val tag: String = "key_voice",
    ) : KeySpec
}

internal object OmniMacLayouts {
    private fun letter(code: Int, ch: String) = KeySpec.CharOrAction(
        keyCode = code,
        primary = ch.lowercase(),
        shifted = ch.uppercase(),
        tag = "key_${ch.lowercase()}",
    )

    val rowNumberCompact: List<KeySpec> = listOf(
        KeySpec.CharOrAction(MacKeyCode.GRAVE, "`", "~", subHint = "~", fnKeyCode = MacKeyCode.ESCAPE, fnLabel = "Esc", tag = "key_grave"),
        KeySpec.CharOrAction(MacKeyCode.NUM_1, "1", "!", subHint = "!", fnKeyCode = MacKeyCode.F1, fnLabel = "F1", tag = "key_1"),
        KeySpec.CharOrAction(MacKeyCode.NUM_2, "2", "@", subHint = "@", fnKeyCode = MacKeyCode.F2, fnLabel = "F2", tag = "key_2"),
        KeySpec.CharOrAction(MacKeyCode.NUM_3, "3", "#", subHint = "#", fnKeyCode = MacKeyCode.F3, fnLabel = "F3", tag = "key_3"),
        KeySpec.CharOrAction(MacKeyCode.NUM_4, "4", "$", subHint = "$", fnKeyCode = MacKeyCode.F4, fnLabel = "F4", tag = "key_4"),
        KeySpec.CharOrAction(MacKeyCode.NUM_5, "5", "%", subHint = "%", fnKeyCode = MacKeyCode.F5, fnLabel = "F5", tag = "key_5"),
        KeySpec.CharOrAction(MacKeyCode.NUM_6, "6", "^", subHint = "^", fnKeyCode = MacKeyCode.F6, fnLabel = "F6", tag = "key_6"),
        KeySpec.CharOrAction(MacKeyCode.NUM_7, "7", "&", subHint = "&", fnKeyCode = MacKeyCode.F7, fnLabel = "F7", tag = "key_7"),
        KeySpec.CharOrAction(MacKeyCode.NUM_8, "8", "*", subHint = "*", fnKeyCode = MacKeyCode.F8, fnLabel = "F8", tag = "key_8"),
        KeySpec.CharOrAction(MacKeyCode.NUM_9, "9", "(", subHint = "(", fnKeyCode = MacKeyCode.F9, fnLabel = "F9", tag = "key_9"),
        KeySpec.CharOrAction(MacKeyCode.NUM_0, "0", ")", subHint = ")", fnKeyCode = MacKeyCode.F10, fnLabel = "F10", tag = "key_0"),
        KeySpec.CharOrAction(MacKeyCode.MINUS, "-", "_", subHint = "_", fnKeyCode = MacKeyCode.F11, fnLabel = "F11", tag = "key_minus"),
        KeySpec.CharOrAction(MacKeyCode.EQUAL, "=", "+", subHint = "+", fnKeyCode = MacKeyCode.F12, fnLabel = "F12", tag = "key_equal"),
        KeySpec.CharOrAction(
            keyCode = MacKeyCode.DELETE,
            primary = "⌫",
            fnKeyCode = MacKeyCode.FORWARD_DELETE,
            fnLabel = "Del",
            weight = 1.45f,
            repeatable = true,
            isUtility = true,
            tag = "key_backspace",
        ),
    )

    val rowQwertyCompact: List<KeySpec> = listOf(
        KeySpec.CharOrAction(MacKeyCode.TAB, "⇥", weight = 1.35f, isUtility = true, tag = "key_tab"),
        letter(MacKeyCode.Q, "Q"),
        letter(MacKeyCode.W, "W"),
        letter(MacKeyCode.E, "E"),
        letter(MacKeyCode.R, "R"),
        letter(MacKeyCode.T, "T"),
        letter(MacKeyCode.Y, "Y"),
        letter(MacKeyCode.U, "U"),
        letter(MacKeyCode.I, "I"),
        letter(MacKeyCode.O, "O"),
        letter(MacKeyCode.P, "P"),
        KeySpec.CharOrAction(MacKeyCode.LEFT_BRACKET, "[", "{", subHint = "{", tag = "key_lbracket"),
        KeySpec.CharOrAction(MacKeyCode.RIGHT_BRACKET, "]", "}", subHint = "}", tag = "key_rbracket"),
        KeySpec.CharOrAction(MacKeyCode.BACKSLASH, "\\", "|", subHint = "|", weight = 1.1f, tag = "key_backslash"),
    )

    val rowHomeCompact: List<KeySpec> = listOf(
        KeySpec.InputSourceKey(weight = 1.55f),
        letter(MacKeyCode.A, "A"),
        letter(MacKeyCode.S, "S"),
        letter(MacKeyCode.D, "D"),
        letter(MacKeyCode.F, "F"),
        letter(MacKeyCode.G, "G"),
        letter(MacKeyCode.H, "H"),
        letter(MacKeyCode.J, "J"),
        letter(MacKeyCode.K, "K"),
        letter(MacKeyCode.L, "L"),
        KeySpec.CharOrAction(MacKeyCode.SEMICOLON, ";", ":", subHint = ":", tag = "key_semicolon"),
        KeySpec.CharOrAction(MacKeyCode.QUOTE, "'", "\"", subHint = "\"", tag = "key_quote"),
        KeySpec.CharOrAction(MacKeyCode.RETURN, "⏎", weight = 1.75f, isAccent = true, tag = "key_return"),
    )

    val rowZxcvCompact: List<KeySpec> = listOf(
        KeySpec.ModifierKey(OmniModifier.SHIFT, "⇧", weight = 1.65f, tag = "mod_shift_l"),
        letter(MacKeyCode.Z, "Z"),
        letter(MacKeyCode.X, "X"),
        letter(MacKeyCode.C, "C"),
        letter(MacKeyCode.V, "V"),
        letter(MacKeyCode.B, "B"),
        letter(MacKeyCode.N, "N"),
        letter(MacKeyCode.M, "M"),
        KeySpec.CharOrAction(MacKeyCode.COMMA, ",", "<", subHint = "<", tag = "key_comma"),
        KeySpec.CharOrAction(MacKeyCode.PERIOD, ".", ">", subHint = ">", tag = "key_period"),
        KeySpec.CharOrAction(MacKeyCode.SLASH, "/", "?", subHint = "?", tag = "key_slash"),
        KeySpec.CharOrAction(
            keyCode = MacKeyCode.UP,
            primary = "↑",
            fnKeyCode = MacKeyCode.PAGE_UP,
            fnLabel = "PgUp",
            repeatable = true,
            isUtility = true,
            tag = "key_up",
        ),
        KeySpec.ModifierKey(OmniModifier.SHIFT, "⇧", weight = 1.25f, tag = "mod_shift_r"),
    )

    val rowBottomCompact: List<KeySpec> = listOf(
        KeySpec.ModifierKey(OmniModifier.FN, "fn", weight = 1.05f),
        KeySpec.ModifierKey(OmniModifier.CTRL, "⌃", weight = 1.05f),
        KeySpec.ModifierKey(OmniModifier.OPT, "⌥", weight = 1.05f),
        KeySpec.ModifierKey(OmniModifier.CMD, "⌘", weight = 1.25f, tag = "mod_cmd_l"),
        KeySpec.CharOrAction(MacKeyCode.SPACE, "Space", weight = 4.6f, tag = "key_space"),
        KeySpec.ModifierKey(OmniModifier.CMD, "⌘", weight = 1.2f, tag = "mod_cmd_r"),
        KeySpec.ModifierKey(OmniModifier.OPT, "⌥", weight = 1.0f, tag = "mod_opt_r"),
        KeySpec.CharOrAction(
            keyCode = MacKeyCode.LEFT,
            primary = "←",
            fnKeyCode = MacKeyCode.HOME,
            fnLabel = "Home",
            repeatable = true,
            isUtility = true,
            tag = "key_left",
        ),
        KeySpec.CharOrAction(
            keyCode = MacKeyCode.DOWN,
            primary = "↓",
            fnKeyCode = MacKeyCode.PAGE_DOWN,
            fnLabel = "PgDn",
            repeatable = true,
            isUtility = true,
            tag = "key_down",
        ),
        KeySpec.CharOrAction(
            keyCode = MacKeyCode.RIGHT,
            primary = "→",
            fnKeyCode = MacKeyCode.END,
            fnLabel = "End",
            repeatable = true,
            isUtility = true,
            tag = "key_right",
        ),
    )

    // 4-Row Slim layout rows (maximizes vertical desktop height)
    val slimRow1Alpha: List<KeySpec> = listOf(
        letter(MacKeyCode.Q, "Q"),
        letter(MacKeyCode.W, "W"),
        letter(MacKeyCode.E, "E"),
        letter(MacKeyCode.R, "R"),
        letter(MacKeyCode.T, "T"),
        letter(MacKeyCode.Y, "Y"),
        letter(MacKeyCode.U, "U"),
        letter(MacKeyCode.I, "I"),
        letter(MacKeyCode.O, "O"),
        letter(MacKeyCode.P, "P"),
        KeySpec.CharOrAction(
            keyCode = MacKeyCode.DELETE,
            primary = "⌫",
            fnKeyCode = MacKeyCode.FORWARD_DELETE,
            fnLabel = "Del",
            weight = 1.35f,
            repeatable = true,
            isUtility = true,
            tag = "key_slim_backspace",
        ),
    )

    val slimRow1Symbols: List<KeySpec> = rowNumberCompact

    val slimRow2Alpha: List<KeySpec> = listOf(
        KeySpec.CharOrAction(MacKeyCode.TAB, "⇥", weight = 1.15f, isUtility = true, tag = "key_slim_tab"),
        letter(MacKeyCode.A, "A"),
        letter(MacKeyCode.S, "S"),
        letter(MacKeyCode.D, "D"),
        letter(MacKeyCode.F, "F"),
        letter(MacKeyCode.G, "G"),
        letter(MacKeyCode.H, "H"),
        letter(MacKeyCode.J, "J"),
        letter(MacKeyCode.K, "K"),
        letter(MacKeyCode.L, "L"),
        KeySpec.CharOrAction(MacKeyCode.RETURN, "⏎", weight = 1.55f, isAccent = true, tag = "key_slim_return"),
    )

    val slimRow2Symbols: List<KeySpec> = listOf(
        KeySpec.CharOrAction(MacKeyCode.ESCAPE, "Esc", weight = 1.15f, isUtility = true, tag = "key_slim_esc"),
        KeySpec.CharOrAction(MacKeyCode.LEFT_BRACKET, "[", "{", subHint = "{"),
        KeySpec.CharOrAction(MacKeyCode.RIGHT_BRACKET, "]", "}", subHint = "}"),
        KeySpec.CharOrAction(MacKeyCode.BACKSLASH, "\\", "|", subHint = "|"),
        KeySpec.CharOrAction(MacKeyCode.SEMICOLON, ";", ":", subHint = ":"),
        KeySpec.CharOrAction(MacKeyCode.QUOTE, "'", "\"", subHint = "\""),
        KeySpec.CharOrAction(MacKeyCode.COMMA, ",", "<", subHint = "<"),
        KeySpec.CharOrAction(MacKeyCode.PERIOD, ".", ">", subHint = ">"),
        KeySpec.CharOrAction(MacKeyCode.SLASH, "/", "?", subHint = "?"),
        KeySpec.CharOrAction(MacKeyCode.UP, "↑", repeatable = true, isUtility = true),
        KeySpec.CharOrAction(MacKeyCode.RETURN, "⏎", weight = 1.45f, isAccent = true),
    )

    val slimRow3: List<KeySpec> = rowZxcvCompact

    val slimRow4: List<KeySpec> = listOf(
        KeySpec.LayerToggleKey(weight = 1.2f),
        KeySpec.InputSourceKey(label = "中/英", weight = 1.25f),
        KeySpec.ModifierKey(OmniModifier.FN, "fn", weight = 0.95f),
        KeySpec.ModifierKey(OmniModifier.CTRL, "⌃", weight = 0.95f),
        KeySpec.ModifierKey(OmniModifier.OPT, "⌥", weight = 0.95f),
        KeySpec.ModifierKey(OmniModifier.CMD, "⌘", weight = 1.2f),
        KeySpec.CharOrAction(MacKeyCode.SPACE, "Space", weight = 3.8f, tag = "key_slim_space"),
        KeySpec.CharOrAction(MacKeyCode.LEFT, "←", repeatable = true, isUtility = true),
        KeySpec.CharOrAction(MacKeyCode.DOWN, "↓", repeatable = true, isUtility = true),
        KeySpec.CharOrAction(MacKeyCode.RIGHT, "→", repeatable = true, isUtility = true),
    )

    // -----------------------------------------------------------------------------------------
    // Thumb split (tablet / unfolded foldable). Not a copy of the physical board: both halves are
    // mirrored 6-column ortholinear grids anchored to their own screen edge, so G and H sit at the
    // same distance (5.5 key units) from the thumb that types them. Keys that do not fit move to
    // the #+= layer instead of widening the right half.
    // -----------------------------------------------------------------------------------------
    private fun digit(code: Int, d: String, shifted: String, fn: Int, fnLabel: String) =
        KeySpec.CharOrAction(code, d, shifted, subHint = shifted, fnKeyCode = fn, fnLabel = fnLabel, tag = "key_$d")

    private fun sym(code: Int, label: String, shift: Boolean = false, tag: String) = KeySpec.CharOrAction(
        keyCode = code,
        primary = label,
        forcedModifiers = if (shift) listOf(OmniModifier.SHIFT) else emptyList(),
        tag = tag,
    )

    private fun letters(chars: String): List<KeySpec> = chars.map { letter(letterCode(it), it.toString()) }

    private val thumbLeftNumber: List<KeySpec> = listOf(
        KeySpec.CharOrAction(MacKeyCode.ESCAPE, "Esc", isUtility = true, tag = "key_thumb_esc"),
        digit(MacKeyCode.NUM_1, "1", "!", MacKeyCode.F1, "F1"),
        digit(MacKeyCode.NUM_2, "2", "@", MacKeyCode.F2, "F2"),
        digit(MacKeyCode.NUM_3, "3", "#", MacKeyCode.F3, "F3"),
        digit(MacKeyCode.NUM_4, "4", "$", MacKeyCode.F4, "F4"),
        digit(MacKeyCode.NUM_5, "5", "%", MacKeyCode.F5, "F5"),
    )
    private val thumbLeftTab = KeySpec.CharOrAction(MacKeyCode.TAB, "⇥", isUtility = true, tag = "key_thumb_tab")
    private val thumbLeftIme = KeySpec.InputSourceKey(weight = 1f, tag = "key_thumb_ime")
    private val thumbLeftShift = KeySpec.ModifierKey(OmniModifier.SHIFT, "⇧", weight = 1f, tag = "mod_thumb_shift")
    private val thumbLeftThumb: List<KeySpec> = listOf(
        KeySpec.ModifierKey(OmniModifier.FN, "fn", weight = 1f, tag = "mod_thumb_fn"),
        KeySpec.ModifierKey(OmniModifier.CTRL, "⌃", weight = 1f, tag = "mod_thumb_ctrl"),
        KeySpec.ModifierKey(OmniModifier.OPT, "⌥", weight = 1f, tag = "mod_thumb_opt"),
        KeySpec.ModifierKey(OmniModifier.CMD, "⌘", weight = 1f, tag = "mod_thumb_cmd"),
        KeySpec.CharOrAction(MacKeyCode.SPACE, "Space", weight = 2f, tag = "key_thumb_space_l"),
    )

    private val thumbRightNumber: List<KeySpec> = listOf(
        digit(MacKeyCode.NUM_6, "6", "^", MacKeyCode.F6, "F6"),
        digit(MacKeyCode.NUM_7, "7", "&", MacKeyCode.F7, "F7"),
        digit(MacKeyCode.NUM_8, "8", "*", MacKeyCode.F8, "F8"),
        digit(MacKeyCode.NUM_9, "9", "(", MacKeyCode.F9, "F9"),
        digit(MacKeyCode.NUM_0, "0", ")", MacKeyCode.F10, "F10"),
        KeySpec.CharOrAction(
            keyCode = MacKeyCode.DELETE, primary = "⌫", fnKeyCode = MacKeyCode.FORWARD_DELETE, fnLabel = "Del",
            repeatable = true, isUtility = true, tag = "key_thumb_backspace",
        ),
    )
    private val thumbRightQuote = KeySpec.CharOrAction(MacKeyCode.QUOTE, "'", "\"", subHint = "\"", tag = "key_thumb_quote")
    private val thumbRightReturn = KeySpec.CharOrAction(MacKeyCode.RETURN, "⏎", isAccent = true, tag = "key_thumb_return")
    private val thumbRightUp = KeySpec.CharOrAction(
        MacKeyCode.UP, "↑", fnKeyCode = MacKeyCode.PAGE_UP, fnLabel = "PgUp", repeatable = true, isUtility = true, tag = "key_thumb_up",
    )
    private val thumbRightThumb: List<KeySpec> = listOf(
        KeySpec.CharOrAction(MacKeyCode.SPACE, "Space", weight = 2f, tag = "key_thumb_space_r"),
        KeySpec.LayerToggleKey(labelActive = "ABC", labelInactive = "#+=", weight = 1f, tag = "key_thumb_layer"),
        KeySpec.CharOrAction(MacKeyCode.LEFT, "←", fnKeyCode = MacKeyCode.HOME, fnLabel = "Home", repeatable = true, isUtility = true, tag = "key_thumb_left"),
        KeySpec.CharOrAction(MacKeyCode.DOWN, "↓", fnKeyCode = MacKeyCode.PAGE_DOWN, fnLabel = "PgDn", repeatable = true, isUtility = true, tag = "key_thumb_down"),
        KeySpec.CharOrAction(MacKeyCode.RIGHT, "→", fnKeyCode = MacKeyCode.END, fnLabel = "End", repeatable = true, isUtility = true, tag = "key_thumb_right"),
    )

    val splitLeftRows: List<List<KeySpec>> = listOf(
        thumbLeftNumber,
        listOf(thumbLeftTab) + letters("QWERT"),
        listOf(thumbLeftIme) + letters("ASDFG"),
        listOf(thumbLeftShift) + letters("ZXCVB"),
        thumbLeftThumb,
    )

    val splitRightRows: List<List<KeySpec>> = listOf(
        thumbRightNumber,
        letters("YUIOP") + thumbRightQuote,
        letters("HJKL") + KeySpec.CharOrAction(MacKeyCode.SEMICOLON, ";", ":", subHint = ":", tag = "key_thumb_semicolon") +
            thumbRightReturn,
        letters("NM") + listOf(
            KeySpec.CharOrAction(MacKeyCode.COMMA, ",", "<", subHint = "<", tag = "key_thumb_comma"),
            KeySpec.CharOrAction(MacKeyCode.PERIOD, ".", ">", subHint = ">", tag = "key_thumb_period"),
            KeySpec.CharOrAction(MacKeyCode.SLASH, "/", "?", subHint = "?", tag = "key_thumb_slash"),
            thumbRightUp,
        ),
        thumbRightThumb,
    )

    /** #+= layer: letter columns become symbols; edge columns and thumb rows stay put. */
    val splitLeftSymbolRows: List<List<KeySpec>> = listOf(
        thumbLeftNumber,
        listOf(
            thumbLeftTab,
            sym(MacKeyCode.GRAVE, "`", tag = "sym_grave"),
            sym(MacKeyCode.GRAVE, "~", shift = true, tag = "sym_tilde"),
            sym(MacKeyCode.MINUS, "-", tag = "sym_minus"),
            sym(MacKeyCode.MINUS, "_", shift = true, tag = "sym_underscore"),
            sym(MacKeyCode.EQUAL, "=", tag = "sym_equal"),
        ),
        listOf(
            thumbLeftIme,
            sym(MacKeyCode.BACKSLASH, "\\", tag = "sym_backslash"),
            sym(MacKeyCode.BACKSLASH, "|", shift = true, tag = "sym_pipe"),
            sym(MacKeyCode.QUOTE, "'", tag = "sym_quote"),
            sym(MacKeyCode.QUOTE, "\"", shift = true, tag = "sym_dquote"),
            sym(MacKeyCode.SEMICOLON, ":", shift = true, tag = "sym_colon"),
        ),
        listOf(
            thumbLeftShift,
            sym(MacKeyCode.NUM_1, "!", shift = true, tag = "sym_bang"),
            sym(MacKeyCode.NUM_2, "@", shift = true, tag = "sym_at"),
            sym(MacKeyCode.NUM_3, "#", shift = true, tag = "sym_hash"),
            sym(MacKeyCode.NUM_4, "$", shift = true, tag = "sym_dollar"),
            sym(MacKeyCode.NUM_5, "%", shift = true, tag = "sym_percent"),
        ),
        thumbLeftThumb,
    )

    val splitRightSymbolRows: List<List<KeySpec>> = listOf(
        thumbRightNumber,
        listOf(
            sym(MacKeyCode.EQUAL, "+", shift = true, tag = "sym_plus"),
            sym(MacKeyCode.LEFT_BRACKET, "[", tag = "sym_lbracket"),
            sym(MacKeyCode.RIGHT_BRACKET, "]", tag = "sym_rbracket"),
            sym(MacKeyCode.LEFT_BRACKET, "{", shift = true, tag = "sym_lbrace"),
            sym(MacKeyCode.RIGHT_BRACKET, "}", shift = true, tag = "sym_rbrace"),
            thumbRightQuote,
        ),
        listOf(
            sym(MacKeyCode.NUM_6, "^", shift = true, tag = "sym_caret"),
            sym(MacKeyCode.NUM_7, "&", shift = true, tag = "sym_amp"),
            sym(MacKeyCode.NUM_8, "*", shift = true, tag = "sym_star"),
            sym(MacKeyCode.NUM_9, "(", shift = true, tag = "sym_lparen"),
            sym(MacKeyCode.NUM_0, ")", shift = true, tag = "sym_rparen"),
            thumbRightReturn,
        ),
        listOf(
            sym(MacKeyCode.COMMA, "<", shift = true, tag = "sym_lt"),
            sym(MacKeyCode.PERIOD, ">", shift = true, tag = "sym_gt"),
            sym(MacKeyCode.SLASH, "?", shift = true, tag = "sym_question"),
            sym(MacKeyCode.SEMICOLON, ";", tag = "sym_semicolon"),
            sym(MacKeyCode.SLASH, "/", tag = "sym_slash"),
            thumbRightUp,
        ),
        thumbRightThumb,
    )

    // -----------------------------------------------------------------------------------------
    // Voice deck: dictation does the typing; each thumb keeps editing keys, Mac combos and a mic.
    // -----------------------------------------------------------------------------------------
    private fun combo(
        code: Int,
        label: String,
        caption: String,
        mods: List<OmniModifier>,
        tag: String,
        weight: Float = 1f,
        repeat: Boolean = false,
    ) = KeySpec.CharOrAction(
        keyCode = code,
        primary = label,
        weight = weight,
        repeatable = repeat,
        isUtility = true,
        tag = tag,
        forcedModifiers = mods,
        caption = caption,
    )

    private val cmdOnly = listOf(OmniModifier.CMD)

    val voiceLeftRows: List<List<KeySpec>> = listOf(
        listOf(
            KeySpec.CharOrAction(MacKeyCode.ESCAPE, "Esc", isUtility = true, tag = "voice_esc"),
            combo(MacKeyCode.Z, "⌘Z", "撤销", cmdOnly, "voice_undo"),
            combo(MacKeyCode.Z, "⌘⇧Z", "重做", listOf(OmniModifier.CMD, OmniModifier.SHIFT), "voice_redo"),
        ),
        listOf(
            combo(MacKeyCode.A, "⌘A", "全选", cmdOnly, "voice_select_all"),
            combo(MacKeyCode.C, "⌘C", "复制", cmdOnly, "voice_copy"),
            combo(MacKeyCode.V, "⌘V", "粘贴", cmdOnly, "voice_paste"),
        ),
        listOf(
            KeySpec.CharOrAction(MacKeyCode.TAB, "⇥", isUtility = true, tag = "voice_tab"),
            combo(MacKeyCode.TAB, "⌘⇥", "切换App", cmdOnly, "voice_cmd_tab"),
            combo(MacKeyCode.SPACE, "⌘␣", "搜索", cmdOnly, "voice_spotlight"),
        ),
        listOf(
            KeySpec.ModifierKey(OmniModifier.SHIFT, "⇧", weight = 1f, tag = "mod_voice_shift"),
            KeySpec.ModifierKey(OmniModifier.OPT, "⌥", weight = 1f, tag = "mod_voice_opt"),
            KeySpec.ModifierKey(OmniModifier.CMD, "⌘", weight = 1f, tag = "mod_voice_cmd"),
        ),
        listOf(
            KeySpec.InputSourceKey(weight = 1f, tag = "voice_ime"),
            KeySpec.VoiceKey(weight = 2f, tag = "key_voice_l"),
        ),
    )

    val voiceRightRows: List<List<KeySpec>> = listOf(
        listOf(
            combo(MacKeyCode.DELETE, "⌥⌫", "删词", listOf(OmniModifier.OPT), "voice_delete_word", repeat = true),
            KeySpec.CharOrAction(MacKeyCode.DELETE, "⌫", weight = 2f, repeatable = true, isUtility = true, tag = "voice_backspace"),
        ),
        listOf(
            combo(MacKeyCode.LEFT, "⌘←", "行首", cmdOnly, "voice_line_start"),
            KeySpec.CharOrAction(MacKeyCode.UP, "↑", repeatable = true, isUtility = true, tag = "voice_up"),
            combo(MacKeyCode.RIGHT, "⌘→", "行尾", cmdOnly, "voice_line_end"),
        ),
        listOf(
            KeySpec.CharOrAction(MacKeyCode.LEFT, "←", repeatable = true, isUtility = true, tag = "voice_left"),
            KeySpec.CharOrAction(MacKeyCode.DOWN, "↓", repeatable = true, isUtility = true, tag = "voice_down"),
            KeySpec.CharOrAction(MacKeyCode.RIGHT, "→", repeatable = true, isUtility = true, tag = "voice_right"),
        ),
        listOf(KeySpec.CharOrAction(MacKeyCode.SPACE, "Space", weight = 3f, tag = "voice_space")),
        listOf(
            KeySpec.VoiceKey(weight = 1.5f, tag = "key_voice_r"),
            KeySpec.CharOrAction(MacKeyCode.RETURN, "⏎", weight = 1.5f, isAccent = true, tag = "voice_return"),
        ),
    )

    private fun letterCode(c: Char): Int = when (c) {
        'A' -> MacKeyCode.A; 'B' -> MacKeyCode.B; 'C' -> MacKeyCode.C; 'D' -> MacKeyCode.D
        'E' -> MacKeyCode.E; 'F' -> MacKeyCode.F; 'G' -> MacKeyCode.G; 'H' -> MacKeyCode.H
        'I' -> MacKeyCode.I; 'J' -> MacKeyCode.J; 'K' -> MacKeyCode.K; 'L' -> MacKeyCode.L
        'M' -> MacKeyCode.M; 'N' -> MacKeyCode.N; 'O' -> MacKeyCode.O; 'P' -> MacKeyCode.P
        'Q' -> MacKeyCode.Q; 'R' -> MacKeyCode.R; 'S' -> MacKeyCode.S; 'T' -> MacKeyCode.T
        'U' -> MacKeyCode.U; 'V' -> MacKeyCode.V; 'W' -> MacKeyCode.W; 'X' -> MacKeyCode.X
        'Y' -> MacKeyCode.Y; 'Z' -> MacKeyCode.Z
        else -> error("not a letter: $c")
    }
}
