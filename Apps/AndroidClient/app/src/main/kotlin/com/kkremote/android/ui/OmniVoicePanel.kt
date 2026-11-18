package com.kkremote.android.ui

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.os.SystemClock
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Mic
import androidx.compose.material.icons.rounded.Stop
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalInspectionMode
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.core.content.ContextCompat
import java.util.Locale

internal enum class VoiceStatus { IDLE, LISTENING, FINISHING }

/**
 * Phone-side dictation for the voice deck. Speech is recognised on the Android device (the Mac's
 * microphone is not near the user) and the text is inserted at the Mac cursor via insertText.
 *
 * One gesture model for the centre mic button and both thumb mic keys:
 * - tap: toggle hands-free listening (auto-restarts after each utterance until tapped again);
 * - hold: push-to-talk, release to finish the utterance.
 *
 * When no system recognition service exists (common on ROMs without Google services) the
 * controller opens a composer dialog instead, where the user dictates with the input method's
 * own voice key and sends the result.
 */
@Stable
internal class VoiceDictationController(
    private val context: Context,
    private val inspectionMode: Boolean,
) {
    var status by mutableStateOf(VoiceStatus.IDLE)
        private set
    var handsFree by mutableStateOf(false)
        private set
    var partial by mutableStateOf("")
        private set
    var draft by mutableStateOf("")
    val history = mutableStateListOf<String>()
    var level by mutableFloatStateOf(0f)
        private set
    var languageTag by mutableStateOf(defaultLanguageTag())
    var autoSend by mutableStateOf(true)
    var message by mutableStateOf<String?>(null)
    var showFallback by mutableStateOf(false)

    var onSendText: (String) -> Unit = {}
    var onSendReturn: () -> Unit = {}
    var requestPermission: () -> Unit = {}
    var isEnabled: () -> Boolean = { true }

    val recognitionAvailable: Boolean by lazy {
        !inspectionMode && runCatching { SpeechRecognizer.isRecognitionAvailable(context) }.getOrDefault(false)
    }

    private var recognizer: SpeechRecognizer? = null
    private var pressedAt = 0L
    private var stopOnRelease = false
    private var restartPending = false

    val isListening: Boolean get() = status != VoiceStatus.IDLE

    /** Shared tap / hold handling for the mic button and the VoiceKey caps. */
    fun press(down: Boolean) {
        val now = SystemClock.uptimeMillis()
        if (down) {
            pressedAt = now
            if (isListening && handsFree) {
                stopOnRelease = true
            } else if (!isListening) {
                start(handsFree = false)
            }
            return
        }
        if (stopOnRelease) {
            stopOnRelease = false
            stop()
            return
        }
        if (!isListening) return
        if (now - pressedAt < TAP_MS) {
            handsFree = true // short tap -> keep listening hands-free
        } else {
            finishUtterance() // push-to-talk released
        }
    }

    fun start(handsFree: Boolean) {
        message = null
        if (!isEnabled()) {
            message = "未连接 Mac，语音暂不可用"
            return
        }
        if (!recognitionAvailable) {
            showFallback = true
            return
        }
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            requestPermission()
            return
        }
        this.handsFree = handsFree
        val r = recognizer ?: SpeechRecognizer.createSpeechRecognizer(context).also {
            it.setRecognitionListener(RecognizerBridge(this))
            recognizer = it
        }
        partial = ""
        status = VoiceStatus.LISTENING
        r.startListening(buildIntent())
    }

    fun onPermissionResult(granted: Boolean) {
        if (granted) start(handsFree = true) else message = "需要麦克风权限才能语音输入"
    }

    fun stop() {
        handsFree = false
        finishUtterance()
    }

    private fun finishUtterance() {
        if (!isListening) return
        status = VoiceStatus.FINISHING
        recognizer?.stopListening()
    }

    fun cancelAll() {
        handsFree = false
        stopOnRelease = false
        restartPending = false
        recognizer?.cancel()
        status = VoiceStatus.IDLE
        partial = ""
        level = 0f
    }

    fun destroy() {
        cancelAll()
        recognizer?.destroy()
        recognizer = null
    }

    fun toggleLanguage() {
        languageTag = if (languageTag.startsWith("zh")) "en-US" else "zh-CN"
        if (isListening) {
            recognizer?.cancel()
            recognizer?.startListening(buildIntent())
        }
    }

    fun sendDraft(withReturn: Boolean) {
        val text = draft.trim()
        if (text.isNotEmpty()) {
            deliver(text, force = true)
            draft = ""
        }
        if (withReturn) onSendReturn()
    }

    /** Text produced by speech (or the fallback composer). */
    fun deliver(text: String, force: Boolean = false) {
        val clean = text.trim()
        if (clean.isEmpty()) return
        if (autoSend || force) {
            val out = if (languageTag.startsWith("en")) "$clean " else clean
            onSendText(out)
            history.add(clean)
            while (history.size > 4) history.removeAt(0)
        } else {
            draft = if (draft.isBlank()) clean else draft.trimEnd() + (if (languageTag.startsWith("en")) " " else "") + clean
        }
    }

    private fun buildIntent(): Intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
        putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
        putExtra(RecognizerIntent.EXTRA_LANGUAGE, languageTag)
        putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
        putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
        putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, context.packageName)
    }

    private fun restartIfHandsFree(): Boolean {
        if (!handsFree || restartPending) return false
        restartPending = true
        status = VoiceStatus.LISTENING
        android.os.Handler(context.mainLooper).postDelayed({
            restartPending = false
            if (handsFree) recognizer?.startListening(buildIntent())
        }, 120L)
        return true
    }

    // Recognizer callbacks (via RecognizerBridge) ----------------------------------------------

    internal fun onReady() {
        if (status == VoiceStatus.IDLE) status = VoiceStatus.LISTENING
    }

    internal fun onLevel(rmsdB: Float) {
        level = ((rmsdB + 2f) / 12f).coerceIn(0f, 1f)
    }

    internal fun onSpeechEnd() {
        level = 0f
    }

    internal fun onRecognizerError(error: Int) {
        level = 0f
        partial = ""
        val benign = error == SpeechRecognizer.ERROR_NO_MATCH || error == SpeechRecognizer.ERROR_SPEECH_TIMEOUT
        if (benign && restartIfHandsFree()) return
        handsFree = false
        status = VoiceStatus.IDLE
        message = when (error) {
            SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "没有听清，请再说一次"
            SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "需要麦克风权限才能语音输入"
            SpeechRecognizer.ERROR_NETWORK, SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "语音识别网络不可用"
            SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "语音识别正忙，请稍后再试"
            SpeechRecognizer.ERROR_CLIENT -> null
            else -> "语音识别出错（$error）"
        }
    }

    internal fun onFinalText(text: String) {
        partial = ""
        level = 0f
        deliver(text)
        if (!restartIfHandsFree()) status = VoiceStatus.IDLE
    }

    internal fun onPartialText(text: String) {
        partial = text
    }

    companion object {
        private const val TAP_MS = 300L

        private fun defaultLanguageTag(): String =
            if (Locale.getDefault().language == "en") "en-US" else "zh-CN"
    }
}

