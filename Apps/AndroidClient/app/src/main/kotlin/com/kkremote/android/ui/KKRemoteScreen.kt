package com.kkremote.android.ui

import android.content.ClipboardManager
import android.content.Context
import android.graphics.Rect as AndroidRect
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AddLink
import androidx.compose.material.icons.filled.Analytics
import androidx.compose.material.icons.filled.AspectRatio
import androidx.compose.material.icons.filled.ContentPaste
import androidx.compose.material.icons.filled.DeleteOutline
import androidx.compose.material.icons.filled.DesktopMac
import androidx.compose.material.icons.filled.Keyboard
import androidx.compose.material.icons.filled.KeyboardHide
import androidx.compose.material.icons.filled.LinkOff
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.Mouse
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.TouchApp
import androidx.compose.material.icons.automirrored.filled.ViewSidebar
import androidx.compose.material.icons.filled.Window
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.VerticalDivider
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.kkremote.android.gesture.GestureAction
import com.kkremote.android.gesture.InteractionGestureMachine
import com.kkremote.android.gesture.TouchContact
import com.kkremote.android.gesture.TouchPoint
import com.kkremote.android.protocol.RemoteWindow
import com.kkremote.android.protocol.TrustedHostProfile
import com.kkremote.android.ui.theme.AmberWait
import com.kkremote.android.ui.theme.CoralAlert
import com.kkremote.android.ui.theme.ElectricAccent
import com.kkremote.android.ui.theme.EmeraldLive
import com.kkremote.android.ui.theme.StudioBorder
import com.kkremote.android.ui.theme.StudioCanvas
import com.kkremote.android.ui.theme.StudioSurface
import com.kkremote.android.ui.theme.StudioSurfaceElevated
import com.kkremote.android.ui.theme.TextPrimary
import com.kkremote.android.ui.theme.TextSecondary
import org.webrtc.VideoTrack
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

private data class StageTransform(
    val left0: Float,
    val top0: Float,
    val drawW: Float,
    val drawH: Float,
    val centerX: Float,
    val centerY: Float,
    val zoom: Float,
    val panX: Float,
    val panY: Float,
) {
    fun screenToNormalized(screenX: Float, screenY: Float): Pair<Float, Float>? {
        if (drawW <= 1f || drawH <= 1f || zoom <= 0.01f) return null
        val baseX = (screenX - panX - centerX) / zoom + centerX
        val baseY = (screenY - panY - centerY) / zoom + centerY
        val u = (baseX - left0) / drawW
        val v = (baseY - top0) / drawH
        if (u < 0f || u >= 1f || v < 0f || v >= 1f) return null
        return u to v
    }

    fun normalizedToScreen(u: Float, v: Float): Offset {
        val baseX = left0 + u * drawW
        val baseY = top0 + v * drawH
        return Offset(
            x = centerX + (baseX - centerX) * zoom + panX,
            y = centerY + (baseY - centerY) * zoom + panY,
        )
    }

    fun effectivePointsPerScreenPixel(winWidthPt: Double): Float {
        if (drawW <= 1f || zoom <= 0.01f) return 1f
        return (winWidthPt.toFloat()) / (drawW * zoom)
    }
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalComposeUiApi::class)
@Composable
fun KKRemoteScreen(viewModel: WorkspaceViewModel) {
    val state by viewModel.uiState.collectAsState()
    val videoTrack by viewModel.videoTrack.collectAsState()

    BoxWithConstraints(
        modifier = Modifier
            .fillMaxSize()
            .background(StudioCanvas)
            .semantics { testTagsAsResourceId = true }
            .imePadding()
    ) {
        val isLargeFoldableScreen = maxWidth >= 600.dp

        Row(modifier = Modifier.fillMaxSize()) {
            // Adaptive Foldable Left Rail for OPPO Find N6 Unfolded Display
            if (isLargeFoldableScreen && state.sidebarExpandedOnLargeScreen) {
                FoldableWindowSidebar(
                    state = state,
                    onSelectWindow = viewModel::selectWindow,
                    onRefreshWindows = viewModel::refreshWindows,
                    onOpenPairing = { viewModel.setShowPairingSheet(true) },
                    onOpenTelemetry = { viewModel.setShowTelemetrySheet(true) },
                )
                VerticalDivider(color = StudioBorder, thickness = 1.dp)
            }

            // Main Interactive Mac Window Stage
            Column(modifier = Modifier.weight(1f).fillMaxHeight()) {
                Box(modifier = Modifier.weight(1f).fillMaxWidth()) {
                    RemoteWindowStage(
                        state = state,
                        videoTrack = videoTrack,
                        onVideoSizeChanged = viewModel::onVideoSizeChanged,
                        onZoomAndPan = viewModel::updateZoomAndPan,
                        onMoveTrackpadCursor = viewModel::moveTrackpadCursor,
                        onRemoteClick = viewModel::sendRemoteClick,
                        onRemoteScroll = viewModel::queueRemoteScroll,
                        onOpenPairing = { viewModel.setShowPairingSheet(true) },
                        onOpenWindows = { viewModel.setShowWindowSheet(true) },
                        onReconnect = viewModel::reconnectActiveHost,
                    )

                    // Top Floating Telemetry & Host Status Capsule
                    TopStatusOverlay(
                        state = state,
                        isLargeScreen = isLargeFoldableScreen,
                        onToggleSidebar = viewModel::toggleLargeScreenSidebar,
                        onOpenTelemetry = { viewModel.setShowTelemetrySheet(true) },
                        onOpenPairing = { viewModel.setShowPairingSheet(true) },
                    )

                    // Draggable Bottom-Right Floating Capsule Dock (mirrors iOS IPhoneWindowWorkspace)
                    FloatingControlDock(
                        state = state,
                        isLargeScreen = isLargeFoldableScreen,
                        onToggleKeyboard = { viewModel.setShowKeyboardBar(!state.showKeyboardBar) },
                        onOpenWindows = { viewModel.setShowWindowSheet(true) },
                        onTogglePointerMode = viewModel::togglePointerMode,
                        onSetScaleMode = viewModel::setScaleMode,
                        onResetViewport = viewModel::resetViewport,
                        onOpenTelemetry = { viewModel.setShowTelemetrySheet(true) },
                        onOpenPairing = { viewModel.setShowPairingSheet(true) },
                        onDisconnect = viewModel::disconnect,
                        modifier = Modifier.align(Alignment.BottomEnd),
                    )
                }

                // Collapsible Direct CJK/English IME & macOS Function Key Bar
                AnimatedVisibility(visible = state.showKeyboardBar) {
                    MacKeyboardComposerBar(
                        canControl = state.canControl,
                        onSendText = viewModel::sendRemoteText,
                        onSendKey = viewModel::sendRemoteKey,
                        onClose = { viewModel.setShowKeyboardBar(false) },
                    )
                }
            }
        }

        if (state.showPairingSheet) {
            ModalBottomSheet(
                onDismissRequest = { viewModel.setShowPairingSheet(false) },
                sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
                containerColor = StudioSurface,
                contentColor = TextPrimary,
            ) {
                PairingAndHostsSheet(
                    state = state,
                    onImportLink = { link, coord -> viewModel.importPairingLink(link, coord) },
                    onConnectSaved = viewModel::connectToHost,
                    onRemoveSaved = viewModel::removeHost,
                    onClose = { viewModel.setShowPairingSheet(false) },
                )
            }
        }

        if (state.showWindowSheet) {
            ModalBottomSheet(
                onDismissRequest = { viewModel.setShowWindowSheet(false) },
                sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
                containerColor = StudioSurface,
                contentColor = TextPrimary,
            ) {
                WindowCatalogSheet(
                    state = state,
                    onRefresh = viewModel::refreshWindows,
                    onSelect = viewModel::selectWindow,
                )
            }
        }

        if (state.showTelemetrySheet) {
            ModalBottomSheet(
                onDismissRequest = { viewModel.setShowTelemetrySheet(false) },
                sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
                containerColor = StudioSurface,
                contentColor = TextPrimary,
            ) {
                TelemetryDiagnosticsSheet(
                    state = state,
                    onSetScaleMode = viewModel::setScaleMode,
                    onTogglePreferHdr = viewModel::togglePreferHdr,
                    onReconnect = viewModel::reconnectActiveHost,
                )
            }
        }
    }
}

