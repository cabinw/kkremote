package com.kkremote.keyboardtest

import android.app.Activity
import android.content.Context
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.view.WindowCompat
import kotlinx.coroutines.launch
import com.kkremote.android.ui.OmniKeyboardMetrics
import com.kkremote.android.ui.OmniKeyboardStyle
import com.kkremote.android.ui.OmniKeyboardTheme
import com.kkremote.android.ui.OmniMacKeyboard
import com.kkremote.android.ui.omniKeyboardTrayColor

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        setContent { KeyboardPlayground() }
    }
}

private data class StageColors(
    val page: Color,
    val desktopTop: Color,
    val desktopBottom: Color,
    val window: Color,
    val titleBar: Color,
    val text: Color,
    val secondary: Color,
    val accent: Color,
    val selection: Color,
    val chip: Color,
    val chipSelected: Color,
    val chipText: Color,
    val chipSelectedText: Color,
    val light: Boolean,
)

private fun stageColors(theme: OmniKeyboardTheme): StageColors = when (theme) {
    OmniKeyboardTheme.GRAPHITE -> StageColors(
        page = Color(0xFF0B0D12),
        desktopTop = Color(0xFF1B2A44), desktopBottom = Color(0xFF0F1626),
        window = Color(0xFF1E2129), titleBar = Color(0xFF2A2E38),
        text = Color(0xFFEDEFF4), secondary = Color(0xFF8E97AA), accent = Color(0xFF4DA3FF),
        selection = Color(0xFF2E5A99),
        chip = Color(0xFF1E222B), chipSelected = Color(0xFF2E8BFF), chipText = Color(0xFFD5DCEB), chipSelectedText = Color.White,
        light = false,
    )
    OmniKeyboardTheme.MECHANICAL_LIGHT -> StageColors(
        page = Color(0xFFF1EFEA),
        desktopTop = Color(0xFFE9D9C4), desktopBottom = Color(0xFFD9C4A8),
        window = Color(0xFFFFFFFF), titleBar = Color(0xFFF2F0EC),
        text = Color(0xFF2E2C28), secondary = Color(0xFF8C877C), accent = Color(0xFFD0632A),
        selection = Color(0xFFF7C9A8),
        chip = Color(0xFFE3E0D9), chipSelected = Color(0xFFE2733A), chipText = Color(0xFF34322D), chipSelectedText = Color.White,
        light = true,
    )
}

private class PlaygroundPrefs(context: Context) {
    private val sp = context.getSharedPreferences("keyboard-test", Context.MODE_PRIVATE)
    var style: OmniKeyboardStyle
        get() = runCatching { OmniKeyboardStyle.valueOf(sp.getString("style", null)!!) }.getOrDefault(OmniKeyboardStyle.SPLIT_TRACKPAD)
        set(v) = sp.edit().putString("style", v.name).apply()
    var theme: OmniKeyboardTheme
        get() = runCatching { OmniKeyboardTheme.valueOf(sp.getString("theme", null)!!) }.getOrDefault(OmniKeyboardTheme.MECHANICAL_LIGHT)
        set(v) = sp.edit().putString("theme", v.name).apply()
    var rowPitch: Float?
        get() = sp.getFloat("rowPitch", -1f).takeIf { it > 0f }
        set(v) = sp.edit().putFloat("rowPitch", v ?: -1f).apply()
}

