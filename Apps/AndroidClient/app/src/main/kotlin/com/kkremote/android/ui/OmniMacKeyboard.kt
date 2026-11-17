package com.kkremote.android.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.PointerId
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min

/**
 * Compact self-drawn virtual Mac keyboard styles for Omni-Desktop mode.
 * Never invokes Android's system IME — all key events emit raw macOS CGKeyCodes + modifiers.
 */
@Serializable
enum class OmniKeyboardStyle(val shortLabel: String, val fullLabel: String) {
    COMPACT_5_ROW("5行全键", "紧凑 5 行全键位"),
    SLIM_4_ROW("4行超薄", "极简 4 行超薄配列"),
    SPLIT_TRACKPAD("分体触控", "左右分体 + 中置触控板"),
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
        KeySpec.CharOrAction(MacKeyCode.SPACE, "Space", weight = 4.6f, repeatable = true, tag = "key_space"),
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
        KeySpec.CharOrAction(MacKeyCode.SPACE, "Space", weight = 3.8f, repeatable = true, tag = "key_slim_space"),
        KeySpec.CharOrAction(MacKeyCode.LEFT, "←", repeatable = true, isUtility = true),
        KeySpec.CharOrAction(MacKeyCode.DOWN, "↓", repeatable = true, isUtility = true),
        KeySpec.CharOrAction(MacKeyCode.RIGHT, "→", repeatable = true, isUtility = true),
    )

    // Split thumb layout (Left cluster + Center Trackpad + Right cluster)
    val splitLeftRows: List<List<KeySpec>> = listOf(
        listOf(
            KeySpec.CharOrAction(MacKeyCode.GRAVE, "`", "~", fnKeyCode = MacKeyCode.ESCAPE, fnLabel = "Esc"),
            KeySpec.CharOrAction(MacKeyCode.NUM_1, "1", "!", fnKeyCode = MacKeyCode.F1, fnLabel = "F1"),
            KeySpec.CharOrAction(MacKeyCode.NUM_2, "2", "@", fnKeyCode = MacKeyCode.F2, fnLabel = "F2"),
            KeySpec.CharOrAction(MacKeyCode.NUM_3, "3", "#", fnKeyCode = MacKeyCode.F3, fnLabel = "F3"),
            KeySpec.CharOrAction(MacKeyCode.NUM_4, "4", "$", fnKeyCode = MacKeyCode.F4, fnLabel = "F4"),
            KeySpec.CharOrAction(MacKeyCode.NUM_5, "5", "%", fnKeyCode = MacKeyCode.F5, fnLabel = "F5"),
        ),
        listOf(
            KeySpec.CharOrAction(MacKeyCode.TAB, "⇥", weight = 1.2f, isUtility = true),
            letter(MacKeyCode.Q, "Q"),
            letter(MacKeyCode.W, "W"),
            letter(MacKeyCode.E, "E"),
            letter(MacKeyCode.R, "R"),
            letter(MacKeyCode.T, "T"),
        ),
        listOf(
            KeySpec.InputSourceKey(label = "中/英", weight = 1.3f),
            letter(MacKeyCode.A, "A"),
            letter(MacKeyCode.S, "S"),
            letter(MacKeyCode.D, "D"),
            letter(MacKeyCode.F, "F"),
            letter(MacKeyCode.G, "G"),
        ),
        listOf(
            KeySpec.ModifierKey(OmniModifier.SHIFT, "⇧", weight = 1.35f),
            letter(MacKeyCode.Z, "Z"),
            letter(MacKeyCode.X, "X"),
            letter(MacKeyCode.C, "C"),
            letter(MacKeyCode.V, "V"),
            letter(MacKeyCode.B, "B"),
        ),
        listOf(
            KeySpec.ModifierKey(OmniModifier.FN, "fn", weight = 1.0f),
            KeySpec.ModifierKey(OmniModifier.CTRL, "⌃", weight = 1.0f),
            KeySpec.ModifierKey(OmniModifier.OPT, "⌥", weight = 1.0f),
            KeySpec.ModifierKey(OmniModifier.CMD, "⌘", weight = 1.25f),
            KeySpec.CharOrAction(MacKeyCode.SPACE, "Space", weight = 1.85f, repeatable = true, tag = "key_split_space_l"),
        ),
    )

    val splitRightRows: List<List<KeySpec>> = listOf(
        listOf(
            KeySpec.CharOrAction(MacKeyCode.NUM_6, "6", "^", fnKeyCode = MacKeyCode.F6, fnLabel = "F6"),
            KeySpec.CharOrAction(MacKeyCode.NUM_7, "7", "&", fnKeyCode = MacKeyCode.F7, fnLabel = "F7"),
            KeySpec.CharOrAction(MacKeyCode.NUM_8, "8", "*", fnKeyCode = MacKeyCode.F8, fnLabel = "F8"),
            KeySpec.CharOrAction(MacKeyCode.NUM_9, "9", "(", fnKeyCode = MacKeyCode.F9, fnLabel = "F9"),
            KeySpec.CharOrAction(MacKeyCode.NUM_0, "0", ")", fnKeyCode = MacKeyCode.F10, fnLabel = "F10"),
            KeySpec.CharOrAction(MacKeyCode.MINUS, "-", "_", fnKeyCode = MacKeyCode.F11, fnLabel = "F11"),
            KeySpec.CharOrAction(MacKeyCode.EQUAL, "=", "+", fnKeyCode = MacKeyCode.F12, fnLabel = "F12"),
            KeySpec.CharOrAction(MacKeyCode.DELETE, "⌫", fnKeyCode = MacKeyCode.FORWARD_DELETE, fnLabel = "Del", weight = 1.3f, repeatable = true, isUtility = true),
        ),
        listOf(
            letter(MacKeyCode.Y, "Y"),
            letter(MacKeyCode.U, "U"),
            letter(MacKeyCode.I, "I"),
            letter(MacKeyCode.O, "O"),
            letter(MacKeyCode.P, "P"),
            KeySpec.CharOrAction(MacKeyCode.LEFT_BRACKET, "[", "{"),
            KeySpec.CharOrAction(MacKeyCode.RIGHT_BRACKET, "]", "}"),
            KeySpec.CharOrAction(MacKeyCode.BACKSLASH, "\\", "|"),
        ),
        listOf(
            letter(MacKeyCode.H, "H"),
            letter(MacKeyCode.J, "J"),
            letter(MacKeyCode.K, "K"),
            letter(MacKeyCode.L, "L"),
            KeySpec.CharOrAction(MacKeyCode.SEMICOLON, ";", ":"),
            KeySpec.CharOrAction(MacKeyCode.QUOTE, "'", "\""),
            KeySpec.CharOrAction(MacKeyCode.RETURN, "⏎", weight = 1.65f, isAccent = true),
        ),
        listOf(
            letter(MacKeyCode.N, "N"),
            letter(MacKeyCode.M, "M"),
            KeySpec.CharOrAction(MacKeyCode.COMMA, ",", "<"),
            KeySpec.CharOrAction(MacKeyCode.PERIOD, ".", ">"),
            KeySpec.CharOrAction(MacKeyCode.SLASH, "/", "?"),
            KeySpec.CharOrAction(MacKeyCode.UP, "↑", repeatable = true, isUtility = true),
            KeySpec.ModifierKey(OmniModifier.SHIFT, "⇧", weight = 1.15f),
        ),
        listOf(
            KeySpec.CharOrAction(MacKeyCode.SPACE, "Space", weight = 2.2f, repeatable = true, tag = "key_split_space_r"),
            KeySpec.ModifierKey(OmniModifier.CMD, "⌘", weight = 1.15f),
            KeySpec.CharOrAction(MacKeyCode.LEFT, "←", repeatable = true, isUtility = true),
            KeySpec.CharOrAction(MacKeyCode.DOWN, "↓", repeatable = true, isUtility = true),
            KeySpec.CharOrAction(MacKeyCode.RIGHT, "→", repeatable = true, isUtility = true),
        ),
    )
}