@Composable
private fun RemoteWindowStage(
    state: WorkspaceUiState,
    videoTrack: VideoTrack?,
    onVideoSizeChanged: (Int, Int) -> Unit,
    onZoomAndPan: (Float, Float, Float) -> Unit,
    onMoveTrackpadCursor: (Float, Float) -> Unit,
    onRemoteClick: (Double, Double, Boolean, Float, Float) -> Unit,
    onRemoteScroll: (Double, Double, Double, Double) -> Unit,
    onOpenPairing: () -> Unit,
    onOpenWindows: () -> Unit,
    onReconnect: () -> Unit,
) {
    val haptics = LocalHapticFeedback.current
    val hostView = LocalView.current
    var stageSize by remember { mutableStateOf(IntSize.Zero) }
    val gestureMachine = remember { InteractionGestureMachine() }

    LaunchedEffect(state.inputMode) {
        gestureMachine.relativeTrackpad = state.inputMode == PointerInputMode.TRACKPAD
        gestureMachine.directScroll = state.inputMode == PointerInputMode.DIRECT_TOUCH
        gestureMachine.reset()
    }

    // Prevent Android edge back-swipe from stealing remote trackpad / touch gestures when controlling a window
    LaunchedEffect(stageSize, state.hasLiveVideo, state.canControl) {
        if (stageSize.width > 0 && stageSize.height > 0 && state.hasLiveVideo && state.canControl) {
            val edgePx = 64
            hostView.systemGestureExclusionRects = listOf(
                AndroidRect(0, 0, edgePx, stageSize.height),
                AndroidRect(max(0, stageSize.width - edgePx), 0, stageSize.width, stageSize.height),
            )
        } else {
            hostView.systemGestureExclusionRects = emptyList()
        }
    }

    val vidW = max(1, state.videoWidthPx)
    val vidH = max(1, state.videoHeightPx)
    val stW = stageSize.width.toFloat()
    val stH = stageSize.height.toFloat()

    val (drawW, drawH) = remember(stW, stH, vidW, vidH, state.scaleMode) {
        if (stW <= 1f || stH <= 1f) {
            0f to 0f
        } else {
            when (state.scaleMode) {
                CanvasScaleMode.FIT -> {
                    val s = min(stW / vidW, stH / vidH)
                    (vidW * s) to (vidH * s)
                }
                CanvasScaleMode.FILL -> {
                    val s = max(stW / vidW, stH / vidH)
                    (vidW * s) to (vidH * s)
                }
                CanvasScaleMode.PIXEL_1X -> vidW.toFloat() to vidH.toFloat()
            }
        }
    }

    val transform = StageTransform(
        left0 = (stW - drawW) * 0.5f,
        top0 = (stH - drawH) * 0.5f,
        drawW = drawW,
        drawH = drawH,
        centerX = stW * 0.5f,
        centerY = stH * 0.5f,
        zoom = state.zoom,
        panX = state.panX,
        panY = state.panY,
    )

    var latestTransform by remember { mutableStateOf(transform) }
    latestTransform = transform
    var latestState by remember { mutableStateOf(state) }
    latestState = state

    val rippleAnim = remember { Animatable(0f) }
    LaunchedEffect(state.lastRipple?.id) {
        if (state.lastRipple != null) {
            rippleAnim.snapTo(0f)
            rippleAnim.animateTo(1f, tween(durationMillis = 240))
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .onSizeChanged { stageSize = it }
            .testTag("remoteWindowStage")
            .pointerInput(Unit) {
                var scrollAnchorPt: Pair<Double, Double>? = null
                awaitEachGesture {
                    do {
                        val event = awaitPointerEvent()
                        val timeSec = (event.changes.firstOrNull()?.uptimeMillis ?: System.currentTimeMillis()) / 1000.0
                        val activeContacts = event.changes
                            .filter { it.pressed }
                            .map { ch ->
                                ch.consume()
                                TouchContact(ch.id.value.toInt(), TouchPoint(ch.position.x, ch.position.y))
                            }
                        val actions = gestureMachine.update(activeContacts, timeSec)
                        val curState = latestState
                        val curTransform = latestTransform
                        val win = curState.selectedWindow

                        for (act in actions) {
                            when (act) {
                                is GestureAction.Zoom -> onZoomAndPan(act.factor, 0f, 0f)
                                is GestureAction.Pan -> onZoomAndPan(1.0f, act.delta.dx, act.delta.dy)
                                is GestureAction.RelativeMove -> {
                                    if (win != null) {
                                        val ptsPerPx = curTransform.effectivePointsPerScreenPixel(win.widthPoints) * 1.15f
                                        onMoveTrackpadCursor(act.delta.dx * ptsPerPx, act.delta.dy * ptsPerPx)
                                    }
                                }
                                is GestureAction.Tap -> {
                                    if (win != null && curState.hasLiveVideo) {
                                        if (curState.inputMode == PointerInputMode.TRACKPAD) {
                                            val cur = curState.trackpadCursorPt
                                                ?: TouchPoint((win.widthPoints * 0.5).toFloat(), (win.heightPoints * 0.5).toFloat())
                                            val scr = curTransform.normalizedToScreen(
                                                (cur.x / win.widthPoints.toFloat()).coerceIn(0f, 1f),
                                                (cur.y / win.heightPoints.toFloat()).coerceIn(0f, 1f),
                                            )
                                            haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                                            onRemoteClick(cur.x.toDouble(), cur.y.toDouble(), false, scr.x, scr.y)
                                        } else {
                                            curTransform.screenToNormalized(act.point.x, act.point.y)?.let { (u, v) ->
                                                haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                                                onRemoteClick(
                                                    u * win.widthPoints,
                                                    v * win.heightPoints,
                                                    false,
                                                    act.point.x,
                                                    act.point.y,
                                                )
                                            }
                                        }
                                    }
                                }
                                is GestureAction.SecondaryClick -> {
                                    if (win != null && curState.hasLiveVideo) {
                                        if (curState.inputMode == PointerInputMode.TRACKPAD) {
                                            val cur = curState.trackpadCursorPt
                                                ?: TouchPoint((win.widthPoints * 0.5).toFloat(), (win.heightPoints * 0.5).toFloat())
                                            val scr = curTransform.normalizedToScreen(
                                                (cur.x / win.widthPoints.toFloat()).coerceIn(0f, 1f),
                                                (cur.y / win.heightPoints.toFloat()).coerceIn(0f, 1f),
                                            )
                                            haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                                            onRemoteClick(cur.x.toDouble(), cur.y.toDouble(), true, scr.x, scr.y)
                                        } else {
                                            curTransform.screenToNormalized(act.point.x, act.point.y)?.let { (u, v) ->
                                                haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                                                onRemoteClick(
                                                    u * win.widthPoints,
                                                    v * win.heightPoints,
                                                    true,
                                                    act.point.x,
                                                    act.point.y,
                                                )
                                            }
                                        }
                                    }
                                }
                                is GestureAction.ScrollBegan -> {
                                    if (win != null) {
                                        scrollAnchorPt = if (curState.inputMode == PointerInputMode.TRACKPAD) {
                                            val cur = curState.trackpadCursorPt
                                                ?: TouchPoint((win.widthPoints * 0.5).toFloat(), (win.heightPoints * 0.5).toFloat())
                                            cur.x.toDouble() to cur.y.toDouble()
                                        } else {
                                            curTransform.screenToNormalized(act.origin.x, act.origin.y)?.let { (u, v) ->
                                                (u * win.widthPoints) to (v * win.heightPoints)
                                            }
                                        }
                                    }
                                }
                                is GestureAction.Scroll -> {
                                    val anchor = scrollAnchorPt
                                    if (win != null && anchor != null) {
                                        val ptsPerPx = curTransform.effectivePointsPerScreenPixel(win.widthPoints)
                                        onRemoteScroll(
                                            anchor.first,
                                            anchor.second,
                                            (act.delta.dx * ptsPerPx).toDouble(),
                                            (act.delta.dy * ptsPerPx).toDouble(),
                                        )
                                    }
                                }
                                GestureAction.ScrollEnded, GestureAction.Cancel -> {
                                    scrollAnchorPt = null
                                }
                            }
                        }
                    } while (event.changes.any { it.pressed })
                }
            }
    ) {
        val density = LocalDensity.current
        if (videoTrack != null && drawW > 1f && drawH > 1f) {
            val drawWDp = with(density) { drawW.toDp() }
            val drawHDp = with(density) { drawH.toDp() }
            AndroidView(
                factory = { ctx ->
                    WebRtcTextureView(ctx).apply {
                        onVideoDimensionsChanged = onVideoSizeChanged
                        bindTrack(videoTrack)
                    }
                },
                update = { view ->
                    view.onVideoDimensionsChanged = onVideoSizeChanged
                    view.bindTrack(videoTrack)
                },
                modifier = Modifier
                    .align(Alignment.Center)
                    .size(drawWDp, drawHDp)
                    .graphicsLayer {
                        scaleX = state.zoom
                        scaleY = state.zoom
                        translationX = state.panX
                        translationY = state.panY
                    }
                    .clip(RoundedCornerShape(if (state.scaleMode == CanvasScaleMode.FIT) 6.dp else 0.dp)),
            )
        }

        // Empty / Connecting / Select-Window Placeholder State
        if (!state.hasLiveVideo) {
            EmptyStageOverlay(
                state = state,
                onOpenPairing = onOpenPairing,
                onOpenWindows = onOpenWindows,
                onReconnect = onReconnect,
                modifier = Modifier.align(Alignment.Center),
            )
        }

        // Virtual macOS Trackpad Cursor + Click Ripple Overlay
        Canvas(modifier = Modifier.fillMaxSize()) {
            val ripple = state.lastRipple
            if (ripple != null && rippleAnim.value < 0.99f) {
                val p = rippleAnim.value
                val color = if (ripple.isSecondary) AmberWait else ElectricAccent
                drawCircle(
                    color = color.copy(alpha = (1f - p) * 0.75f),
                    radius = 12.dp.toPx() + p * 24.dp.toPx(),
                    center = Offset(ripple.viewX, ripple.viewY),
                    style = Stroke(width = 2.2.dp.toPx()),
                )
            }

            val win = state.selectedWindow
            val cursorPt = state.trackpadCursorPt
            if (state.hasLiveVideo && state.inputMode == PointerInputMode.TRACKPAD && win != null && cursorPt != null) {
                val u = (cursorPt.x / win.widthPoints.toFloat()).coerceIn(0f, 1f)
                val v = (cursorPt.y / win.heightPoints.toFloat()).coerceIn(0f, 1f)
                val pos = transform.normalizedToScreen(u, v)
                val s = 1.dp.toPx()
                val arrow = Path().apply {
                    moveTo(pos.x, pos.y)
                    lineTo(pos.x, pos.y + 18f * s)
                    lineTo(pos.x + 4.8f * s, pos.y + 14.2f * s)
                    lineTo(pos.x + 8.2f * s, pos.y + 21.5f * s)
                    lineTo(pos.x + 11.0f * s, pos.y + 20.1f * s)
                    lineTo(pos.x + 7.6f * s, pos.y + 12.8f * s)
                    lineTo(pos.x + 13.5f * s, pos.y + 12.8f * s)
                    close()
                }
                drawPath(arrow, color = Color.Black)
                drawPath(arrow, color = Color.White, style = Stroke(width = 1.5f * s))
            }
        }
    }
}

@Composable
private fun EmptyStageOverlay(
    state: WorkspaceUiState,
    onOpenPairing: () -> Unit,
    onOpenWindows: () -> Unit,
    onReconnect: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        modifier = modifier
            .padding(24.dp)
            .width(380.dp),
        shape = RoundedCornerShape(22.dp),
        color = StudioSurface.copy(alpha = 0.94f),
        border = BorderStroke(1.dp, StudioBorder),
    ) {
        Column(
            modifier = Modifier.padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Icon(
                imageVector = Icons.Default.DesktopMac,
                contentDescription = null,
                tint = ElectricAccent,
                modifier = Modifier.size(40.dp),
            )
            Text(
                text = state.activeHost?.name ?: "KKRemote 原生工作台",
                fontSize = 18.sp,
                fontWeight = FontWeight.SemiBold,
                color = TextPrimary,
            )
            Text(
                text = state.statusText,
                fontSize = 13.sp,
                color = TextSecondary,
            )
            if (state.phase == ConnectionPhase.CONNECTING_COORD ||
                state.phase == ConnectionPhase.HANDSHAKING ||
                state.phase == ConnectionPhase.ICE_CHECKING
            ) {
                CircularProgressIndicator(
                    modifier = Modifier.size(26.dp),
                    strokeWidth = 2.5.dp,
                    color = ElectricAccent,
                )
            }
            state.errorText?.let { err ->
                Text(text = err, fontSize = 12.sp, color = CoralAlert)
            }
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                if (state.dataChannelOpen) {
                    Button(
                        onClick = onOpenWindows,
                        modifier = Modifier.testTag("btnEmptyChooseWindow"),
                    ) {
                        Icon(Icons.Default.Window, contentDescription = null, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(6.dp))
                        Text("选择 Mac 窗口")
                    }
                } else if (state.activeHost != null) {
                    Button(
                        onClick = onReconnect,
                        modifier = Modifier.testTag("btnEmptyReconnect"),
                    ) {
                        Icon(Icons.Default.Refresh, contentDescription = null, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(6.dp))
                        Text("立即重连")
                    }
                }
                OutlinedButton(
                    onClick = onOpenPairing,
                    modifier = Modifier.testTag("btnEmptyPairing"),
                ) {
                    Icon(Icons.Default.AddLink, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(6.dp))
                    Text(if (state.activeHost == null) "配对 Mac 主机" else "切换主机")
                }
            }
        }
    }
}