@Composable
fun KeyboardPlayground() {
    val context = LocalContext.current
    val prefs = remember { PlaygroundPrefs(context) }
    var style by remember { mutableStateOf(prefs.style) }
    var theme by remember { mutableStateOf(prefs.theme) }
    var rowPitch by remember { mutableStateOf(prefs.rowPitch) }
    var connected by remember { mutableStateOf(true) }
    val sim = remember { MacTextSimulator() }
    var simRevision by remember { mutableIntStateOf(0) }
    var pointer by remember { mutableStateOf(Offset(0.62f, 0.4f)) }
    var clickFlash by remember { mutableStateOf<String?>(null) }
    var clickFlashId by remember { mutableIntStateOf(0) }
    val editorScroll = rememberScrollState()
    val scope = rememberCoroutineScope()
    val colors = stageColors(theme)

    val view = LocalView.current
    SideEffect {
        val window = (view.context as? Activity)?.window ?: return@SideEffect
        WindowCompat.getInsetsController(window, view).apply {
            isAppearanceLightStatusBars = colors.light
            isAppearanceLightNavigationBars = colors.light
        }
    }

    val statusTop = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
    val navBottom = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()

    BoxWithConstraints(
        modifier = Modifier
            .fillMaxSize()
            .background(colors.page),
    ) {
        val headerH = 92.dp
        val minStage = 150.dp
        val rows = OmniKeyboardMetrics.rowCount(style)
        val maxPitch = ((maxHeight - statusTop - headerH - navBottom - minStage - OmniKeyboardMetrics.ChromeHeight) / rows)
            .coerceIn(OmniKeyboardMetrics.MinRowPitch, OmniKeyboardMetrics.MaxRowPitch)
        val pitch: Dp = (rowPitch?.dp ?: OmniKeyboardMetrics.defaultRowPitch(maxWidth))
            .coerceIn(OmniKeyboardMetrics.MinRowPitch, maxPitch)
        val keyboardH = OmniKeyboardMetrics.heightFor(style, pitch)

        Column(Modifier.fillMaxSize()) {
            Spacer(Modifier.height(statusTop))
            PlaygroundHeader(
                style = style,
                theme = theme,
                connected = connected,
                colors = colors,
                onStyle = { style = it; prefs.style = it },
                onTheme = { theme = it; prefs.theme = it },
                onConnected = { connected = it },
                onClear = { sim.clear(); simRevision++ },
                modifier = Modifier
                    .fillMaxWidth()
                    .height(headerH),
            )
            MockMacStage(
                sim = sim,
                revision = simRevision,
                editorScroll = editorScroll,
                pointer = pointer,
                clickFlash = clickFlash,
                colors = colors,
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f)
                    .padding(horizontal = 10.dp, vertical = 6.dp),
            )
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(keyboardH + navBottom)
                    .background(omniKeyboardTrayColor(theme))
                    .padding(bottom = navBottom),
            ) {
                OmniMacKeyboard(
                    style = style,
                    enabled = connected,
                    onSendRawKey = { code, mods -> sim.onRawKey(code, mods); simRevision++ },
                    onToggleInputSource = { sim.toggleInputSource(); simRevision++ },
                    onTrackpadDelta = { dx, dy ->
                        pointer = Offset(
                            (pointer.x + dx / 900f).coerceIn(0f, 1f),
                            (pointer.y + dy / 520f).coerceIn(0f, 1f),
                        )
                    },
                    onTrackpadClick = { secondary ->
                        clickFlash = if (secondary) "右键" else "单击"
                        clickFlashId++
                    },
                    onTrackpadScroll = { _, dy ->
                        scope.launch { editorScroll.scrollBy(-dy.toFloat() * 3f) }
                        if (clickFlash != "双指滚动") clickFlash = "双指滚动"
                        clickFlashId++
                    },
                    modifier = Modifier.fillMaxSize(),
                    rowPitch = pitch,
                    maxRowPitch = maxPitch,
                    onRowPitchChange = { p, final ->
                        rowPitch = p?.value
                        if (final) prefs.rowPitch = p?.value
                    },
                    theme = theme,
                    onSendText = { sim.insertText(it); simRevision++ },
                )
            }
        }
    }

    LaunchedEffect(clickFlash, clickFlashId) {
        if (clickFlash != null) {
            kotlinx.coroutines.delay(650)
            clickFlash = null
        }
    }
}

@Composable
private fun PlaygroundHeader(
    style: OmniKeyboardStyle,
    theme: OmniKeyboardTheme,
    connected: Boolean,
    colors: StageColors,
    onStyle: (OmniKeyboardStyle) -> Unit,
    onTheme: (OmniKeyboardTheme) -> Unit,
    onConnected: (Boolean) -> Unit,
    onClear: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier.padding(horizontal = 12.dp, vertical = 6.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Keyboard Test", fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = colors.text)
            Spacer(Modifier.width(8.dp))
            Text(style.fullLabel, fontSize = 11.5.sp, color = colors.secondary, maxLines = 1, modifier = Modifier.weight(1f))
            Chip("连接", connected, colors) { onConnected(!connected) }
            Spacer(Modifier.width(6.dp))
            Chip("清空", false, colors, onClear)
        }
        Row(
            modifier = Modifier.horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            for (s in OmniKeyboardStyle.entries) Chip(s.shortLabel, s == style, colors) { onStyle(s) }
            Box(Modifier.width(1.dp).height(18.dp).background(colors.secondary.copy(alpha = 0.4f)))
            for (t in OmniKeyboardTheme.entries) Chip(t.shortLabel, t == theme, colors) { onTheme(t) }
        }
    }
}

@Composable
private fun Chip(text: String, selected: Boolean, colors: StageColors, onClick: () -> Unit) {
    val shape = RoundedCornerShape(50)
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .height(32.dp)
            .clip(shape)
            .background(if (selected) colors.chipSelected else colors.chip)
            .clickable(onClick = onClick)
            .padding(horizontal = 13.dp),
    ) {
        Text(
            text,
            fontSize = 13.sp,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Medium,
            color = if (selected) colors.chipSelectedText else colors.chipText,
            maxLines = 1,
        )
    }
}