@Composable
internal fun rememberVoiceDictationController(): VoiceDictationController {
    val context = LocalContext.current
    val inspection = LocalInspectionMode.current
    val controller = remember(context) { VoiceDictationController(context.applicationContext, inspection) }
    if (!inspection) {
        val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            controller.onPermissionResult(granted)
        }
        controller.requestPermission = { launcher.launch(Manifest.permission.RECORD_AUDIO) }
    }
    DisposableEffect(controller) { onDispose { controller.destroy() } }
    return controller
}

/** Mic hold/tap gesture shared by the big centre button. */
private fun Modifier.voicePress(controller: VoiceDictationController): Modifier = pointerInput(controller) {
    awaitEachGesture {
        awaitFirstDown(requireUnconsumed = false).consume()
        controller.press(true)
        waitForUpOrCancellation()
        controller.press(false)
    }
}

@Composable
internal fun VoiceDictationPanel(
    controller: VoiceDictationController,
    enabled: Boolean,
    modifier: Modifier = Modifier,
) {
    val skin = LocalKbSkin.current
    val shape = RoundedCornerShape(14.dp)
    val accent = skin.accent.faceBottom

    BoxWithConstraints(
        modifier = modifier
            .padding(bottom = 1.5.dp)
            .clip(shape)
            .background(Brush.verticalGradient(listOf(skin.trackpadTop, skin.trackpadBottom)))
            .border(0.7.dp, skin.trackpadBorder, shape)
            .testTag("omni_voice_panel"),
    ) {
        val compact = maxWidth < 220.dp
        val micSize = (maxHeight * 0.34f).coerceIn(48.dp, 76.dp)
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(horizontal = 10.dp, vertical = 8.dp),
        ) {
            // Header: status + language / auto-send chips.
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                val (statusText, statusColor) = when {
                    !enabled -> "未连接 Mac" to skin.textWarning
                    controller.message != null -> controller.message!! to skin.textWarning
                    controller.status == VoiceStatus.FINISHING -> "识别中…" to skin.textAccent
                    controller.isListening && controller.handsFree -> "正在听写 · 轻点停止" to skin.textAccent
                    controller.isListening -> "正在听 · 松开结束" to skin.textAccent
                    !controller.recognitionAvailable && !LocalInspectionMode.current -> "使用输入法语音" to skin.textSecondary
                    else -> "轻点听写 · 按住说话" to skin.textSecondary
                }
                if (controller.isListening) {
                    Box(Modifier.size(7.dp).clip(CircleShape).background(Color(0xFFFF4D4F)))
                    Spacer(Modifier.width(5.dp))
                }
                Text(
                    text = statusText,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Medium,
                    color = statusColor,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                if (!compact) {
                    VoiceChip(
                        text = if (controller.languageTag.startsWith("zh")) "中文" else "EN",
                        selected = false,
                        onClick = controller::toggleLanguage,
                    )
                    Spacer(Modifier.width(5.dp))
                    VoiceChip(
                        text = "自动发送",
                        selected = controller.autoSend,
                        onClick = { controller.autoSend = !controller.autoSend },
                    )
                }
            }

            // Transcript: sent history (faded), pending draft, live partial.
            val scroll = rememberScrollState()
            LaunchedEffect(controller.partial, controller.draft, controller.history.size) {
                scroll.animateScrollTo(scroll.maxValue)
            }
            Box(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .padding(vertical = 4.dp),
                contentAlignment = Alignment.BottomStart,
            ) {
                val empty = controller.history.isEmpty() && controller.draft.isBlank() && controller.partial.isBlank()
                if (empty) {
                    Text(
                        text = if (compact) "说话即输入" else "说话，文字会直接输入到 Mac 光标处\n两侧拇指键负责删除、换行和快捷组合",
                        fontSize = 12.sp,
                        lineHeight = 17.sp,
                        color = skin.textSecondary,
                        textAlign = TextAlign.Center,
                        modifier = Modifier
                            .fillMaxWidth()
                            .align(Alignment.Center),
                    )
                } else {
                    Column(
                        verticalArrangement = Arrangement.spacedBy(3.dp),
                        modifier = Modifier
                            .fillMaxWidth()
                            .verticalScroll(scroll),
                    ) {
                        for (line in controller.history) {
                            Text("✓ $line", fontSize = 12.sp, color = skin.textSecondary, maxLines = 2, overflow = TextOverflow.Ellipsis)
                        }
                        if (controller.draft.isNotBlank()) {
                            Text(controller.draft, fontSize = 15.sp, color = skin.textPrimary)
                        }
                        if (controller.partial.isNotBlank()) {
                            Text(controller.partial, fontSize = 15.sp, fontStyle = FontStyle.Italic, color = skin.textAccent)
                        }
                    }
                }
            }

            // Controls: clear | mic | send.
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Box(Modifier.weight(1f), contentAlignment = Alignment.CenterStart) {
                    if (controller.draft.isNotBlank() && !compact) {
                        VoiceChip(text = "清空", selected = false, onClick = { controller.draft = "" })
                    }
                }
                MicButton(controller = controller, accent = accent, size = micSize, enabled = enabled)
                Box(Modifier.weight(1f), contentAlignment = Alignment.CenterEnd) {
                    if (controller.draft.isNotBlank() && !compact) {
                        Row(horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                            VoiceChip(text = "发送", selected = false, onClick = { controller.sendDraft(withReturn = false) })
                            VoiceChip(text = "发送⏎", selected = true, onClick = { controller.sendDraft(withReturn = true) })
                        }
                    }
                }
            }
        }
    }

    if (controller.showFallback) {
        ImeVoiceFallbackDialog(controller)
    }
}