/**
 * Custom self-drawn Mac virtual keyboard for Omni-Desktop mode.
 * Pure Compose canvas/pointer surface — never opens Android's InputMethodManager.
 */
@Composable
fun OmniMacKeyboard(
    style: OmniKeyboardStyle,
    enabled: Boolean,
    onSendRawKey: (keyCode: Int, modifiers: List<String>) -> Unit,
    onToggleInputSource: () -> Unit,
    onTrackpadDelta: (dxPt: Float, dyPt: Float) -> Unit,
    onTrackpadClick: (isSecondary: Boolean) -> Unit,
    onTrackpadScroll: (dxPt: Double, dyPt: Double) -> Unit,
    modifier: Modifier = Modifier,
) {
    val haptics = LocalHapticFeedback.current
    val modifierController = remember { OmniModifierController() }
    var modRevision by remember { mutableIntStateOf(0) }
    var slimSymbolLayer by remember { mutableStateOf(false) }

    // Force recomposition on modifier state change
    val shiftActive = remember(modRevision) { modifierController.isActive(OmniModifier.SHIFT) }
    val fnActive = remember(modRevision) { modifierController.isActive(OmniModifier.FN) }

    val latestSendRawKey by rememberUpdatedState(onSendRawKey)
    val latestToggleIme by rememberUpdatedState(onToggleInputSource)
    val latestEnabled by rememberUpdatedState(enabled)

    fun dispatchCharOrAction(spec: KeySpec.CharOrAction) {
        if (!latestEnabled) return
        val fnCode = spec.fnKeyCode
        val useFnMorph = fnActive && fnCode != null
        val code = if (fnActive && fnCode != null) fnCode else spec.keyCode
        val mods = modifierController.consumeForKeystroke(omitFnWireFlag = useFnMorph)
        modRevision += 1
        latestSendRawKey(code, mods)
    }

    BoxWithConstraints(
        modifier = modifier
            .fillMaxWidth()
            .background(
                Brush.verticalGradient(
                    colors = listOf(
                        Color(0xFF14161D),
                        Color(0xFF0D0F14),
                    )
                )
            )
            .padding(horizontal = 4.dp, vertical = 4.dp)
            .testTag("omni_mac_keyboard"),
    ) {
        val rowCount = if (style == OmniKeyboardStyle.SLIM_4_ROW) 4 else 5
        val rowGap = 3.dp
        val totalGap = rowGap * (rowCount - 1)
        val computedRowHeight = ((maxHeight - totalGap) / rowCount).coerceIn(26.dp, 38.dp)

        when (style) {
            OmniKeyboardStyle.COMPACT_5_ROW -> {
                val rows = listOf(
                    OmniMacLayouts.rowNumberCompact,
                    OmniMacLayouts.rowQwertyCompact,
                    OmniMacLayouts.rowHomeCompact,
                    OmniMacLayouts.rowZxcvCompact,
                    OmniMacLayouts.rowBottomCompact,
                )
                KeyboardRowsDeck(
                    rows = rows,
                    rowHeight = computedRowHeight,
                    rowGap = rowGap,
                    shiftActive = shiftActive,
                    fnActive = fnActive,
                    slimSymbolLayer = false,
                    modifierMode = { modRevision; modifierController.modeOf(it) },
                    onModifierDown = { mod ->
                        haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                        modifierController.onModifierDown(mod, System.currentTimeMillis())
                        modRevision += 1
                    },
                    onModifierUp = { mod, cancelled ->
                        modifierController.onModifierUp(mod, System.currentTimeMillis(), cancelled)
                        modRevision += 1
                    },
                    onFireKey = { spec ->
                        haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                        dispatchCharOrAction(spec)
                    },
                    onRepeatKey = { spec ->
                        dispatchCharOrAction(spec)
                    },
                    onToggleIme = {
                        haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                        if (latestEnabled) latestToggleIme()
                    },
                    onToggleLayer = {},
                )
            }

            OmniKeyboardStyle.SLIM_4_ROW -> {
                val rows = listOf(
                    if (slimSymbolLayer) OmniMacLayouts.slimRow1Symbols else OmniMacLayouts.slimRow1Alpha,
                    if (slimSymbolLayer) OmniMacLayouts.slimRow2Symbols else OmniMacLayouts.slimRow2Alpha,
                    OmniMacLayouts.slimRow3,
                    OmniMacLayouts.slimRow4,
                )
                KeyboardRowsDeck(
                    rows = rows,
                    rowHeight = computedRowHeight,
                    rowGap = rowGap,
                    shiftActive = shiftActive,
                    fnActive = fnActive,
                    slimSymbolLayer = slimSymbolLayer,
                    modifierMode = { modRevision; modifierController.modeOf(it) },
                    onModifierDown = { mod ->
                        haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                        modifierController.onModifierDown(mod, System.currentTimeMillis())
                        modRevision += 1
                    },
                    onModifierUp = { mod, cancelled ->
                        modifierController.onModifierUp(mod, System.currentTimeMillis(), cancelled)
                        modRevision += 1
                    },
                    onFireKey = { spec ->
                        haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                        dispatchCharOrAction(spec)
                    },
                    onRepeatKey = { spec ->
                        dispatchCharOrAction(spec)
                    },
                    onToggleIme = {
                        haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                        if (latestEnabled) latestToggleIme()
                    },
                    onToggleLayer = {
                        haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                        slimSymbolLayer = !slimSymbolLayer
                    },
                )
            }

            OmniKeyboardStyle.SPLIT_TRACKPAD -> {
                val trackpadWidth = (maxWidth * 0.23f).coerceIn(104.dp, 196.dp)
                val deckHeight = computedRowHeight * 5 + rowGap * 4
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(deckHeight),
                    horizontalArrangement = Arrangement.spacedBy(5.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Box(modifier = Modifier.weight(0.95f).fillMaxHeight()) {
                        KeyboardRowsDeck(
                            rows = OmniMacLayouts.splitLeftRows,
                            rowHeight = computedRowHeight,
                            rowGap = rowGap,
                            shiftActive = shiftActive,
                            fnActive = fnActive,
                            slimSymbolLayer = false,
                            modifierMode = { modRevision; modifierController.modeOf(it) },
                            onModifierDown = { mod ->
                                haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                                modifierController.onModifierDown(mod, System.currentTimeMillis())
                                modRevision += 1
                            },
                            onModifierUp = { mod, cancelled ->
                                modifierController.onModifierUp(mod, System.currentTimeMillis(), cancelled)
                                modRevision += 1
                            },
                            onFireKey = { spec ->
                                haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                                dispatchCharOrAction(spec)
                            },
                            onRepeatKey = { spec -> dispatchCharOrAction(spec) },
                            onToggleIme = {
                                haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                                if (latestEnabled) latestToggleIme()
                            },
                            onToggleLayer = {},
                        )
                    }

                    CenterMiniTrackpad(
                        enabled = enabled,
                        onDelta = onTrackpadDelta,
                        onClick = { secondary ->
                            haptics.performHapticFeedback(
                                if (secondary) HapticFeedbackType.LongPress else HapticFeedbackType.TextHandleMove
                            )
                            onTrackpadClick(secondary)
                        },
                        onScroll = onTrackpadScroll,
                        modifier = Modifier
                            .width(trackpadWidth)
                            .fillMaxHeight(),
                    )

                    Box(modifier = Modifier.weight(1.05f).fillMaxHeight()) {
                        KeyboardRowsDeck(
                            rows = OmniMacLayouts.splitRightRows,
                            rowHeight = computedRowHeight,
                            rowGap = rowGap,
                            shiftActive = shiftActive,
                            fnActive = fnActive,
                            slimSymbolLayer = false,
                            modifierMode = { modRevision; modifierController.modeOf(it) },
                            onModifierDown = { mod ->
                                haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                                modifierController.onModifierDown(mod, System.currentTimeMillis())
                                modRevision += 1
                            },
                            onModifierUp = { mod, cancelled ->
                                modifierController.onModifierUp(mod, System.currentTimeMillis(), cancelled)
                                modRevision += 1
                            },
                            onFireKey = { spec ->
                                haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                                dispatchCharOrAction(spec)
                            },
                            onRepeatKey = { spec -> dispatchCharOrAction(spec) },
                            onToggleIme = {
                                haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                                if (latestEnabled) latestToggleIme()
                            },
                            onToggleLayer = {},
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun KeyboardRowsDeck(
    rows: List<List<KeySpec>>,
    rowHeight: Dp,
    rowGap: Dp,
    shiftActive: Boolean,
    fnActive: Boolean,
    slimSymbolLayer: Boolean,
    modifierMode: (OmniModifier) -> ModifierLatchMode,
    onModifierDown: (OmniModifier) -> Unit,
    onModifierUp: (OmniModifier, Boolean) -> Unit,
    onFireKey: (KeySpec.CharOrAction) -> Unit,
    onRepeatKey: (KeySpec.CharOrAction) -> Unit,
    onToggleIme: () -> Unit,
    onToggleLayer: () -> Unit,
) {
    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(rowGap),
    ) {
        for (row in rows) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(rowHeight),
                horizontalArrangement = Arrangement.spacedBy(2.6.dp),
            ) {
                for (spec in row) {
                    KeyCapItem(
                        spec = spec,
                        shiftActive = shiftActive,
                        fnActive = fnActive,
                        slimSymbolLayer = slimSymbolLayer,
                        modifierMode = modifierMode,
                        onModifierDown = onModifierDown,
                        onModifierUp = onModifierUp,
                        onFireKey = onFireKey,
                        onRepeatKey = onRepeatKey,
                        onToggleIme = onToggleIme,
                        onToggleLayer = onToggleLayer,
                        modifier = Modifier
                            .weight(spec.weight)
                            .fillMaxHeight(),
                    )
                }
            }
        }
    }
}

@Composable
private fun KeyCapItem(
    spec: KeySpec,
    shiftActive: Boolean,
    fnActive: Boolean,
    slimSymbolLayer: Boolean,
    modifierMode: (OmniModifier) -> ModifierLatchMode,
    onModifierDown: (OmniModifier) -> Unit,
    onModifierUp: (OmniModifier, Boolean) -> Unit,
    onFireKey: (KeySpec.CharOrAction) -> Unit,
    onRepeatKey: (KeySpec.CharOrAction) -> Unit,
    onToggleIme: () -> Unit,
    onToggleLayer: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val scope = rememberCoroutineScope()
    var pressed by remember { mutableStateOf(false) }

    val latestOnFireKey by rememberUpdatedState(onFireKey)
    val latestOnRepeatKey by rememberUpdatedState(onRepeatKey)
    val latestOnModifierDown by rememberUpdatedState(onModifierDown)
    val latestOnModifierUp by rememberUpdatedState(onModifierUp)
    val latestOnToggleIme by rememberUpdatedState(onToggleIme)
    val latestOnToggleLayer by rememberUpdatedState(onToggleLayer)

    val shape = RoundedCornerShape(6.dp)
    val modMode = (spec as? KeySpec.ModifierKey)?.let(fun(m) = modifierMode(m.modifier)) ?: ModifierLatchMode.OFF

    val baseBg = when {
        spec is KeySpec.ModifierKey && modMode == ModifierLatchMode.LOCKED -> Color(0xFF28559A)
        spec is KeySpec.ModifierKey && modMode != ModifierLatchMode.OFF -> Color(0xFF0A84FF)
        spec is KeySpec.LayerToggleKey && slimSymbolLayer -> Color(0xFF0A84FF)
        pressed -> Color(0xFF474E62)
        spec is KeySpec.CharOrAction && spec.isAccent -> Color(0xFF1D4ED8)
        spec is KeySpec.CharOrAction && spec.isUtility -> Color(0xFF202430)
        spec is KeySpec.ModifierKey || spec is KeySpec.InputSourceKey || spec is KeySpec.LayerToggleKey -> Color(0xFF202430)
        else -> Color(0xFF2A2F3D)
    }

    val borderColor = when {
        spec is KeySpec.ModifierKey && modMode != ModifierLatchMode.OFF -> Color(0xFF7CC4FF).copy(alpha = 0.72f)
        pressed -> Color.White.copy(alpha = 0.36f)
        else -> Color.White.copy(alpha = 0.11f)
    }

    Box(
        contentAlignment = Alignment.Center,
        modifier = modifier
            .testTag(spec.tag)
            .clip(shape)
            .background(baseBg)
            .border(BorderStroke(0.6.dp, borderColor), shape)
            .pointerInput(spec) {
                awaitEachGesture {
                    val down = awaitPointerEvent().changes.firstOrNull { it.pressed } ?: return@awaitEachGesture
                    down.consume()
                    val pointerId: PointerId = down.id
                    pressed = true

                    var repeatJob: Job? = null
                    when (spec) {
                        is KeySpec.ModifierKey -> latestOnModifierDown(spec.modifier)
                        is KeySpec.CharOrAction -> {
                            latestOnFireKey(spec)
                            if (spec.repeatable) {
                                repeatJob = scope.launch {
                                    delay(370L)
                                    while (true) {
                                        latestOnRepeatKey(spec)
                                        delay(58L)
                                    }
                                }
                            }
                        }
                        is KeySpec.InputSourceKey -> latestOnToggleIme()
                        is KeySpec.LayerToggleKey -> latestOnToggleLayer()
                    }

                    var cancelled = false
                    while (true) {
                        val event = awaitPointerEvent()
                        val change = event.changes.firstOrNull { it.id == pointerId }
                        if (change == null) {
                            cancelled = true
                            break
                        }
                        change.consume()
                        if (!change.pressed) {
                            break
                        }
                    }

                    repeatJob?.cancel()
                    pressed = false
                    if (spec is KeySpec.ModifierKey) {
                        latestOnModifierUp(spec.modifier, cancelled)
                    }
                }
            },
    ) {
        when (spec) {
            is KeySpec.CharOrAction -> {
                val fnLbl = spec.fnLabel
                val useFn = fnActive && fnLbl != null
                val mainText = when {
                    fnActive && fnLbl != null -> fnLbl
                    shiftActive && spec.shifted != null -> spec.shifted
                    spec.primary.length == 1 && spec.primary[0].isLetter() -> spec.primary.uppercase()
                    else -> spec.primary
                }
                val hintText = if (!useFn && !shiftActive) spec.subHint else null

                if (hintText != null) {
                    Text(
                        text = hintText,
                        fontSize = 8.sp,
                        lineHeight = 8.sp,
                        color = Color(0xFF9AA3B8),
                        modifier = Modifier
                            .align(Alignment.TopEnd)
                            .padding(top = 1.5.dp, end = 3.dp),
                    )
                }
                Text(
                    text = mainText,
                    fontSize = when {
                        mainText == "Space" -> 11.sp
                        mainText.length >= 3 -> 10.sp
                        else -> 12.5.sp
                    },
                    fontWeight = if (useFn || spec.isAccent) FontWeight.SemiBold else FontWeight.Medium,
                    color = if (useFn) Color(0xFF8EC8FF) else Color(0xFFF3F5FA),
                    maxLines = 1,
                    overflow = TextOverflow.Clip,
                    textAlign = TextAlign.Center,
                )
            }

            is KeySpec.ModifierKey -> {
                if (modMode != ModifierLatchMode.OFF) {
                    Box(
                        modifier = Modifier
                            .align(Alignment.TopEnd)
                            .padding(top = 3.dp, end = 3.5.dp)
                            .size(4.5.dp)
                            .clip(CircleShape)
                            .background(
                                if (modMode == ModifierLatchMode.LOCKED) Color(0xFFFFD60A) else Color.White
                            )
                    )
                }
                Text(
                    text = spec.caption,
                    fontSize = if (spec.caption.length >= 2) 10.5.sp else 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = Color(0xFFF3F5FA),
                    maxLines = 1,
                )
            }

            is KeySpec.InputSourceKey -> {
                Text(
                    text = spec.label,
                    fontSize = 10.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = Color(0xFF9ED0FF),
                    maxLines = 1,
                )
            }

            is KeySpec.LayerToggleKey -> {
                Text(
                    text = if (slimSymbolLayer) spec.labelActive else spec.labelInactive,
                    fontSize = 10.5.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = Color(0xFFF3F5FA),
                    maxLines = 1,
                )
            }
        }
    }
}

/**
 * Center multi-touch relative Mac trackpad for SPLIT_TRACKPAD keyboard style:
 * - 1-finger drag: relative Mac pointer glide with gentle acceleration
 * - 1-finger tap: left click at cursor
 * - 2-finger tap: secondary (right) click at cursor
 * - 2-finger drag: smooth pixel-accurate Mac scroll wheel
 */
@Composable
private fun CenterMiniTrackpad(
    enabled: Boolean,
    onDelta: (dxPt: Float, dyPt: Float) -> Unit,
    onClick: (isSecondary: Boolean) -> Unit,
    onScroll: (dxPt: Double, dyPt: Double) -> Unit,
    modifier: Modifier = Modifier,
) {
    val density = LocalDensity.current.density
    val latestEnabled by rememberUpdatedState(enabled)
    val latestDelta by rememberUpdatedState(onDelta)
    val latestClick by rememberUpdatedState(onClick)
    val latestScroll by rememberUpdatedState(onScroll)

    var activeTouchPoint by remember { mutableStateOf<Offset?>(null) }
    val shape = RoundedCornerShape(10.dp)

    Box(
        modifier = modifier
            .testTag("omni_split_trackpad")
            .clip(shape)
            .background(
                Brush.verticalGradient(
                    colors = listOf(
                        Color(0xFF1B1F2B),
                        Color(0xFF151822),
                    )
                )
            )
            .border(BorderStroke(0.8.dp, Color(0xFF5EA8FF).copy(alpha = 0.25f)), shape)
            .pointerInput(density) {
                awaitEachGesture {
                    val firstEvent = awaitPointerEvent()
                    val firstDown = firstEvent.changes.firstOrNull { it.pressed } ?: return@awaitEachGesture
                    firstEvent.changes.forEach { it.consume() }

                    val startMs = System.currentTimeMillis()
                    var maxPointers = firstEvent.changes.count { it.pressed }
                    var totalTravelPx = 0f
                    var prevCentroid = centroidOfPressed(firstEvent.changes.mapNotNull { if (it.pressed) it.position else null })
                        ?: firstDown.position
                    activeTouchPoint = prevCentroid

                    while (true) {
                        val event = awaitPointerEvent()
                        event.changes.forEach { it.consume() }
                        val pressedPts = event.changes.mapNotNull { if (it.pressed) it.position else null }
                        if (pressedPts.isEmpty()) break

                        val count = pressedPts.size
                        if (count > maxPointers) {
                            maxPointers = count
                            prevCentroid = centroidOfPressed(pressedPts) ?: prevCentroid
                            continue
                        }
                        val curCentroid = centroidOfPressed(pressedPts) ?: prevCentroid
                        activeTouchPoint = curCentroid
                        val dxPx = curCentroid.x - prevCentroid.x
                        val dyPx = curCentroid.y - prevCentroid.y
                        prevCentroid = curCentroid

                        val stepDist = hypot(dxPx, dyPx)
                        totalTravelPx += stepDist
                        if (!latestEnabled || stepDist < 0.35f) continue

                        val dxDp = dxPx / max(1f, density)
                        val dyDp = dyPx / max(1f, density)
                        if (count >= 2) {
                            latestScroll((dxDp * 2.2f).toDouble(), (dyDp * 2.2f).toDouble())
                        } else {
                            val speedBoost = min(2.4f, 1.15f + stepDist * 0.045f)
                            latestDelta(dxDp * speedBoost, dyDp * speedBoost)
                        }
                    }

                    activeTouchPoint = null
                    val elapsed = System.currentTimeMillis() - startMs
                    val tapSlopPx = 11f * density
                    if (latestEnabled && elapsed <= 270L && totalTravelPx <= tapSlopPx) {
                        latestClick(maxPointers >= 2)
                    }
                }
            },
    ) {
        Canvas(modifier = Modifier.fillMaxSize()) {
            val midX = size.width * 0.5f
            val midY = size.height * 0.5f
            // Subtle precision trackpad grid reticle
            drawLine(
                color = Color.White.copy(alpha = 0.05f),
                start = Offset(midX, 12f),
                end = Offset(midX, size.height - 12f),
                strokeWidth = 1f,
            )
            drawLine(
                color = Color.White.copy(alpha = 0.05f),
                start = Offset(12f, midY),
                end = Offset(size.width - 12f, midY),
                strokeWidth = 1f,
            )
            activeTouchPoint?.let { pt ->
                drawCircle(
                    color = Color(0xFF0A84FF).copy(alpha = 0.28f),
                    radius = 18.dp.toPx(),
                    center = pt,
                )
                drawCircle(
                    color = Color(0xFF7CC4FF).copy(alpha = 0.85f),
                    radius = 4.dp.toPx(),
                    center = pt,
                )
            }
        }

        Text(
            text = "TRACKPAD",
            fontSize = 8.5.sp,
            fontFamily = FontFamily.Monospace,
            fontWeight = FontWeight.SemiBold,
            color = Color(0xFF7F8BA3).copy(alpha = 0.65f),
            modifier = Modifier
                .align(Alignment.TopCenter)
                .padding(top = 5.dp),
        )
        Row(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .padding(bottom = 5.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Text(
                text = "单指点按 · 双指滚轮/右键",
                fontSize = 8.sp,
                color = Color(0xFF7F8BA3).copy(alpha = 0.58f),
                maxLines = 1,
            )
        }
    }
}

private fun centroidOfPressed(points: List<Offset>): Offset? {
    if (points.isEmpty()) return null
    var sx = 0f
    var sy = 0f
    for (p in points) {
        sx += p.x
        sy += p.y
    }
    return Offset(sx / points.size, sy / points.size)
}