@Composable
private fun MockMacStage(
    sim: MacTextSimulator,
    revision: Int,
    editorScroll: ScrollState,
    pointer: Offset,
    clickFlash: String?,
    colors: StageColors,
    modifier: Modifier = Modifier,
) {
    val shape = RoundedCornerShape(14.dp)
    Box(
        modifier = modifier
            .clip(shape)
            .background(Brush.linearGradient(listOf(colors.desktopTop, colors.desktopBottom))),
    ) {
        // Simulated TextEdit window.
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(14.dp)
                .shadow(16.dp, RoundedCornerShape(10.dp))
                .clip(RoundedCornerShape(10.dp))
                .background(colors.window),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .background(colors.titleBar)
                    .padding(horizontal = 10.dp, vertical = 7.dp),
            ) {
                for (c in listOf(Color(0xFFFF5F57), Color(0xFFFEBC2E), Color(0xFF28C840))) {
                    Box(Modifier.size(10.dp).clip(CircleShape).background(c))
                    Spacer(Modifier.width(6.dp))
                }
                Text(
                    "未命名.txt — 模拟 Mac 输入",
                    fontSize = 12.sp,
                    color = colors.secondary,
                    modifier = Modifier.weight(1f).padding(start = 6.dp),
                    maxLines = 1,
                )
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier
                        .size(22.dp)
                        .clip(RoundedCornerShape(5.dp))
                        .border(1.dp, colors.secondary.copy(alpha = 0.6f), RoundedCornerShape(5.dp)),
                ) {
                    Text(if (sim.chineseInput) "中" else "A", fontSize = 11.sp, color = colors.text)
                }
            }
            EditorBody(sim, revision, editorScroll, colors, Modifier.weight(1f).fillMaxWidth())
            EventStrip(sim, revision, colors)
        }

        // Trackpad pointer.
        BoxWithConstraints(Modifier.fillMaxSize()) {
            val x = maxWidth * pointer.x
            val y = maxHeight * pointer.y
            Canvas(Modifier.padding(start = x, top = y).size(18.dp)) {
                val p = Path().apply {
                    moveTo(0f, 0f); lineTo(0f, size.height); lineTo(size.width * 0.32f, size.height * 0.72f)
                    lineTo(size.width * 0.72f, size.height * 0.72f); close()
                }
                drawPath(p, Color.Black)
                drawPath(p, Color.White, style = androidx.compose.ui.graphics.drawscope.Stroke(1.5f))
            }
            if (clickFlash != null) {
                Text(
                    clickFlash,
                    fontSize = 11.sp,
                    color = Color.White,
                    modifier = Modifier
                        .padding(start = x + 16.dp, top = y + 14.dp)
                        .clip(RoundedCornerShape(6.dp))
                        .background(Color.Black.copy(alpha = 0.6f))
                        .padding(horizontal = 6.dp, vertical = 2.dp),
                )
            }
        }
    }
}

@Composable
private fun EditorBody(
    sim: MacTextSimulator,
    revision: Int,
    scroll: ScrollState,
    colors: StageColors,
    modifier: Modifier,
) {
    val blink = rememberInfiniteTransition(label = "caret")
    val caretAlpha by blink.animateFloat(
        initialValue = 1f,
        targetValue = 0f,
        animationSpec = infiniteRepeatable(tween(530), RepeatMode.Reverse),
        label = "caretAlpha",
    )
    LaunchedEffect(revision) { scroll.animateScrollTo(scroll.maxValue) }

    val text = sim.text
    val sel = sim.selection
    val annotated = buildAnnotatedString {
        if (text.isEmpty() && sel == null) {
            withStyle(SpanStyle(color = colors.accent.copy(alpha = caretAlpha))) { append("│") }
            withStyle(SpanStyle(color = colors.secondary)) {
                append("在下方键盘上打字，或切到「语音」说话。⌘Z / ⌥⌫ / 方向键都会在这里生效。")
            }
            return@buildAnnotatedString
        }
        for (i in 0..text.length) {
            if (i == sim.cursor && sel == null) {
                withStyle(SpanStyle(color = colors.accent.copy(alpha = caretAlpha))) { append("│") }
            }
            if (i == text.length) break
            val inSel = sel != null && i in sel
            if (inSel) withStyle(SpanStyle(background = colors.selection)) { append(text[i]) } else append(text[i])
        }
    }
    Box(modifier.verticalScroll(scroll).padding(horizontal = 14.dp, vertical = 10.dp)) {
        Text(annotated, fontSize = 17.sp, lineHeight = 25.sp, color = colors.text)
    }
}

@Composable
private fun EventStrip(sim: MacTextSimulator, revision: Int, colors: StageColors) {
    val scroll = rememberScrollState()
    LaunchedEffect(revision) { scroll.animateScrollTo(scroll.maxValue) }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(colors.titleBar)
            .horizontalScroll(scroll)
            .padding(horizontal = 8.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(5.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text("发送到 Mac:", fontSize = 10.5.sp, color = colors.secondary)
        val events = sim.recentEvents
        if (events.isEmpty()) {
            Text("—", fontSize = 11.sp, color = colors.secondary)
        }
        events.forEachIndexed { i, e ->
            val latest = i == events.lastIndex
            Text(
                e,
                fontSize = 11.sp,
                fontFamily = FontFamily.Monospace,
                color = if (latest) colors.chipSelectedText else colors.chipText,
                maxLines = 1,
                modifier = Modifier
                    .clip(RoundedCornerShape(5.dp))
                    .background(if (latest) colors.chipSelected else colors.chip)
                    .padding(horizontal = 6.dp, vertical = 2.dp),
            )
        }
    }
}