@Composable
private fun MicButton(controller: VoiceDictationController, accent: Color, size: androidx.compose.ui.unit.Dp, enabled: Boolean) {
    val listening = controller.isListening
    val level by animateFloatAsState(controller.level, tween(90), label = "micLevel")
    val pulse = rememberInfiniteTransition(label = "micPulse")
    val wave by pulse.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(1400), RepeatMode.Restart),
        label = "micWave",
    )
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .size(size * 1.5f)
            .graphicsLayer { alpha = if (enabled) 1f else 0.5f }
            .voicePress(controller)
            .semantics { contentDescription = if (listening) "停止语音输入" else "语音输入，轻点听写，按住说话" }
            .testTag("omni_voice_mic"),
    ) {
        Canvas(Modifier.fillMaxSize()) {
            val c = Offset(this.size.width / 2f, this.size.height / 2f)
            val base = size.toPx() / 2f
            if (listening) {
                drawCircle(accent.copy(alpha = 0.18f * (1f - wave)), radius = base * (1f + 0.5f * wave), center = c)
                drawCircle(accent.copy(alpha = 0.28f), radius = base * (1.05f + 0.35f * level), center = c)
            }
            drawCircle(Color.Black.copy(alpha = 0.18f), radius = base, center = c + Offset(0f, 2.dp.toPx()))
            drawCircle(
                Brush.verticalGradient(listOf(accent.copy(alpha = 0.92f), accent), startY = c.y - base, endY = c.y + base),
                radius = base,
                center = c,
            )
            drawCircle(Color.White.copy(alpha = 0.35f), radius = base - 0.5f, center = c, style = Stroke(1f))
        }
        Icon(
            imageVector = if (listening && controller.handsFree) Icons.Rounded.Stop else Icons.Rounded.Mic,
            contentDescription = null,
            tint = Color.White,
            modifier = Modifier.size(size * 0.45f),
        )
    }
}

