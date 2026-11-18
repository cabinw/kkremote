package com.kkremote.android.ui

import android.os.Build
import android.view.HapticFeedbackConstants
import android.view.View
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectVerticalDragGestures
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
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Backspace
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.rounded.KeyboardReturn
import androidx.compose.material.icons.automirrored.rounded.KeyboardTab
import androidx.compose.material.icons.rounded.KeyboardArrowDown
import androidx.compose.material.icons.rounded.KeyboardArrowUp
import androidx.compose.material.icons.rounded.Language
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.changedToDownIgnoreConsumed
import androidx.compose.ui.input.pointer.changedToUpIgnoreConsumed
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.zIndex
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** Sizing tokens shared by the keyboard and the Omni workspace that hosts it. */
object OmniKeyboardMetrics {
    val GrabberHeight: Dp = 20.dp
    val BottomPadding: Dp = 6.dp
    val SidePadding: Dp = 6.dp

    /** Row pitch = visible key height + vertical gap. 38dp keeps ~32dp caps, the floor for thumbs. */
    val MinRowPitch: Dp = 38.dp
    val MaxRowPitch: Dp = 62.dp
    val DefaultRowPitch: Dp = 48.dp
    val WideDefaultRowPitch: Dp = 52.dp

    val ChromeHeight: Dp get() = GrabberHeight + BottomPadding

    fun rowCount(style: OmniKeyboardStyle): Int = if (style == OmniKeyboardStyle.SLIM_4_ROW) 4 else 5

    fun defaultRowPitch(widthDp: Dp): Dp = if (widthDp >= 600.dp) WideDefaultRowPitch else DefaultRowPitch

    fun heightFor(style: OmniKeyboardStyle, rowPitch: Dp): Dp = ChromeHeight + rowPitch * rowCount(style)

    internal fun verticalGap(rowPitch: Dp): Dp = (rowPitch * 0.16f).coerceIn(5.dp, 9.dp)

    internal fun horizontalGap(deckWidth: Dp, unitsPerRow: Float): Dp =
        (deckWidth / unitsPerRow * 0.16f).coerceIn(3.5.dp, 7.dp)
}

private object KbPalette {
    val trayTop = Color(0xFF1C1F27)
    val trayBottom = Color(0xFF121419)
    val trayHairline = Color.White.copy(alpha = 0.07f)

    val letterTop = Color(0xFF3C414E)
    val letterBottom = Color(0xFF353A46)
    val letterPressedTop = Color(0xFF5A6072)
    val letterPressedBottom = Color(0xFF4E5465)

    val funcTop = Color(0xFF282C36)
    val funcBottom = Color(0xFF22262F)
    val funcPressedTop = Color(0xFF3D4250)
    val funcPressedBottom = Color(0xFF363A47)

    val accentTop = Color(0xFF2E8BFF)
    val accentBottom = Color(0xFF1570E3)
    val accentPressedTop = Color(0xFF63A9FF)
    val accentPressedBottom = Color(0xFF3B8CF5)

    val activeTop = Color(0xFF233A5E)
    val activeBottom = Color(0xFF1D3251)
    val activePressedTop = Color(0xFF2F4D7A)
    val activePressedBottom = Color(0xFF284369)

    val lip = Color(0xFF07080B)
    val textPrimary = Color(0xFFF2F4F8)
    val textSecondary = Color(0xFF9AA2B4)
    val textAccent = Color(0xFF8CC8FF)
    val textWarning = Color(0xFFFFC46B)
    val ledOn = Color(0xFF6CC1FF)

    val bubbleTop = Color(0xFF616879)
    val bubbleBottom = Color(0xFF4C5263)
}

private enum class CapTone { LETTER, FUNCTION, ACCENT, ACTIVE }

@Immutable
private data class TouchVisual(val key: KeyRef, val cursorMode: Boolean)

@Immutable
private data class KeyboardVisual(
    val pressed: Set<KeyId>,
    val touches: List<TouchVisual>,
    val modes: Map<OmniModifier, ModifierLatchMode>,
    val symbolLayer: Boolean,
    val cursorDragging: Boolean,
    val enabled: Boolean,
) {
    fun mode(m: OmniModifier): ModifierLatchMode = modes[m] ?: ModifierLatchMode.OFF
    val shiftActive: Boolean get() = mode(OmniModifier.SHIFT) != ModifierLatchMode.OFF
    val fnActive: Boolean get() = mode(OmniModifier.FN) != ModifierLatchMode.OFF

    /** ⌃⌥⌘ prefix shown in the preview bubble so a chord is visible before it is sent. */
    val chordPrefix: String?
        get() = listOf(OmniModifier.CTRL, OmniModifier.OPT, OmniModifier.CMD)
            .filter { mode(it) != ModifierLatchMode.OFF }
            .joinToString("") { it.symbol }
            .ifEmpty { null }
}