@Composable
private fun TopStatusOverlay(
    state: WorkspaceUiState,
    isLargeScreen: Boolean,
    onToggleSidebar: () -> Unit,
    onOpenTelemetry: () -> Unit,
    onOpenPairing: () -> Unit,
) {
    val statusBarPad = WindowInsets.statusBars.asPaddingValues()
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = statusBarPad.calculateTopPadding() + 8.dp, start = 12.dp, end = 12.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            if (isLargeScreen) {
                Surface(
                    shape = CircleShape,
                    color = StudioSurface.copy(alpha = 0.88f),
                    border = BorderStroke(1.dp, StudioBorder),
                ) {
                    IconButton(
                        onClick = onToggleSidebar,
                        modifier = Modifier.size(36.dp).testTag("btnToggleSidebar"),
                    ) {
                        Icon(Icons.AutoMirrored.Filled.ViewSidebar, contentDescription = "切换窗口侧栏", tint = TextPrimary, modifier = Modifier.size(18.dp))
                    }
                }
            }

            // Host Pill
            Surface(
                shape = CircleShape,
                color = StudioSurface.copy(alpha = 0.88f),
                border = BorderStroke(1.dp, StudioBorder),
                modifier = Modifier
                    .clip(CircleShape)
                    .clickable(onClick = onOpenPairing)
                    .testTag("pillHostStatus"),
            ) {
                Row(
                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 7.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(7.dp),
                ) {
                    val dotColor = when {
                        state.phase == ConnectionPhase.CONNECTED -> EmeraldLive
                        state.hostOnline -> AmberWait
                        else -> TextSecondary
                    }
                    Box(modifier = Modifier.size(8.dp).clip(CircleShape).background(dotColor))
                    Text(
                        text = state.activeHost?.name ?: "未配对主机",
                        fontSize = 12.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = TextPrimary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }

            // Live Telemetry Pill
            if (state.phase == ConnectionPhase.CONNECTED) {
                Surface(
                    shape = CircleShape,
                    color = StudioSurface.copy(alpha = 0.88f),
                    border = BorderStroke(1.dp, StudioBorder),
                    modifier = Modifier
                        .clip(CircleShape)
                        .clickable(onClick = onOpenTelemetry)
                        .testTag("pillTelemetry"),
                ) {
                    val t = state.telemetry
                    val metricText = if (state.hasLiveVideo) {
                        val rttStr = t.rttMs?.let { "${it.roundToInt()}ms" } ?: "—"
                        "${state.videoWidthPx}×${state.videoHeightPx} · ${t.fps.roundToInt()}fps · $rttStr"
                    } else {
                        "P2P 已连通 · 等待选窗"
                    }
                    Text(
                        text = metricText,
                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 7.dp),
                        style = TextStyle(
                            fontSize = 12.sp,
                            fontFamily = FontFamily.Monospace,
                            color = TextSecondary,
                        ),
                        maxLines = 1,
                    )
                }
            }
        }

        state.bannerWarning?.let { warn ->
            Surface(
                shape = RoundedCornerShape(10.dp),
                color = StudioSurfaceElevated.copy(alpha = 0.92f),
                border = BorderStroke(1.dp, AmberWait.copy(alpha = 0.45f)),
            ) {
                Text(
                    text = warn,
                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
                    fontSize = 12.sp,
                    color = AmberWait,
                )
            }
        }
    }
}