@Composable
private fun VoiceChip(text: String, selected: Boolean, onClick: () -> Unit) {
    val skin = LocalKbSkin.current
    val shape = RoundedCornerShape(50)
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .height(24.dp)
            .clip(shape)
            .background(if (selected) skin.accent.faceBottom else skin.func.faceBottom)
            .border(0.6.dp, skin.trackpadBorder, shape)
            .clickable(onClick = onClick)
            .padding(horizontal = 9.dp),
    ) {
        Text(
            text = text,
            fontSize = 11.sp,
            fontWeight = FontWeight.Medium,
            color = if (selected) skin.accent.legend else skin.func.legend,
            maxLines = 1,
        )
    }
}

/** No system recognizer: dictate with the input method's voice key inside a focused composer. */
@Composable
private fun ImeVoiceFallbackDialog(controller: VoiceDictationController) {
    var text by remember { mutableStateOf("") }
    val focus = remember { FocusRequester() }
    Dialog(onDismissRequest = { controller.showFallback = false }) {
        Column(
            modifier = Modifier
                .clip(RoundedCornerShape(18.dp))
                .background(Color(0xFFF7F6F3))
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text("语音输入", fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = Color(0xFF2E2C28))
            Text(
                "本机没有系统语音识别服务。请点输入法键盘上的麦克风说话，识别完成后发送到 Mac。",
                fontSize = 12.5.sp,
                color = Color(0xFF6E6A62),
            )
            OutlinedTextField(
                value = text,
                onValueChange = { text = it },
                minLines = 2,
                maxLines = 5,
                modifier = Modifier
                    .fillMaxWidth()
                    .focusRequester(focus)
                    .testTag("omni_voice_fallback_field"),
            )
            Row(horizontalArrangement = Arrangement.End, modifier = Modifier.fillMaxWidth()) {
                TextButton(onClick = { controller.showFallback = false }) { Text("关闭") }
                TextButton(onClick = {
                    controller.deliver(text, force = true)
                    text = ""
                }) { Text("发送") }
                TextButton(onClick = {
                    controller.deliver(text, force = true)
                    controller.onSendReturn()
                    text = ""
                }) { Text("发送并回车") }
            }
        }
    }
    LaunchedEffect(Unit) { runCatching { focus.requestFocus() } }
}

/**
 * Separate listener so android.speech classes are only loaded once dictation actually starts
 * (keeps the keyboard composable free of speech dependencies, e.g. in layout previews).
 */
private class RecognizerBridge(private val c: VoiceDictationController) : RecognitionListener {
    override fun onReadyForSpeech(params: Bundle?) = c.onReady()
    override fun onBeginningOfSpeech() = Unit
    override fun onRmsChanged(rmsdB: Float) = c.onLevel(rmsdB)
    override fun onBufferReceived(buffer: ByteArray?) = Unit
    override fun onEndOfSpeech() = c.onSpeechEnd()
    override fun onError(error: Int) = c.onRecognizerError(error)
    override fun onResults(results: Bundle?) =
        c.onFinalText(results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull().orEmpty())
    override fun onPartialResults(partialResults: Bundle?) =
        c.onPartialText(partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull().orEmpty())
    override fun onEvent(eventType: Int, params: Bundle?) = Unit
}