/**
 * Self-drawn virtual Mac keyboard for Omni-Desktop mode. A pure Compose surface that emits raw
 * macOS key codes and never opens Android's input method.
 *
 * [rowPitch] is the current row pitch chosen by the host; when [onRowPitchChange] is set the top
 * grabber lets the user drag the keyboard taller/shorter (`final=true` on release, `null` = reset).
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
    rowPitch: Dp = OmniKeyboardMetrics.DefaultRowPitch,
    maxRowPitch: Dp = OmniKeyboardMetrics.MaxRowPitch,
    onRowPitchChange: ((rowPitch: Dp?, final: Boolean) -> Unit)? = null,
) {
    OmniMacKeyboardImpl(
        style = style,
        enabled = enabled,
        onSendRawKey = onSendRawKey,
        onToggleInputSource = onToggleInputSource,
        onTrackpadDelta = onTrackpadDelta,
        onTrackpadClick = onTrackpadClick,
        onTrackpadScroll = onTrackpadScroll,
        modifier = modifier,
        rowPitch = rowPitch,
        maxRowPitch = maxRowPitch,
        onRowPitchChange = onRowPitchChange,
        previewSetup = null,
    )
}

@Composable
private fun OmniMacKeyboardImpl(
    style: OmniKeyboardStyle,
    enabled: Boolean,
    onSendRawKey: (keyCode: Int, modifiers: List<String>) -> Unit,
    onToggleInputSource: () -> Unit,
    onTrackpadDelta: (dxPt: Float, dyPt: Float) -> Unit,
    onTrackpadClick: (isSecondary: Boolean) -> Unit,
    onTrackpadScroll: (dxPt: Double, dyPt: Double) -> Unit,
    modifier: Modifier,
    rowPitch: Dp,
    maxRowPitch: Dp,
    onRowPitchChange: ((Dp?, Boolean) -> Unit)?,
    previewSetup: ((OmniKeyTouchEngine, OmniModifierController) -> Unit)?,
) {
    val view = LocalView.current
    val density = LocalDensity.current
    val scope = rememberCoroutineScope()
    val controller = remember { OmniModifierController() }
    var revision by remember { mutableIntStateOf(0) }
    var symbolLayer by remember { mutableStateOf(false) }

    val latestEnabled by rememberUpdatedState(enabled)
    val latestSend by rememberUpdatedState(onSendRawKey)
    val latestToggleIme by rememberUpdatedState(onToggleInputSource)

    val engine = remember {
        OmniKeyTouchEngine(
            modifiers = controller,
            clock = System::currentTimeMillis,
            isEnabled = { latestEnabled },
            sendKey = { code, mods -> latestSend(code, mods) },
            toggleInputSource = { latestToggleIme() },
            toggleLayer = { symbolLayer = !symbolLayer },
            haptic = { view.keyHaptic(it) },
            onChanged = { revision++ },
        ).also { e -> previewSetup?.invoke(e, controller) }
    }
    engine.cursorStartPx = with(density) { 14.dp.toPx() }
    engine.cursorStepPx = with(density) { 11.dp.toPx() }

    val appliedStyle = remember { arrayOf(style) }
    LaunchedEffect(style) {
        // Only a real style switch drops in-flight touches (not the first composition).
        if (appliedStyle[0] != style) {
            appliedStyle[0] = style
            engine.cancelAll()
            if (style != OmniKeyboardStyle.SLIM_4_ROW) symbolLayer = false
        }
    }
    LaunchedEffect(enabled) {
        if (!enabled) {
            engine.cancelAll()
            controller.resetAll()
            revision++
        }
    }

    val visual = remember(revision, symbolLayer, enabled) {
        KeyboardVisual(
            pressed = engine.pressedKeyIds(),
            touches = engine.activeTouches.map { TouchVisual(it.key, it.cursorMode) },
            modes = OmniModifier.entries.associateWith(controller::modeOf),
            symbolLayer = symbolLayer,
            cursorDragging = engine.isCursorDragging(),
            enabled = enabled,
        )
    }

    Column(
        modifier = modifier
            .fillMaxWidth()
            .drawBehind {
                drawRect(Brush.verticalGradient(listOf(KbPalette.trayTop, KbPalette.trayBottom)))
                drawLine(KbPalette.trayHairline, Offset(0f, 0f), Offset(size.width, 0f), strokeWidth = 1f)
            }
            .padding(horizontal = OmniKeyboardMetrics.SidePadding)
            .testTag("omni_mac_keyboard"),
    ) {
        KeyboardGrabber(
            rowPitch = rowPitch,
            maxRowPitch = maxRowPitch,
            rowCount = OmniKeyboardMetrics.rowCount(style),
            visual = visual,
            onRowPitchChange = onRowPitchChange,
        )

        Box(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f)
                .graphicsLayer { alpha = if (enabled) 1f else 0.55f },
        ) {
            when (style) {
                OmniKeyboardStyle.COMPACT_5_ROW -> KeyDeck(
                    deck = 0,
                    rows = OmniMacLayouts.compactRows,
                    engine = engine,
                    visual = visual,
                    scope = scope,
                    modifier = Modifier.fillMaxSize(),
                )

                OmniKeyboardStyle.SLIM_4_ROW -> KeyDeck(
                    deck = 0,
                    rows = if (symbolLayer) OmniMacLayouts.slimSymbolRows else OmniMacLayouts.slimAlphaRows,
                    engine = engine,
                    visual = visual,
                    scope = scope,
                    modifier = Modifier.fillMaxSize(),
                )

                OmniKeyboardStyle.SPLIT_TRACKPAD -> BoxWithConstraints(Modifier.fillMaxSize()) {
                    val trackpadWidth = (maxWidth * 0.22f).coerceIn(104.dp, 200.dp)
                    val gutter = 8.dp
                    Row(
                        modifier = Modifier.fillMaxSize(),
                        horizontalArrangement = Arrangement.spacedBy(gutter),
                    ) {
                        KeyDeck(
                            deck = 0,
                            rows = OmniMacLayouts.splitLeftRows,
                            engine = engine,
                            visual = visual,
                            scope = scope,
                            modifier = Modifier.weight(0.95f).fillMaxHeight(),
                        )
                        CenterMiniTrackpad(
                            enabled = enabled,
                            onDelta = onTrackpadDelta,
                            onClick = { secondary ->
                                view.keyHaptic(if (secondary) KeyHaptic.CONFIRM else KeyHaptic.TAP)
                                onTrackpadClick(secondary)
                            },
                            onScroll = onTrackpadScroll,
                            modifier = Modifier
                                .width(trackpadWidth)
                                .fillMaxHeight(),
                        )
                        KeyDeck(
                            deck = 1,
                            rows = OmniMacLayouts.splitRightRows,
                            engine = engine,
                            visual = visual,
                            scope = scope,
                            modifier = Modifier.weight(1.05f).fillMaxHeight(),
                        )
                    }
                }
            }
        }
        Spacer(Modifier.height(OmniKeyboardMetrics.BottomPadding))
    }
}

internal val OmniMacLayouts.compactRows: List<List<KeySpec>>
    get() = listOf(rowNumberCompact, rowQwertyCompact, rowHomeCompact, rowZxcvCompact, rowBottomCompact)

internal val OmniMacLayouts.slimAlphaRows: List<List<KeySpec>>
    get() = listOf(slimRow1Alpha, slimRow2Alpha, slimRow3, slimRow4)

internal val OmniMacLayouts.slimSymbolRows: List<List<KeySpec>>
    get() = listOf(slimRow1Symbols, slimRow2Symbols, slimRow3, slimRow4)

private const val A11Y_POINTER = -7L

@Composable
private fun KeyDeck(
    deck: Int,
    rows: List<List<KeySpec>>,
    engine: OmniKeyTouchEngine,
    visual: KeyboardVisual,
    scope: CoroutineScope,
    modifier: Modifier = Modifier,
) {
    BoxWithConstraints(modifier = modifier) {
        val density = LocalDensity.current
        val widthPx = constraints.maxWidth.toFloat()
        val heightPx = constraints.maxHeight.toFloat()
        val unitsPerRow = rows.maxOf { row -> row.sumOf { it.weight.toDouble() } }.toFloat()
        val rowPitchDp = with(density) { (heightPx / rows.size).toDp() }
        val vGapPx = with(density) { OmniKeyboardMetrics.verticalGap(rowPitchDp).toPx() }
        val hGapPx = with(density) { OmniKeyboardMetrics.horizontalGap(maxWidth, unitsPerRow).toPx() }
        val geometry = remember(deck, rows, widthPx, heightPx, hGapPx, vGapPx) {
            DeckGeometry(deck, rows, widthPx, heightPx, hGapPx, vGapPx)
        }
        val repeatJobs = remember { HashMap<Long, Job>() }

        Box(
            modifier = Modifier
                .fillMaxSize()
                .pointerInput(geometry, engine) {
                    val active = HashSet<Long>()
                    try {
                        awaitPointerEventScope {
                            while (true) {
                                val event = awaitPointerEvent()
                                for (change in event.changes) {
                                    val id = change.id.value
                                    when {
                                        change.changedToDownIgnoreConsumed() -> {
                                            val ref = geometry.hit(change.position)
                                            if (ref != null) {
                                                active += id
                                                if (engine.onDown(id, ref, change.position.x)) {
                                                    repeatJobs.remove(id)?.cancel()
                                                    repeatJobs[id] = scope.launch {
                                                        delay(400L)
                                                        var interval = 82L
                                                        while (engine.onRepeat(id)) {
                                                            delay(interval)
                                                            interval = max(34L, (interval * 0.9f).toLong())
                                                        }
                                                    }
                                                }
                                            }
                                        }

                                        change.changedToUpIgnoreConsumed() -> if (active.remove(id)) {
                                            repeatJobs.remove(id)?.cancel()
                                            engine.onUp(id)
                                        }

                                        change.pressed && id in active ->
                                            engine.onMove(id, geometry.hit(change.position), change.position.x)
                                    }
                                    change.consume()
                                }
                            }
                        }
                    } finally {
                        for (id in active) {
                            repeatJobs.remove(id)?.cancel()
                            engine.onCancel(id)
                        }
                    }
                },
        ) {
            rows.forEachIndexed { r, row ->
                row.forEachIndexed { c, spec ->
                    val id = KeyId(deck, r, c)
                    key(id, spec) {
                        KeyCap(
                            spec = spec,
                            rect = geometry.rects[r][c],
                            unitWidthPx = geometry.unitWidthPx,
                            pressed = id in visual.pressed,
                            visual = visual,
                            density = density,
                            onAccessibilityActivate = {
                                engine.onDown(A11Y_POINTER, KeyRef(id, spec), 0f)
                                engine.onUp(A11Y_POINTER)
                            },
                        )
                    }
                }
            }

            for (touch in visual.touches) {
                if (touch.key.id.deck != deck || touch.cursorMode) continue
                val spec = touch.key.spec as? KeySpec.CharOrAction ?: continue
                if (!spec.showsPreviewBubble()) continue
                val rect = geometry.rectOf(touch.key.id) ?: continue
                PreviewBubble(
                    rect = rect,
                    deckWidthPx = widthPx,
                    label = spec.displayText(visual.shiftActive, visual.fnActive),
                    chord = visual.chordPrefix,
                    isFnLabel = visual.fnActive && spec.fnLabel != null,
                    density = density,
                )
            }
        }
    }
}

private fun KeySpec.CharOrAction.showsPreviewBubble(): Boolean =
    !repeatable && !isUtility && !isAccent && keyCode != MacKeyCode.SPACE

private fun KeySpec.CharOrAction.displayText(shift: Boolean, fn: Boolean): String {
    val fnText = fnLabel
    return when {
        fn && fnText != null -> fnText
        shift && shifted != null -> shifted
        primary.length == 1 && primary[0].isLetter() -> if (shift) primary.uppercase() else primary.lowercase()
        else -> primary
    }
}

private fun iconFor(keyCode: Int): ImageVector? = when (keyCode) {
    MacKeyCode.DELETE -> Icons.AutoMirrored.Outlined.Backspace
    MacKeyCode.RETURN -> Icons.AutoMirrored.Rounded.KeyboardReturn
    MacKeyCode.TAB -> Icons.AutoMirrored.Rounded.KeyboardTab
    MacKeyCode.UP -> Icons.Rounded.KeyboardArrowUp
    MacKeyCode.DOWN -> Icons.Rounded.KeyboardArrowDown
    MacKeyCode.LEFT -> Icons.AutoMirrored.Rounded.KeyboardArrowLeft
    MacKeyCode.RIGHT -> Icons.AutoMirrored.Rounded.KeyboardArrowRight
    else -> null
}

private fun wordFor(spec: KeySpec): String? = when (spec) {
    is KeySpec.CharOrAction -> when (spec.keyCode) {
        MacKeyCode.DELETE -> "delete"
        MacKeyCode.RETURN -> "return"
        MacKeyCode.TAB -> "tab"
        else -> null
    }
    is KeySpec.ModifierKey -> when (spec.modifier) {
        OmniModifier.SHIFT -> "shift"
        OmniModifier.CTRL -> "control"
        OmniModifier.OPT -> "option"
        OmniModifier.CMD -> "command"
        OmniModifier.FN -> null
    }
    else -> null
}

private fun spokenLabel(spec: KeySpec): String = when (spec) {
    is KeySpec.CharOrAction -> when (spec.keyCode) {
        MacKeyCode.DELETE -> "删除"
        MacKeyCode.RETURN -> "回车"
        MacKeyCode.TAB -> "Tab"
        MacKeyCode.SPACE -> "空格"
        MacKeyCode.ESCAPE -> "Esc"
        MacKeyCode.UP -> "上箭头"
        MacKeyCode.DOWN -> "下箭头"
        MacKeyCode.LEFT -> "左箭头"
        MacKeyCode.RIGHT -> "右箭头"
        else -> spec.primary
    }
    is KeySpec.ModifierKey -> when (spec.modifier) {
        OmniModifier.SHIFT -> "Shift"
        OmniModifier.CTRL -> "Control"
        OmniModifier.OPT -> "Option"
        OmniModifier.CMD -> "Command"
        OmniModifier.FN -> "Fn"
    }
    is KeySpec.InputSourceKey -> "切换中英文输入法"
    is KeySpec.LayerToggleKey -> "切换数字符号层"
}

@Composable
private fun KeyCap(
    spec: KeySpec,
    rect: Rect,
    unitWidthPx: Float,
    pressed: Boolean,
    visual: KeyboardVisual,
    density: Density,
    onAccessibilityActivate: () -> Unit,
) {
    val press by animateFloatAsState(
        targetValue = if (pressed) 1f else 0f,
        animationSpec = if (pressed) snap() else tween(durationMillis = 120),
        label = "keyPress",
    )
    val modMode = (spec as? KeySpec.ModifierKey)?.let { visual.mode(it.modifier) } ?: ModifierLatchMode.OFF
    val tone = when {
        spec is KeySpec.ModifierKey && modMode == ModifierLatchMode.LOCKED -> CapTone.ACCENT
        spec is KeySpec.ModifierKey && modMode != ModifierLatchMode.OFF -> CapTone.ACTIVE
        spec is KeySpec.LayerToggleKey && visual.symbolLayer -> CapTone.ACTIVE
        spec is KeySpec.CharOrAction && spec.isAccent -> CapTone.ACCENT
        spec is KeySpec.CharOrAction && !spec.isUtility -> CapTone.LETTER
        else -> CapTone.FUNCTION
    }
    val (top, bottom, pTop, pBottom) = when (tone) {
        CapTone.LETTER -> listOf(KbPalette.letterTop, KbPalette.letterBottom, KbPalette.letterPressedTop, KbPalette.letterPressedBottom)
        CapTone.FUNCTION -> listOf(KbPalette.funcTop, KbPalette.funcBottom, KbPalette.funcPressedTop, KbPalette.funcPressedBottom)
        CapTone.ACCENT -> listOf(KbPalette.accentTop, KbPalette.accentBottom, KbPalette.accentPressedTop, KbPalette.accentPressedBottom)
        CapTone.ACTIVE -> listOf(KbPalette.activeTop, KbPalette.activeBottom, KbPalette.activePressedTop, KbPalette.activePressedBottom)
    }

    val widthDp = with(density) { rect.width.toDp() }
    val heightDp = with(density) { rect.height.toDp() }
    val lipPx = with(density) { 1.5.dp.toPx() }
    val radiusPx = min(with(density) { 8.dp.toPx() }, rect.height * 0.2f)
    val showWords = widthDp >= 44.dp && heightDp >= 36.dp
    val keyH = rect.height
    fun px(fraction: Float, maxSp: Float): TextUnit = with(density) {
        min((keyH * fraction).toSp().value, maxSp).sp
    }

    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .offset { IntOffset(rect.left.roundToInt(), rect.top.roundToInt()) }
            .size(widthDp, heightDp)
            .testTag(spec.tag)
            .semantics {
                contentDescription = spokenLabel(spec)
                role = Role.Button
                onClick { onAccessibilityActivate(); true }
            }
            .drawBehind {
                val r = CornerRadius(radiusPx)
                val sink = lipPx * press
                val faceH = size.height - lipPx
                drawRoundRect(
                    color = KbPalette.lip,
                    topLeft = Offset(0f, lipPx),
                    size = Size(size.width, faceH),
                    cornerRadius = r,
                )
                drawRoundRect(
                    brush = Brush.verticalGradient(
                        listOf(lerp(top, pTop, press), lerp(bottom, pBottom, press)),
                        startY = sink,
                        endY = sink + faceH,
                    ),
                    topLeft = Offset(0f, sink),
                    size = Size(size.width, faceH),
                    cornerRadius = r,
                )
                drawRoundRect(
                    brush = Brush.verticalGradient(
                        listOf(Color.White.copy(alpha = 0.11f * (1f - press * 0.5f)), Color.Transparent),
                        startY = sink,
                        endY = sink + faceH * 0.55f,
                    ),
                    topLeft = Offset(0.5f, sink + 0.5f),
                    size = Size(size.width - 1f, faceH - 1f),
                    cornerRadius = r,
                    style = Stroke(width = 1f),
                )
            },
    ) {
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .fillMaxSize()
                .padding(bottom = 1.5.dp)
                .offset { IntOffset(0, (lipPx * press).roundToInt()) },
        ) {
            val onAccent = tone == CapTone.ACCENT
            val baseColor = if (onAccent) Color.White else KbPalette.textPrimary
            when (spec) {
                is KeySpec.CharOrAction -> CharCapContent(spec, visual, showWords, baseColor, ::px)
                is KeySpec.ModifierKey -> {
                    val color = when (modMode) {
                        ModifierLatchMode.OFF -> KbPalette.textPrimary
                        ModifierLatchMode.LOCKED -> Color.White
                        else -> KbPalette.textAccent
                    }
                    if (modMode != ModifierLatchMode.OFF) {
                        Box(
                            modifier = Modifier
                                .align(Alignment.TopStart)
                                .padding(start = 5.dp, top = 4.dp)
                                .size(width = 8.dp, height = 3.dp)
                                .clip(CircleShape)
                                .background(if (modMode == ModifierLatchMode.LOCKED) Color.White else KbPalette.ledOn),
                        )
                    }
                    SymbolWithWord(
                        symbol = spec.caption,
                        word = if (showWords) wordFor(spec) else null,
                        color = color,
                        symbolSize = if (spec.caption.length >= 2) px(0.30f, 15f) else px(0.40f, 20f),
                        wordSize = px(0.20f, 10f),
                    )
                }
                is KeySpec.InputSourceKey -> Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(3.dp),
                ) {
                    if (showWords) {
                        Icon(
                            imageVector = Icons.Rounded.Language,
                            contentDescription = null,
                            tint = KbPalette.textAccent,
                            modifier = Modifier.size(heightDp * 0.34f),
                        )
                    }
                    Text(
                        text = spec.label,
                        fontSize = px(0.28f, 14f),
                        fontWeight = FontWeight.Medium,
                        color = KbPalette.textAccent,
                        maxLines = 1,
                        softWrap = false,
                    )
                }
                is KeySpec.LayerToggleKey -> Text(
                    text = if (visual.symbolLayer) spec.labelActive else spec.labelInactive,
                    fontSize = px(0.28f, 14f),
                    fontWeight = FontWeight.Medium,
                    color = if (visual.symbolLayer) KbPalette.textAccent else KbPalette.textPrimary,
                    maxLines = 1,
                    softWrap = false,
                )
            }
        }
    }
}

@Composable
private fun CharCapContent(
    spec: KeySpec.CharOrAction,
    visual: KeyboardVisual,
    showWords: Boolean,
    baseColor: Color,
    px: (Float, Float) -> TextUnit,
) {
    val fnText = spec.fnLabel
    val icon = iconFor(spec.keyCode)
    when {
        visual.fnActive && fnText != null -> Text(
            text = fnText,
            fontSize = px(if (fnText.length >= 3) 0.26f else 0.32f, 15f),
            fontWeight = FontWeight.SemiBold,
            color = KbPalette.textAccent,
            maxLines = 1,
            softWrap = false,
        )

        icon != null -> Column(horizontalAlignment = Alignment.CenterHorizontally) {
            val word = if (showWords) wordFor(spec) else null
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = baseColor,
                modifier = Modifier.size(with(LocalDensity.current) { px(0.46f, 24f).toDp() }),
            )
            if (word != null) {
                Text(word, fontSize = px(0.19f, 10f), color = baseColor.copy(alpha = 0.72f), maxLines = 1)
            }
        }

        spec.keyCode == MacKeyCode.SPACE -> Text(
            text = if (visual.cursorDragging) "‹  移动光标  ›" else "space",
            fontSize = px(0.24f, 12f),
            fontWeight = if (visual.cursorDragging) FontWeight.SemiBold else FontWeight.Normal,
            color = if (visual.cursorDragging) KbPalette.textAccent else KbPalette.textSecondary,
            maxLines = 1,
            softWrap = false,
        )

        spec.keyCode == MacKeyCode.ESCAPE -> Text(
            text = "esc",
            fontSize = px(0.26f, 13f),
            color = baseColor,
            maxLines = 1,
        )

        spec.shifted != null && !(spec.primary.length == 1 && spec.primary[0].isLetter()) -> {
            if (visual.shiftActive) {
                Text(spec.shifted, fontSize = px(0.40f, 20f), color = baseColor, maxLines = 1)
            } else {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy((-1).dp),
                ) {
                    Text(spec.shifted, fontSize = px(0.25f, 12f), color = KbPalette.textSecondary, maxLines = 1)
                    Text(spec.primary, fontSize = px(0.34f, 17f), color = baseColor, maxLines = 1)
                }
            }
        }

        else -> Text(
            text = spec.displayText(visual.shiftActive, fn = false),
            fontSize = px(0.44f, 22f),
            fontWeight = FontWeight.Normal,
            color = baseColor,
            maxLines = 1,
            softWrap = false,
            textAlign = TextAlign.Center,
        )
    }
}

@Composable
private fun SymbolWithWord(symbol: String, word: String?, color: Color, symbolSize: TextUnit, wordSize: TextUnit) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(symbol, fontSize = symbolSize, fontWeight = FontWeight.Medium, color = color, maxLines = 1, softWrap = false)
        if (word != null) {
            Text(word, fontSize = wordSize, color = color.copy(alpha = 0.72f), maxLines = 1, softWrap = false)
        }
    }
}

@Composable
private fun PreviewBubble(
    rect: Rect,
    deckWidthPx: Float,
    label: String,
    chord: String?,
    isFnLabel: Boolean,
    density: Density,
) {
    val shape = RoundedCornerShape(12.dp)
    val wPx = max(rect.width + with(density) { 18.dp.toPx() }, with(density) { 46.dp.toPx() })
    val hPx = rect.height + with(density) { 24.dp.toPx() }
    val overhang = with(density) { OmniKeyboardMetrics.SidePadding.toPx() }
    val leftPx = (rect.center.x - wPx / 2f).coerceIn(-overhang, deckWidthPx - wPx + overhang)
    val topPx = rect.top - hPx - with(density) { 4.dp.toPx() }
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
        modifier = Modifier
            .zIndex(2f)
            .offset { IntOffset(leftPx.roundToInt(), topPx.roundToInt()) }
            .size(with(density) { wPx.toDp() }, with(density) { hPx.toDp() })
            .shadow(elevation = 10.dp, shape = shape, ambientColor = Color.Black, spotColor = Color.Black)
            .background(Brush.verticalGradient(listOf(KbPalette.bubbleTop, KbPalette.bubbleBottom)), shape)
            .border(0.6.dp, Color.White.copy(alpha = 0.14f), shape),
    ) {
        if (chord != null) {
            Text(chord, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = KbPalette.textAccent, maxLines = 1)
        }
        Text(
            text = label,
            fontSize = with(density) { min((hPx * 0.42f).toSp().value, if (isFnLabel || label.length > 1) 20f else 30f).sp },
            fontWeight = if (isFnLabel) FontWeight.SemiBold else FontWeight.Normal,
            color = if (isFnLabel) KbPalette.textAccent else Color.White,
            maxLines = 1,
            softWrap = false,
        )
    }
}

@Composable
private fun KeyboardGrabber(
    rowPitch: Dp,
    maxRowPitch: Dp,
    rowCount: Int,
    visual: KeyboardVisual,
    onRowPitchChange: ((Dp?, Boolean) -> Unit)?,
) {
    val view = LocalView.current
    val density = LocalDensity.current
    val latestPitch by rememberUpdatedState(rowPitch)
    val latestMax by rememberUpdatedState(maxRowPitch)
    val latestChange by rememberUpdatedState(onRowPitchChange)
    var dragging by remember { mutableStateOf(false) }
    var dragPitch by remember { mutableFloatStateOf(rowPitch.value) }

    val locked = OmniModifier.entries.filter { visual.mode(it) == ModifierLatchMode.LOCKED }
    val (status, statusColor) = when {
        !visual.enabled -> "未连接 · 按键暂停发送" to KbPalette.textWarning
        visual.cursorDragging -> "光标模式 · 左右滑动空格键" to KbPalette.textAccent
        locked.isNotEmpty() -> "${locked.joinToString(" ") { it.symbol }} 已锁定 · 再点一次解除" to KbPalette.textAccent
        else -> null to KbPalette.textSecondary
    }

    var base = Modifier
        .fillMaxWidth()
        .height(OmniKeyboardMetrics.GrabberHeight)
    if (onRowPitchChange != null) {
        base = base
            .pointerInput(rowCount) {
                var startPitch = 0f
                var accumulated = 0f
                var lastTick = 0
                detectVerticalDragGestures(
                    onDragStart = {
                        dragging = true
                        startPitch = latestPitch.value
                        dragPitch = startPitch
                        accumulated = 0f
                        lastTick = (startPitch / 2f).roundToInt()
                    },
                    onDragEnd = {
                        dragging = false
                        latestChange?.invoke(dragPitch.dp, true)
                    },
                    onDragCancel = {
                        dragging = false
                        latestChange?.invoke(dragPitch.dp, true)
                    },
                ) { change, dy ->
                    change.consume()
                    accumulated += dy / density.density
                    val upper = min(OmniKeyboardMetrics.MaxRowPitch.value, latestMax.value)
                    val next = (startPitch - accumulated / rowCount)
                        .coerceIn(OmniKeyboardMetrics.MinRowPitch.value, max(OmniKeyboardMetrics.MinRowPitch.value, upper))
                    dragPitch = next
                    val tick = (next / 2f).roundToInt()
                    if (tick != lastTick) {
                        lastTick = tick
                        view.keyHaptic(KeyHaptic.TICK)
                    }
                    latestChange?.invoke(next.dp, false)
                }
            }
            .pointerInput(Unit) {
                detectTapGestures(onDoubleTap = {
                    view.keyHaptic(KeyHaptic.CONFIRM)
                    latestChange?.invoke(null, true)
                })
            }
            .semantics { contentDescription = "拖动调整键盘高度，双击恢复默认" }
            .testTag("omni_keyboard_grabber")
    }

    Box(modifier = base) {
        if (status != null) {
            Text(
                text = status,
                fontSize = 9.5.sp,
                fontWeight = FontWeight.Medium,
                color = statusColor,
                maxLines = 1,
                softWrap = false,
                modifier = Modifier
                    .align(Alignment.CenterStart)
                    .padding(start = 2.dp),
            )
        }
        if (onRowPitchChange != null) {
            Box(
                modifier = Modifier
                    .align(Alignment.Center)
                    .size(width = if (dragging) 48.dp else 36.dp, height = 4.dp)
                    .clip(CircleShape)
                    .background(if (dragging) KbPalette.textAccent else Color.White.copy(alpha = 0.22f)),
            )
        }
        if (dragging) {
            val keyHeight = (dragPitch - OmniKeyboardMetrics.verticalGap(dragPitch.dp).value).roundToInt()
            Text(
                text = "按键高度 ${keyHeight}dp · 双击复原",
                fontSize = 9.5.sp,
                fontWeight = FontWeight.Medium,
                color = KbPalette.textAccent,
                maxLines = 1,
                softWrap = false,
                modifier = Modifier
                    .align(Alignment.CenterEnd)
                    .padding(end = 2.dp),
            )
        }
    }
}

/**
 * Center multi-touch relative Mac trackpad for the SPLIT_TRACKPAD keyboard style:
 * 1-finger drag moves the Mac pointer (gentle acceleration), 1-finger tap clicks, 2-finger tap
 * right-clicks and 2-finger drag scrolls.
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
    var fingers by remember { mutableIntStateOf(0) }
    val shape = RoundedCornerShape(12.dp)

    Box(
        modifier = modifier
            .padding(bottom = 1.5.dp)
            .testTag("omni_split_trackpad")
            .clip(shape)
            .background(Brush.verticalGradient(listOf(Color(0xFF2A2E39), Color(0xFF232731))))
            .border(0.7.dp, Color.White.copy(alpha = if (activeTouchPoint != null) 0.16f else 0.08f), shape)
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
                    fingers = maxPointers

                    while (true) {
                        val event = awaitPointerEvent()
                        event.changes.forEach { it.consume() }
                        val pressedPts = event.changes.mapNotNull { if (it.pressed) it.position else null }
                        if (pressedPts.isEmpty()) break

                        val count = pressedPts.size
                        fingers = count
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
                    fingers = 0
                    val elapsed = System.currentTimeMillis() - startMs
                    val tapSlopPx = 11f * density
                    if (latestEnabled && elapsed <= 270L && totalTravelPx <= tapSlopPx) {
                        latestClick(maxPointers >= 2)
                    }
                }
            },
    ) {
        Canvas(modifier = Modifier.fillMaxSize()) {
            drawRoundRect(
                brush = Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.10f), Color.Transparent), endY = size.height * 0.4f),
                topLeft = Offset(0.5f, 0.5f),
                size = Size(size.width - 1f, size.height - 1f),
                cornerRadius = CornerRadius(12.dp.toPx()),
                style = Stroke(width = 1f),
            )
            activeTouchPoint?.let { pt ->
                drawCircle(Color(0xFF0A84FF).copy(alpha = 0.20f), radius = 22.dp.toPx(), center = pt)
                drawCircle(Color(0xFF8CC8FF).copy(alpha = 0.9f), radius = 4.dp.toPx(), center = pt)
            }
        }
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(2.dp),
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .padding(bottom = 8.dp)
                .graphicsLayer { alpha = if (activeTouchPoint != null) 0.25f else 1f },
        ) {
            Text(
                text = when (fingers) {
                    0, 1 -> "单指移动 · 轻点单击"
                    else -> "双指滚动 · 轻点右键"
                },
                fontSize = 9.sp,
                color = KbPalette.textSecondary.copy(alpha = 0.7f),
                maxLines = 1,
                softWrap = false,
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

private fun View.keyHaptic(kind: KeyHaptic) {
    val constant = when (kind) {
        KeyHaptic.TAP -> HapticFeedbackConstants.KEYBOARD_TAP
        KeyHaptic.TICK -> HapticFeedbackConstants.TEXT_HANDLE_MOVE
        KeyHaptic.CONFIRM ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) HapticFeedbackConstants.CONFIRM
            else HapticFeedbackConstants.LONG_PRESS
        KeyHaptic.TOGGLE -> HapticFeedbackConstants.VIRTUAL_KEY
    }
    performHapticFeedback(constant)
}

// ---------------------------------------------------------------------------------------------
// Previews (render with the Android Compose Preview pane / `android preview render`).
// ---------------------------------------------------------------------------------------------

private fun refAt(rows: List<List<KeySpec>>, deck: Int, row: Int, col: Int) =
    KeyRef(KeyId(deck, row, col), rows[row][col])

@Composable
private fun KeyboardPreviewFrame(
    style: OmniKeyboardStyle,
    rowPitch: Dp,
    enabled: Boolean = true,
    setup: (OmniKeyTouchEngine, OmniModifierController) -> Unit = { _, _ -> },
) {
    Column(Modifier.fillMaxSize().background(Color(0xFF0B0D12))) {
        Spacer(Modifier.weight(1f))
        OmniMacKeyboardImpl(
            style = style,
            enabled = enabled,
            onSendRawKey = { _, _ -> },
            onToggleInputSource = {},
            onTrackpadDelta = { _, _ -> },
            onTrackpadClick = {},
            onTrackpadScroll = { _, _ -> },
            modifier = Modifier.height(OmniKeyboardMetrics.heightFor(style, rowPitch)),
            rowPitch = rowPitch,
            maxRowPitch = OmniKeyboardMetrics.MaxRowPitch,
            onRowPitchChange = { _, _ -> },
            previewSetup = setup,
        )
    }
}

@Preview(name = "Phone · 5 行全键 · ⌘ 单次 + 按下 C", widthDp = 411, heightDp = 360)
@Composable
private fun PreviewCompactPhone() {
    KeyboardPreviewFrame(OmniKeyboardStyle.COMPACT_5_ROW, OmniKeyboardMetrics.DefaultRowPitch) { engine, _ ->
        val rows = OmniMacLayouts.compactRows
        engine.onDown(1, refAt(rows, 0, 4, 3), 0f) // ⌘ tap -> one-shot
        engine.onUp(1)
        engine.onDown(2, refAt(rows, 0, 3, 3), 0f) // C held -> preview bubble "⌘ c"
    }
}

@Preview(name = "Phone · 4 行超薄 · ⇧ 锁定", widthDp = 411, heightDp = 320)
@Composable
private fun PreviewSlimPhone() {
    KeyboardPreviewFrame(OmniKeyboardStyle.SLIM_4_ROW, OmniKeyboardMetrics.DefaultRowPitch) { engine, _ ->
        val rows = OmniMacLayouts.slimAlphaRows
        val shift = refAt(rows, 0, 2, 0)
        engine.onDown(1, shift, 0f); engine.onUp(1)
        engine.onDown(2, shift, 0f); engine.onUp(2)
        engine.onDown(3, refAt(rows, 0, 1, 7), 0f) // J
    }
}

@Preview(name = "Foldable · 分体触控 · fn 按住", widthDp = 840, heightDp = 400)
@Composable
private fun PreviewSplitFoldable() {
    KeyboardPreviewFrame(OmniKeyboardStyle.SPLIT_TRACKPAD, OmniKeyboardMetrics.WideDefaultRowPitch) { engine, _ ->
        engine.onDown(1, refAt(OmniMacLayouts.splitLeftRows, 0, 4, 0), 0f)
    }
}

@Preview(name = "Foldable · 5 行全键 · 未连接", widthDp = 840, heightDp = 400)
@Composable
private fun PreviewCompactFoldableDisabled() {
    KeyboardPreviewFrame(OmniKeyboardStyle.COMPACT_5_ROW, OmniKeyboardMetrics.WideDefaultRowPitch, enabled = false)
}