@Composable
private fun FloatingControlDock(
    state: WorkspaceUiState,
    isLargeScreen: Boolean,
    onToggleKeyboard: () -> Unit,
    onOpenWindows: () -> Unit,
    onTogglePointerMode: () -> Unit,
    onSetScaleMode: (CanvasScaleMode) -> Unit,
    onResetViewport: () -> Unit,
    onOpenTelemetry: () -> Unit,
    onOpenPairing: () -> Unit,
    onDisconnect: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val navPad = WindowInsets.navigationBars.asPaddingValues()
    var offsetX by remember { mutableFloatStateOf(0f) }
    var offsetY by remember { mutableFloatStateOf(0f) }
    var showOverflow by remember { mutableStateOf(false) }

    Box(
        modifier = modifier
            .padding(end = 14.dp, bottom = navPad.calculateBottomPadding() + 14.dp)
            .offset { IntOffset(offsetX.roundToInt(), offsetY.roundToInt()) }
            .pointerInput(Unit) {
                detectDragGestures { change, dragAmount ->
                    change.consume()
                    offsetX = (offsetX + dragAmount.x).coerceIn(-900f, 60f)
                    offsetY = (offsetY + dragAmount.y).coerceIn(-1200f, 60f)
                }
            }
    ) {
        Surface(
            shape = CircleShape,
            color = StudioSurface.copy(alpha = 0.92f),
            border = BorderStroke(1.dp, StudioBorder),
            shadowElevation = 10.dp,
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                IconButton(
                    onClick = onToggleKeyboard,
                    enabled = state.hasLiveVideo,
                    modifier = Modifier.size(48.dp).testTag("dockBtnKeyboard"),
                ) {
                    Icon(
                        imageVector = if (state.showKeyboardBar) Icons.Default.KeyboardHide else Icons.Default.Keyboard,
                        contentDescription = if (state.showKeyboardBar) "隐藏键盘栏" else "打开键盘栏",
                        tint = if (state.showKeyboardBar) ElectricAccent else TextPrimary,
                    )
                }
                VerticalDivider(modifier = Modifier.height(22.dp), color = StudioBorder)

                if (!isLargeScreen || !state.sidebarExpandedOnLargeScreen) {
                    IconButton(
                        onClick = onOpenWindows,
                        enabled = state.dataChannelOpen,
                        modifier = Modifier.size(48.dp).testTag("dockBtnWindows"),
                    ) {
                        Icon(
                            imageVector = Icons.Default.Window,
                            contentDescription = "选择远端窗口",
                            tint = if (state.dataChannelOpen) TextPrimary else TextSecondary.copy(alpha = 0.4f),
                        )
                    }
                    VerticalDivider(modifier = Modifier.height(22.dp), color = StudioBorder)
                }

                IconButton(
                    onClick = onTogglePointerMode,
                    enabled = state.hasLiveVideo,
                    modifier = Modifier.size(48.dp).testTag("dockBtnPointerMode"),
                ) {
                    Icon(
                        imageVector = if (state.inputMode == PointerInputMode.TRACKPAD) Icons.Default.Mouse else Icons.Default.TouchApp,
                        contentDescription = "切换直点与触控板模式",
                        tint = if (state.inputMode == PointerInputMode.TRACKPAD) ElectricAccent else TextPrimary,
                    )
                }
                VerticalDivider(modifier = Modifier.height(22.dp), color = StudioBorder)

                Box {
                    IconButton(
                        onClick = { showOverflow = true },
                        modifier = Modifier.size(48.dp).testTag("dockBtnMore"),
                    ) {
                        Icon(Icons.Default.MoreHoriz, contentDescription = "更多操作", tint = TextPrimary)
                    }

                    DropdownMenu(
                        expanded = showOverflow,
                        onDismissRequest = { showOverflow = false },
                        containerColor = StudioSurfaceElevated,
                    ) {
                        CanvasScaleMode.entries.forEach { mode ->
                            DropdownMenuItem(
                                text = { Text("画面：${mode.label} ${if (state.scaleMode == mode) "✓" else ""}") },
                                leadingIcon = { Icon(Icons.Default.AspectRatio, contentDescription = null) },
                                onClick = {
                                    onSetScaleMode(mode)
                                    showOverflow = false
                                },
                            )
                        }
                        if (state.zoom > 1.01f) {
                            DropdownMenuItem(
                                text = { Text("重置缩放 (${String.format("%.1f×", state.zoom)})") },
                                onClick = {
                                    onResetViewport()
                                    showOverflow = false
                                },
                            )
                        }
                        HorizontalDivider(color = StudioBorder)
                        DropdownMenuItem(
                            text = { Text("传输与解码诊断") },
                            leadingIcon = { Icon(Icons.Default.Analytics, contentDescription = null) },
                            onClick = {
                                showOverflow = false
                                onOpenTelemetry()
                            },
                        )
                        DropdownMenuItem(
                            text = { Text("配对与主机列表") },
                            leadingIcon = { Icon(Icons.Default.AddLink, contentDescription = null) },
                            onClick = {
                                showOverflow = false
                                onOpenPairing()
                            },
                        )
                        if (state.phase != ConnectionPhase.IDLE) {
                            DropdownMenuItem(
                                text = { Text("断开当前连接", color = CoralAlert) },
                                leadingIcon = { Icon(Icons.Default.LinkOff, contentDescription = null, tint = CoralAlert) },
                                onClick = {
                                    showOverflow = false
                                    onDisconnect()
                                },
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun FoldableWindowSidebar(
    state: WorkspaceUiState,
    onSelectWindow: (RemoteWindow) -> Unit,
    onRefreshWindows: () -> Unit,
    onOpenPairing: () -> Unit,
    onOpenTelemetry: () -> Unit,
) {
    val statusBarPad = WindowInsets.statusBars.asPaddingValues()
    val navPad = WindowInsets.navigationBars.asPaddingValues()
    Column(
        modifier = Modifier
            .width(256.dp)
            .fillMaxHeight()
            .background(StudioSurface)
            .padding(
                top = statusBarPad.calculateTopPadding() + 10.dp,
                bottom = navPad.calculateBottomPadding() + 10.dp,
                start = 12.dp,
                end = 12.dp,
            )
            .testTag("foldableWindowSidebar"),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Text("Mac 窗口工作区", fontSize = 15.sp, fontWeight = FontWeight.Bold, color = TextPrimary)
            IconButton(
                onClick = onRefreshWindows,
                enabled = state.dataChannelOpen,
                modifier = Modifier.size(32.dp).testTag("btnSidebarRefresh"),
            ) {
                Icon(Icons.Default.Refresh, contentDescription = "刷新窗口列表", tint = TextSecondary, modifier = Modifier.size(18.dp))
            }
        }
        Spacer(Modifier.height(8.dp))

        if (!state.dataChannelOpen) {
            Text(
                text = if (state.activeHost == null) "请先导入配对链接" else state.statusText,
                fontSize = 12.sp,
                color = TextSecondary,
                modifier = Modifier.padding(vertical = 8.dp),
            )
        } else if (state.windows.isEmpty()) {
            Text(
                text = if (state.catalogLoading) "正在读取 Mac 桌面窗口…" else "暂无可捕获窗口",
                fontSize = 12.sp,
                color = TextSecondary,
                modifier = Modifier.padding(vertical = 8.dp),
            )
        } else {
            LazyColumn(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                items(state.windows, key = { it.id }) { win ->
                    val active = state.selectedWindow?.id == win.id
                    Surface(
                        shape = RoundedCornerShape(12.dp),
                        color = if (active) ElectricAccent.copy(alpha = 0.16f) else StudioSurfaceElevated,
                        border = BorderStroke(1.dp, if (active) ElectricAccent else StudioBorder),
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(12.dp))
                            .clickable { onSelectWindow(win) }
                            .semantics { contentDescription = "窗口 ${win.displayLabel}" },
                    ) {
                        Column(modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp)) {
                            Text(
                                text = win.application,
                                fontSize = 13.sp,
                                fontWeight = FontWeight.SemiBold,
                                color = if (active) ElectricAccent else TextPrimary,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                            if (win.title.isNotBlank()) {
                                Text(
                                    text = win.title,
                                    fontSize = 12.sp,
                                    color = TextSecondary,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }
                            Text(
                                text = "${win.widthPoints.roundToInt()}×${win.heightPoints.roundToInt()} pt",
                                fontSize = 11.sp,
                                fontFamily = FontFamily.Monospace,
                                color = TextSecondary.copy(alpha = 0.75f),
                            )
                        }
                    }
                }
            }
        }

        if (!state.dataChannelOpen || state.windows.isEmpty()) {
            Spacer(Modifier.weight(1f))
        }

        HorizontalDivider(color = StudioBorder, modifier = Modifier.padding(vertical = 8.dp))
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            TextButton(onClick = onOpenPairing) { Text("主机管理", fontSize = 12.sp) }
            TextButton(onClick = onOpenTelemetry) { Text("传输诊断", fontSize = 12.sp) }
        }
    }
}

@Composable
private fun MacKeyboardComposerBar(
    canControl: Boolean,
    onSendText: (String) -> Unit,
    onSendKey: (String) -> Unit,
    onClose: () -> Unit,
) {
    val navPad = WindowInsets.navigationBars.asPaddingValues()
    var draft by remember { mutableStateOf("") }

    Surface(
        color = StudioSurface,
        border = BorderStroke(1.dp, StudioBorder),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(
            modifier = Modifier
                .padding(
                    start = 12.dp,
                    end = 12.dp,
                    top = 8.dp,
                    bottom = maxOf(8.dp, navPad.calculateBottomPadding()),
                ),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            // macOS Special Keys Row
            val keys = listOf(
                "Esc" to "escape",
                "Tab" to "tab",
                "退格" to "backspace",
                "回车" to "return",
                "←" to "left",
                "↑" to "up",
                "↓" to "down",
                "→" to "right",
                "Home" to "home",
                "End" to "end",
            )
            Row(
                modifier = Modifier.horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                for ((label, code) in keys) {
                    OutlinedButton(
                        onClick = { onSendKey(code) },
                        enabled = canControl,
                        contentPadding = PaddingValues(horizontal = 12.dp, vertical = 4.dp),
                        modifier = Modifier.height(34.dp).testTag("keyBtn_$code"),
                    ) {
                        Text(label, fontSize = 12.sp)
                    }
                }
            }

            // CJK / English Text Composer
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                OutlinedTextField(
                    value = draft,
                    onValueChange = { draft = it },
                    enabled = canControl,
                    placeholder = {
                        Text(
                            if (canControl) "输入中英文后发送至 Mac 焦点窗口…" else "当前为只读观看（需在 Mac 开启辅助功能权限）",
                            fontSize = 13.sp,
                        )
                    },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
                    keyboardActions = KeyboardActions(
                        onSend = {
                            if (draft.isNotEmpty()) {
                                onSendText(draft)
                                draft = ""
                            }
                        }
                    ),
                    modifier = Modifier.weight(1f).testTag("inputRemoteText"),
                )
                Button(
                    onClick = {
                        if (draft.isNotEmpty()) {
                            onSendText(draft)
                            draft = ""
                        }
                    },
                    enabled = canControl && draft.isNotEmpty(),
                    modifier = Modifier.testTag("btnCommitText"),
                ) {
                    Text("发送")
                }
                IconButton(onClick = onClose) {
                    Icon(Icons.Default.KeyboardHide, contentDescription = "收起键盘栏", tint = TextSecondary)
                }
            }
        }
    }
}

@Composable
private fun PairingAndHostsSheet(
    state: WorkspaceUiState,
    onImportLink: (String, String) -> Boolean,
    onConnectSaved: (TrustedHostProfile) -> Unit,
    onRemoveSaved: (TrustedHostProfile) -> Unit,
    onClose: () -> Unit,
) {
    val context = LocalContext.current
    var rawLink by remember { mutableStateOf("") }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 20.dp, vertical = 8.dp)
            .padding(bottom = 24.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column {
                Text("Mac 主机连接与配对", fontSize = 18.sp, fontWeight = FontWeight.Bold)
                Text("本机加密身份 ID：${state.clientIdShort}…（零知识 P-256）", fontSize = 12.sp, color = TextSecondary)
            }
            TextButton(onClick = onClose) { Text("关闭") }
        }

        if (state.savedHosts.isNotEmpty()) {
            Text("已信任的 Mac 主机", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = TextSecondary)
            state.savedHosts.forEach { host ->
                val isCurrent = state.activeHost?.key == host.key
                Surface(
                    shape = RoundedCornerShape(14.dp),
                    color = if (isCurrent) ElectricAccent.copy(alpha = 0.14f) else StudioSurfaceElevated,
                    border = BorderStroke(1.dp, if (isCurrent) ElectricAccent else StudioBorder),
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(14.dp))
                        .clickable { onConnectSaved(host) }
                        .testTag("savedHost_${host.hostId.take(6)}"),
                ) {
                    Row(
                        modifier = Modifier.padding(14.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween,
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text(host.name, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                            Text(
                                text = "${host.coordUrl} · ${if (host.accessGrant != null) "已获长期授权" else "待首次认证"}",
                                fontSize = 12.sp,
                                color = TextSecondary,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                        IconButton(onClick = { onRemoveSaved(host) }) {
                            Icon(Icons.Default.DeleteOutline, contentDescription = "移除主机", tint = TextSecondary)
                        }
                    }
                }
            }
        }

        HorizontalDivider(color = StudioBorder)
        Text("导入新配对链接", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = TextSecondary)

        OutlinedTextField(
            value = rawLink,
            onValueChange = { rawLink = it },
            placeholder = { Text("粘贴 https://.../#host=... 配对链接", fontSize = 13.sp) },
            singleLine = true,
            modifier = Modifier.fillMaxWidth().testTag("inputPairingUrl"),
        )

        state.errorText?.let { err ->
            Text(err, fontSize = 12.sp, color = CoralAlert)
        }

        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            OutlinedButton(
                onClick = {
                    val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
                    val clip = cm?.primaryClip?.getItemAt(0)?.coerceToText(context)?.toString().orEmpty()
                    if (clip.isNotBlank()) {
                        rawLink = clip
                        onImportLink(clip, "")
                    }
                },
                modifier = Modifier.weight(1f).testTag("btnPasteAndConnect"),
            ) {
                Icon(Icons.Default.ContentPaste, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(6.dp))
                Text("从剪贴板一键连接")
            }

            Button(
                onClick = { onImportLink(rawLink, "") },
                enabled = rawLink.isNotBlank(),
                colors = ButtonDefaults.buttonColors(containerColor = ElectricAccent),
                modifier = Modifier.weight(1f).testTag("btnConnectLink"),
            ) {
                Text("配对并直连")
            }
        }
    }
}

@Composable
private fun WindowCatalogSheet(
    state: WorkspaceUiState,
    onRefresh: () -> Unit,
    onSelect: (RemoteWindow) -> Unit,
) {
    var filter by remember { mutableStateOf("") }
    val filtered = remember(state.windows, filter) {
        if (filter.isBlank()) state.windows
        else state.windows.filter { it.displayLabel.contains(filter, ignoreCase = true) }
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 20.dp)
            .padding(bottom = 24.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column {
                Text("选择要串流的 Mac 窗口", fontSize = 18.sp, fontWeight = FontWeight.Bold)
                Text("带内热切换 · 不改变 Mac 源窗口位置与尺寸", fontSize = 12.sp, color = TextSecondary)
            }
            IconButton(onClick = onRefresh, modifier = Modifier.testTag("btnSheetRefreshWindows")) {
                Icon(Icons.Default.Refresh, contentDescription = "刷新窗口目录")
            }
        }

        OutlinedTextField(
            value = filter,
            onValueChange = { filter = it },
            placeholder = { Text("搜索应用或窗口标题…", fontSize = 13.sp) },
            singleLine = true,
            modifier = Modifier.fillMaxWidth().testTag("inputWindowFilter"),
        )

        LazyColumn(
            modifier = Modifier.height(360.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            items(filtered, key = { it.id }) { win ->
                val isSelected = state.selectedWindow?.id == win.id
                Surface(
                    shape = RoundedCornerShape(14.dp),
                    color = if (isSelected) ElectricAccent.copy(alpha = 0.16f) else StudioSurfaceElevated,
                    border = BorderStroke(1.dp, if (isSelected) ElectricAccent else StudioBorder),
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(14.dp))
                        .clickable { onSelect(win) }
                        .semantics { contentDescription = "选择窗口 ${win.displayLabel}" },
                ) {
                    Row(
                        modifier = Modifier.padding(14.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween,
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text(win.displayLabel, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Text(
                                text = "${win.widthPoints.roundToInt()}×${win.heightPoints.roundToInt()} pt · #${win.number}",
                                fontSize = 12.sp,
                                fontFamily = FontFamily.Monospace,
                                color = TextSecondary,
                            )
                        }
                        Text(
                            text = if (isSelected) "当前投流" else "投流",
                            fontSize = 13.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = ElectricAccent,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun TelemetryDiagnosticsSheet(
    state: WorkspaceUiState,
    onSetScaleMode: (CanvasScaleMode) -> Unit,
    onTogglePreferHdr: () -> Unit,
    onReconnect: () -> Unit,
) {
    val t = state.telemetry
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 20.dp)
            .padding(bottom = 28.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("原生 WebRTC 实时遥测", fontSize = 18.sp, fontWeight = FontWeight.Bold)
            OutlinedButton(onClick = onReconnect) { Text("重协商会话", fontSize = 12.sp) }
        }

        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            CanvasScaleMode.entries.forEach { mode ->
                FilterChip(
                    selected = state.scaleMode == mode,
                    onClick = { onSetScaleMode(mode) },
                    label = { Text(mode.label, fontSize = 12.sp) },
                )
            }
            FilterChip(
                selected = state.preferHdr,
                onClick = onTogglePreferHdr,
                label = { Text(if (state.preferHdr) "HDR 优先" else "SDR 桌面", fontSize = 12.sp) },
            )
        }

        HorizontalDivider(color = StudioBorder)

        TelemetryRow("ICE 候选对", t.candidatePair)
        TelemetryRow("网络往返 RTT", t.rttMs?.let { String.format("%.1f ms", it) } ?: "—")
        TelemetryRow("协商编码器", t.codec)
        TelemetryRow("Android 硬件解码器", t.decoderName)
        TelemetryRow("解码分辨率 / 帧率", "${state.videoWidthPx}×${state.videoHeightPx} @ ${t.fps.roundToInt()} fps")
        TelemetryRow("视频有效码率", String.format("%.2f Mbps", t.videoMbps))
        TelemetryRow("单帧硬解 / 抖动缓冲", "${t.decodeMs?.let { String.format("%.2f ms", it) } ?: "—"} / ${t.jitterMs?.let { String.format("%.2f ms", it) } ?: "—"}")
        TelemetryRow("累计解码帧 / 关键帧", "${t.framesDecoded} / ${t.keyFramesDecoded}")
        TelemetryRow("丢包 / NACK / PLI", "${t.packetsLost} / ${t.nackCount} / ${t.pliCount}")
    }
}

@Composable
private fun TelemetryRow(label: String, value: String) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(label, fontSize = 13.sp, color = TextSecondary)
        Text(
            text = value,
            fontSize = 13.sp,
            fontFamily = FontFamily.Monospace,
            color = TextPrimary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}
