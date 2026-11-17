package com.kkremote.android.ui

import android.app.Activity
import android.content.ClipboardManager
import android.content.Context
import android.graphics.BitmapFactory
import android.graphics.Rect as AndroidRect
import android.util.Base64
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Backspace
import androidx.compose.material.icons.automirrored.filled.KeyboardReturn
import androidx.compose.material.icons.filled.AddLink
import androidx.compose.material.icons.filled.Analytics
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ContentPaste
import androidx.compose.material.icons.filled.DeleteOutline
import androidx.compose.material.icons.filled.DesktopWindows
import androidx.compose.material.icons.filled.FitScreen
import androidx.compose.material.icons.filled.Fullscreen
import androidx.compose.material.icons.filled.Keyboard
import androidx.compose.material.icons.filled.KeyboardHide
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.Mouse
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.StopCircle
import androidx.compose.material.icons.filled.TouchApp
import androidx.compose.material.icons.filled.Window
import androidx.compose.material.icons.filled.ZoomIn
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import com.kkremote.android.gesture.GestureAction
import com.kkremote.android.gesture.InteractionGestureMachine
import com.kkremote.android.gesture.TouchContact
import com.kkremote.android.gesture.TouchPoint
import com.kkremote.android.protocol.RemoteWindow
import com.kkremote.android.protocol.TrustedHostProfile
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

@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun KKRemoteScreen(viewModel: WorkspaceViewModel) {
    val state by viewModel.uiState.collectAsState()
    val videoTrack by viewModel.videoTrack.collectAsState()

    val isDarkMaterial = state.edgeColor.prefersLightContent
    val palette = remember(isDarkMaterial) { GlassPalette.forDarkMode(isDarkMaterial) }
    val ambientBg by animateColorAsState(
        targetValue = state.edgeColor.composeColor,
        animationSpec = tween(durationMillis = 380),
        label = "ambientEdgeColor",
    )

    // Synchronize system status-bar & navigation-bar icon appearance + Omni-Desktop immersive mode
    val view = LocalView.current
    if (!view.isInEditMode) {
        SideEffect {
            val window = (view.context as? Activity)?.window ?: return@SideEffect
            val insetsController = WindowCompat.getInsetsController(window, view)
            insetsController.isAppearanceLightStatusBars = !isDarkMaterial
            insetsController.isAppearanceLightNavigationBars = !isDarkMaterial
            if (state.omniDesktopMode) {
                insetsController.systemBarsBehavior =
                    WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                insetsController.hide(WindowInsetsCompat.Type.systemBars())
            } else {
                insetsController.show(WindowInsetsCompat.Type.systemBars())
            }
        }
    }

    // Report exact full-screen physical window viewport (outside .imePadding() so soft keyboard never triggers Mac resize)
    val configuration = LocalConfiguration.current
    val density = LocalDensity.current
    var fullWindowSizePx by remember { mutableStateOf(IntSize.Zero) }
    val viewportWidthDp = if (fullWindowSizePx.width > 0) {
        fullWindowSizePx.width.toDouble() / density.density.toDouble()
    } else {
        configuration.screenWidthDp.toDouble()
    }
    val viewportHeightDp = if (fullWindowSizePx.height > 0) {
        fullWindowSizePx.height.toDouble() / density.density.toDouble()
    } else {
        configuration.screenHeightDp.toDouble()
    }
    LaunchedEffect(viewportWidthDp, viewportHeightDp, density.density) {
        viewModel.onClientViewportChanged(
            widthDp = viewportWidthDp,
            heightDp = viewportHeightDp,
            displayScale = density.density.toDouble(),
        )
    }

    var liveVideoBitmap by remember { mutableStateOf<ImageBitmap?>(null) }
    var liveVideoRectInRoot by remember { mutableStateOf(Rect.Zero) }
    var liveGeneration by remember { mutableLongStateOf(0L) }
    var showOverflowMenu by remember { mutableStateOf(false) }

    LaunchedEffect(state.hasLiveVideo) {
        if (!state.hasLiveVideo) {
            liveVideoBitmap = null
            liveVideoRectInRoot = Rect.Zero
            liveGeneration += 1L
        }
    }

    val backdrop = LiveVideoBackdrop(
        videoBitmap = if (state.hasLiveVideo) liveVideoBitmap else null,
        videoRectInRoot = liveVideoRectInRoot,
        ambientColor = ambientBg,
        generation = liveGeneration,
    )

    // Full-screen workspace in both folded and unfolded states — no sidebar!
    Box(
        modifier = Modifier
            .fillMaxSize()
            .onSizeChanged { fullWindowSizePx = it }
    ) {
        if (state.omniDesktopMode) {
            OmniDesktopWorkspace(
                state = state,
                palette = palette,
                backdrop = backdrop,
                videoTrack = videoTrack,
                onVideoSizeChanged = viewModel::onVideoSizeChanged,
                onBackdropSampled = { bmp, edge, gen ->
                    liveVideoBitmap = bmp
                    liveGeneration = gen
                    viewModel.onEdgeColorSampled(edge)
                },
                onVideoRectChanged = { rect -> liveVideoRectInRoot = rect },
                onZoomAndPan = viewModel::updateZoomAndPan,
                onResetViewport = viewModel::resetViewport,
                onRemoteClick = viewModel::sendRemoteClick,
                onRemoteScroll = viewModel::queueRemoteScroll,
                onTrackpadDelta = viewModel::moveOmniTrackpadCursor,
                onTrackpadClick = viewModel::clickAtTrackpadCursor,
                onTrackpadScroll = viewModel::scrollAtTrackpadCursor,
                onSendRawKey = viewModel::sendRawMacKey,
                onToggleInputSource = viewModel::sendToggleMacInputSource,
                onActivateOmniApp = viewModel::activateOmniApp,
                onRefreshWindows = viewModel::refreshWindows,
                onCycleKeyboardStyle = viewModel::cycleOmniKeyboardStyle,
                onExitOmniMode = { viewModel.setOmniDesktopMode(false) },
                onConnectOrOpenSettings = {
                    if (state.activeHost != null) viewModel.reconnectActiveHost()
                    else viewModel.setShowPairingSheet(true)
                },
                onOpenSettings = { viewModel.setShowPairingSheet(true) },
                onOpenDiagnostics = { viewModel.setShowTelemetrySheet(true) },
            )
        } else {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .background(ambientBg)
                    .semantics { testTagsAsResourceId = true }
                    .imePadding()
            ) {
                Box(modifier = Modifier.weight(1f).fillMaxWidth()) {
                    RemoteWindowStage(
                        state = state,
                        palette = palette,
                        backdrop = backdrop,
                        videoTrack = videoTrack,
                        onVideoSizeChanged = viewModel::onVideoSizeChanged,
                        onBackdropSampled = { bmp, edge, gen ->
                            liveVideoBitmap = bmp
                            liveGeneration = gen
                            viewModel.onEdgeColorSampled(edge)
                        },
                        onVideoRectChanged = { rect -> liveVideoRectInRoot = rect },
                        onZoomAndPan = viewModel::updateZoomAndPan,
                        onResetViewport = viewModel::resetViewport,
                        onMoveTrackpadCursor = viewModel::moveTrackpadCursor,
                        onRemoteClick = viewModel::sendRemoteClick,
                        onRemoteScroll = viewModel::queueRemoteScroll,
                        onConnectOrOpenSettings = {
                            if (state.activeHost != null) viewModel.reconnectActiveHost()
                            else viewModel.setShowPairingSheet(true)
                        },
                        onOpenSettings = { viewModel.setShowPairingSheet(true) },
                        onOpenWindows = { viewModel.setShowWindowSheet(true) },
                        onEnterOmniDesktop = { viewModel.setOmniDesktopMode(true) },
                    )

                    // Subtle auto-dismissing top frosted notice (matches IOSLabView controlError banner)
                    val statusBarPad = WindowInsets.statusBars.asPaddingValues()
                    androidx.compose.animation.AnimatedVisibility(
                        visible = !state.bannerWarning.isNullOrBlank(),
                        enter = fadeIn(tween(180)),
                        exit = fadeOut(tween(220)),
                        modifier = Modifier
                            .align(Alignment.TopCenter)
                            .padding(top = statusBarPad.calculateTopPadding() + 10.dp, start = 16.dp, end = 16.dp),
                    ) {
                        FrostedGlassBox(
                            palette = palette,
                            backdrop = backdrop,
                            shape = CircleShape,
                            blurRadius = 22.dp,
                            shadowElevation = 8.dp,
                        ) {
                            Text(
                                text = state.bannerWarning.orEmpty(),
                                modifier = Modifier.padding(horizontal = 14.dp, vertical = 8.dp),
                                fontSize = 12.sp,
                                color = palette.primaryText,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                    }

                    // Transparent outside-tap dismiss scrim when iOS popover menu OR horizontal macOS Dock is open
                    if (showOverflowMenu || state.showWindowSheet) {
                        Box(
                            modifier = Modifier
                                .fillMaxSize()
                                .clickable(
                                    interactionSource = remember { MutableInteractionSource() },
                                    indication = null,
                                    onClick = {
                                        showOverflowMenu = false
                                        if (state.showWindowSheet) viewModel.setShowWindowSheet(false)
                                    },
                                )
                        )
                    }

                    // Horizontal macOS Dock Window Switcher (replaces modal window!)
                    androidx.compose.animation.AnimatedVisibility(
                        visible = state.showWindowSheet && state.dataChannelOpen,
                        enter = slideInVertically(
                            initialOffsetY = { it + 64 },
                            animationSpec = spring(dampingRatio = 0.78f, stiffness = Spring.StiffnessMediumLow),
                        ) + fadeIn(tween(160)),
                        exit = slideOutVertically(
                            targetOffsetY = { it + 64 },
                            animationSpec = tween(180),
                        ) + fadeOut(tween(150)),
                        modifier = Modifier.align(Alignment.BottomCenter),
                    ) {
                        MacHorizontalWindowDock(
                            state = state,
                            palette = palette,
                            backdrop = backdrop,
                            onSelect = viewModel::selectWindow,
                            onRefresh = viewModel::refreshWindows,
                            onCollapse = { viewModel.setShowWindowSheet(false) },
                        )
                    }

                    // Bottom-Right Draggable Frosted Glass Capsule Dock + iOS Popover Menu (hidden while horizontal macOS Dock is expanded)
                    androidx.compose.animation.AnimatedVisibility(
                        visible = !(state.showWindowSheet && state.dataChannelOpen),
                        enter = fadeIn(tween(160)),
                        exit = fadeOut(tween(120)),
                        modifier = Modifier.align(Alignment.BottomEnd),
                    ) {
                        FloatingIosCapsuleDock(
                            state = state,
                            palette = palette,
                            backdrop = backdrop,
                            showMenu = showOverflowMenu,
                            onToggleMenu = { showOverflowMenu = !showOverflowMenu },
                            onDismissMenu = { showOverflowMenu = false },
                            onToggleKeyboard = {
                                showOverflowMenu = false
                                viewModel.setShowKeyboardBar(!state.showKeyboardBar)
                            },
                            onOpenWindows = {
                                showOverflowMenu = false
                                viewModel.setShowWindowSheet(true)
                            },
                            onToggleOmniDesktop = {
                                showOverflowMenu = false
                                viewModel.toggleOmniDesktopMode()
                            },
                            onTogglePointerMode = {
                                showOverflowMenu = false
                                viewModel.togglePointerMode()
                            },
                            onSetScaleMode = { mode ->
                                showOverflowMenu = false
                                viewModel.setScaleMode(mode)
                            },
                            onZoomIn = {
                                showOverflowMenu = false
                                viewModel.zoomInStep()
                            },
                            onToggleHdr = {
                                showOverflowMenu = false
                                viewModel.togglePreferHdr()
                            },
                            onToggleLinkQualityBar = {
                                viewModel.toggleLinkQualityBar()
                            },
                            onSendQuickKey = { key ->
                                showOverflowMenu = false
                                viewModel.sendRemoteKey(key)
                            },
                            onOpenSettings = {
                                showOverflowMenu = false
                                viewModel.setShowPairingSheet(true)
                            },
                            onOpenDiagnostics = {
                                showOverflowMenu = false
                                viewModel.setShowTelemetrySheet(true)
                            },
                            onStopViewingKeepConn = {
                                showOverflowMenu = false
                                viewModel.stopViewingKeepConnection()
                            },
                            onDisconnect = {
                                showOverflowMenu = false
                                viewModel.disconnect()
                            },
                        )
                    }
                }

                // Frosted Glass Bottom Keyboard & IME Composer (matches iOS MobileTextComposer)
                AnimatedVisibility(visible = state.showKeyboardBar) {
                    FrostedKeyboardComposerBar(
                        palette = palette,
                        backdrop = backdrop,
                        canControl = state.canControl,
                        onSendText = viewModel::sendRemoteText,
                        onSendKey = viewModel::sendRemoteKey,
                        onClose = { viewModel.setShowKeyboardBar(false) },
                    )
                }
            }
        }
    }

    // Remaining Frosted Glass Modal Sheets (Settings & Diagnostics only)
    if (state.showPairingSheet) {
        FrostedModalSheet(
            palette = palette,
            backdrop = backdrop,
            onDismiss = { viewModel.setShowPairingSheet(false) },
        ) {
            FrostedSettingsAndHostsSheet(
                state = state,
                palette = palette,
                onToggleLinkQualityBar = viewModel::setShowLinkQualityBar,
                onToggleOmniDesktopMode = viewModel::setOmniDesktopMode,
                onSelectOmniKeyboardStyle = viewModel::setOmniKeyboardStyle,
                onImportLink = { link, coord -> viewModel.importPairingLink(link, coord) },
                onConnectSaved = viewModel::connectToHost,
                onRemoveSaved = viewModel::removeHost,
                onDismiss = { viewModel.setShowPairingSheet(false) },
            )
        }
    }

    if (state.showTelemetrySheet) {
        FrostedModalSheet(
            palette = palette,
            backdrop = backdrop,
            onDismiss = { viewModel.setShowTelemetrySheet(false) },
        ) {
            FrostedDiagnosticsSheet(
                state = state,
                palette = palette,
                onSetScaleMode = viewModel::setScaleMode,
                onTogglePreferHdr = viewModel::togglePreferHdr,
                onReconnect = viewModel::reconnectActiveHost,
                onDismiss = { viewModel.setShowTelemetrySheet(false) },
            )
        }
    }
}

@Composable
private fun RemoteWindowStage(
    state: WorkspaceUiState,
    palette: GlassPalette,
    backdrop: LiveVideoBackdrop,
    videoTrack: VideoTrack?,
    onVideoSizeChanged: (Int, Int) -> Unit,
    onBackdropSampled: (ImageBitmap, WindowEdgeColor?, Long) -> Unit,
    onVideoRectChanged: (Rect) -> Unit,
    onZoomAndPan: (Float, Float, Float) -> Unit,
    onResetViewport: () -> Unit,
    onMoveTrackpadCursor: (Float, Float) -> Unit,
    onRemoteClick: (Double, Double, Boolean, Float, Float) -> Unit,
    onRemoteScroll: (Double, Double, Double, Double) -> Unit,
    onConnectOrOpenSettings: () -> Unit,
    onOpenSettings: () -> Unit,
    onOpenWindows: () -> Unit,
    onEnterOmniDesktop: () -> Unit,
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

    val statusBarTopPx = with(LocalDensity.current) {
        WindowInsets.statusBars.asPaddingValues().calculateTopPadding().toPx()
    }
    val navBarBottomPx = with(LocalDensity.current) {
        WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding().toPx()
    }

    val vidW = max(1, state.videoWidthPx)
    val vidH = max(1, state.videoHeightPx)
    val stW = stageSize.width.toFloat()
    val stH = stageSize.height.toFloat()
    val stageAspect = if (stH > 1f) stW / stH else 1f
    val videoAspect = vidW.toFloat() / vidH.toFloat()
    val aspectRelDiff = kotlin.math.abs(videoAspect - stageAspect) / max(0.1f, stageAspect)
    val isAspectMatchedFullScreen = state.hasLiveVideo && aspectRelDiff <= 0.08f
    val useEdgeToEdgeFullScreen = state.scaleMode == CanvasScaleMode.FILL ||
        (state.scaleMode == CanvasScaleMode.FIT && isAspectMatchedFullScreen)
    val safeTop = if (state.scaleMode == CanvasScaleMode.FIT && !isAspectMatchedFullScreen) statusBarTopPx + 8f else 0f
    val safeBottom = if (state.scaleMode == CanvasScaleMode.FIT && !isAspectMatchedFullScreen) navBarBottomPx * 0.6f + 8f else 0f
    val availH = max(1f, stH - safeTop - safeBottom)

    val (drawW, drawH) = remember(stW, stH, availH, vidW, vidH, state.scaleMode, isAspectMatchedFullScreen, aspectRelDiff) {
        if (stW <= 1f || availH <= 1f) {
            0f to 0f
        } else {
            when (state.scaleMode) {
                CanvasScaleMode.FIT -> {
                    if (isAspectMatchedFullScreen && aspectRelDiff <= 0.03f) {
                        val s = max(stW / vidW, stH / vidH)
                        (vidW * s) to (vidH * s)
                    } else {
                        val s = min(stW / vidW, availH / vidH)
                        (vidW * s) to (vidH * s)
                    }
                }
                CanvasScaleMode.FILL -> {
                    val s = max(stW / vidW, stH / vidH)
                    (vidW * s) to (vidH * s)
                }
                CanvasScaleMode.PIXEL_1X -> vidW.toFloat() to vidH.toFloat()
            }
        }
    }

    val verticalBiasPx = (safeTop - safeBottom) * 0.5f

    val transform = StageTransform(
        left0 = (stW - drawW) * 0.5f,
        top0 = (stH - drawH) * 0.5f + verticalBiasPx,
        drawW = drawW,
        drawH = drawH,
        centerX = stW * 0.5f,
        centerY = stH * 0.5f + verticalBiasPx,
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
            val cornerRadius = if (useEdgeToEdgeFullScreen || state.scaleMode != CanvasScaleMode.FIT) 0.dp else 12.dp
            AndroidView(
                factory = { ctx ->
                    WebRtcTextureView(ctx).also { v ->
                        v.setHdrPqMode(state.negotiatedHdrPq)
                        v.onVideoDimensionsChanged = onVideoSizeChanged
                        v.onBackdropSampled = onBackdropSampled
                        v.bindTrack(videoTrack)
                    }
                },
                update = { view ->
                    view.setHdrPqMode(state.negotiatedHdrPq)
                    view.onVideoDimensionsChanged = onVideoSizeChanged
                    view.onBackdropSampled = onBackdropSampled
                    view.bindTrack(videoTrack)
                },
                modifier = Modifier
                    .align(Alignment.Center)
                    .offset { IntOffset(0, verticalBiasPx.roundToInt()) }
                    .size(drawWDp, drawHDp)
                    .graphicsLayer {
                        scaleX = state.zoom
                        scaleY = state.zoom
                        translationX = state.panX
                        translationY = state.panY
                        alpha = if (state.hasLiveVideo) 1f else 0f
                    }
                    .onGloballyPositioned { coords ->
                        onVideoRectChanged(coords.boundsInRoot())
                    }
                    .shadow(
                        elevation = if (state.hasLiveVideo && !useEdgeToEdgeFullScreen && state.scaleMode == CanvasScaleMode.FIT) 18.dp else 0.dp,
                        shape = RoundedCornerShape(cornerRadius),
                        ambientColor = Color.Black.copy(alpha = 0.22f),
                        spotColor = Color.Black.copy(alpha = 0.24f),
                    )
                    .clip(RoundedCornerShape(cornerRadius)),
            )
        }

        // Idle / Connecting / Choose-Window Presentation (matches iOS IOSLabView)
        if (!state.hasLiveVideo) {
            IosStyleIdleWorkspace(
                state = state,
                palette = palette,
                backdrop = backdrop,
                onConnectOrOpenSettings = onConnectOrOpenSettings,
                onOpenSettings = onOpenSettings,
                onOpenWindows = onOpenWindows,
                onEnterOmniDesktop = onEnterOmniDesktop,
            )
        }

        // iOS-style Bottom-Left "完整显示" Frosted Reset Pill when zoomed in
        val navPad = WindowInsets.navigationBars.asPaddingValues()
        if (state.hasLiveVideo && state.zoom > 1.02f) {
            FrostedGlassBox(
                palette = palette,
                backdrop = backdrop,
                shape = CircleShape,
                blurRadius = 22.dp,
                shadowElevation = 10.dp,
                modifier = Modifier
                    .align(Alignment.BottomStart)
                    .padding(start = 16.dp, bottom = navPad.calculateBottomPadding() + 18.dp)
                    .clickable { onResetViewport() }
                    .testTag("btnResetZoom"),
            ) {
                Row(
                    modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Icon(
                        imageVector = Icons.Default.FitScreen,
                        contentDescription = null,
                        tint = palette.primaryText,
                        modifier = Modifier.size(16.dp),
                    )
                    Text("完整显示", fontSize = 13.sp, fontWeight = FontWeight.Medium, color = palette.primaryText)
                }
            }
        }

        // Virtual macOS Cursor & Touch Ripple Overlay
        Canvas(modifier = Modifier.fillMaxSize()) {
            val ripple = state.lastRipple
            if (ripple != null && rippleAnim.value < 0.99f) {
                val p = rippleAnim.value
                val color = if (ripple.isSecondary) Color(0xFFFF9F0A) else palette.accentBlue
                drawCircle(
                    color = color.copy(alpha = (1f - p) * 0.65f),
                    radius = 10.dp.toPx() + p * 22.dp.toPx(),
                    center = Offset(ripple.viewX, ripple.viewY),
                    style = Stroke(width = 2.dp.toPx()),
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
private fun IosStyleIdleWorkspace(
    state: WorkspaceUiState,
    palette: GlassPalette,
    backdrop: LiveVideoBackdrop,
    onConnectOrOpenSettings: () -> Unit,
    onOpenSettings: () -> Unit,
    onOpenWindows: () -> Unit,
    onEnterOmniDesktop: () -> Unit,
) {
    val navPad = WindowInsets.navigationBars.asPaddingValues()
    if (state.phase == ConnectionPhase.CONNECTED && state.dataChannelOpen && state.selectedWindow != null) {
        // Connected and window chosen, waiting for first decoded frame ("等待首帧…" frosted capsule)
        Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            FrostedGlassBox(
                palette = palette,
                backdrop = backdrop,
                shape = CircleShape,
                blurRadius = 24.dp,
            ) {
                Row(
                    modifier = Modifier.padding(horizontal = 18.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(18.dp),
                        strokeWidth = 2.dp,
                        color = palette.accentBlue,
                    )
                    Text("等待首帧…", fontSize = 14.sp, color = palette.primaryText)
                }
            }
        }
        return
    }

    // Exact iPhone centered hero workspace ("把桌面窗口，带到手边")
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 28.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Spacer(Modifier.weight(1f))

        Icon(
            imageVector = Icons.Default.DesktopWindows,
            contentDescription = null,
            tint = palette.accentBlue,
            modifier = Modifier.size(48.dp),
        )
        Spacer(Modifier.height(18.dp))

        Text(
            text = if (state.dataChannelOpen) "请选择远端窗口" else "把桌面窗口，带到手边",
            fontSize = 23.sp,
            fontWeight = FontWeight.Bold,
            color = palette.primaryText,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(8.dp))

        Text(
            text = when {
                state.dataChannelOpen -> "${state.activeHost?.name ?: "Mac"} 已直连，点击下方选择应用窗口开始。"
                state.phase == ConnectionPhase.IDLE -> "连接 Mac，选择一个应用窗口开始。"
                else -> state.statusText
            },
            fontSize = 15.sp,
            color = palette.secondaryText,
            textAlign = TextAlign.Center,
        )

        if (state.phase == ConnectionPhase.CONNECTING_COORD ||
            state.phase == ConnectionPhase.HANDSHAKING ||
            state.phase == ConnectionPhase.ICE_CHECKING
        ) {
            Spacer(Modifier.height(16.dp))
            CircularProgressIndicator(
                modifier = Modifier.size(22.dp),
                strokeWidth = 2.2.dp,
                color = palette.accentBlue,
            )
        }

        Spacer(Modifier.height(22.dp))

        // Primary Apple Blue Pill Button
        val primaryLabel = when {
            state.dataChannelOpen -> "选择远端窗口"
            state.activeHost != null -> "连接 ${state.activeHost.name}"
            else -> "连接主机"
        }
        Box(
            modifier = Modifier
                .clip(RoundedCornerShape(14.dp))
                .background(palette.accentBlue)
                .clickable {
                    if (state.dataChannelOpen) onOpenWindows() else onConnectOrOpenSettings()
                }
                .padding(horizontal = 26.dp, vertical = 13.dp)
                .testTag("phoneConnect"),
        ) {
            Text(
                text = primaryLabel,
                fontSize = 16.sp,
                fontWeight = FontWeight.SemiBold,
                color = Color.White,
            )
        }

        Spacer(Modifier.height(14.dp))

        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(
                text = "Omni-Desktop 全桌面",
                fontSize = 15.sp,
                fontWeight = FontWeight.SemiBold,
                color = palette.accentBlue,
                modifier = Modifier
                    .clip(RoundedCornerShape(8.dp))
                    .clickable(onClick = onEnterOmniDesktop)
                    .padding(horizontal = 10.dp, vertical = 6.dp)
                    .testTag("btnEnterOmniHero"),
            )
            Text("·", fontSize = 14.sp, color = palette.secondaryText)
            Text(
                text = "连接设置",
                fontSize = 15.sp,
                fontWeight = FontWeight.Medium,
                color = palette.accentBlue,
                modifier = Modifier
                    .clip(RoundedCornerShape(8.dp))
                    .clickable(onClick = onOpenSettings)
                    .padding(horizontal = 10.dp, vertical = 6.dp)
                    .testTag("btnOpenSettingsHero"),
            )
        }

        state.errorText?.let { err ->
            Spacer(Modifier.height(10.dp))
            Text(
                text = err,
                fontSize = 12.sp,
                color = palette.destructiveRed,
                textAlign = TextAlign.Center,
            )
        }

        Spacer(Modifier.weight(1f))

        Text(
            text = if (state.dataChannelOpen) "已连接 · ${state.activeHost?.name.orEmpty()}" else state.statusText,
            fontSize = 12.sp,
            color = palette.secondaryText,
            modifier = Modifier.padding(bottom = navPad.calculateBottomPadding() + 18.dp),
        )
    }
}

@Composable
private fun FloatingIosCapsuleDock(
    state: WorkspaceUiState,
    palette: GlassPalette,
    backdrop: LiveVideoBackdrop,
    showMenu: Boolean,
    onToggleMenu: () -> Unit,
    onDismissMenu: () -> Unit,
    onToggleKeyboard: () -> Unit,
    onOpenWindows: () -> Unit,
    onToggleOmniDesktop: () -> Unit,
    onTogglePointerMode: () -> Unit,
    onSetScaleMode: (CanvasScaleMode) -> Unit,
    onZoomIn: () -> Unit,
    onToggleHdr: () -> Unit,
    onToggleLinkQualityBar: () -> Unit,
    onSendQuickKey: (String) -> Unit,
    onOpenSettings: () -> Unit,
    onOpenDiagnostics: () -> Unit,
    onStopViewingKeepConn: () -> Unit,
    onDisconnect: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val navPad = WindowInsets.navigationBars.asPaddingValues()
    val configuration = LocalConfiguration.current
    val view = LocalView.current
    var offsetX by remember { mutableFloatStateOf(0f) }
    var offsetY by remember { mutableFloatStateOf(0f) }

    // Reset dock offset cleanly when folding / unfolding changes window dimensions (matches IPhoneWindowWorkspace)
    LaunchedEffect(view.width, view.height) {
        offsetX = 0f
        offsetY = 0f
    }

    val dragModifier = Modifier.pointerInput(Unit) {
        detectDragGestures { change, dragAmount ->
            change.consume()
            val maxLeft = -max(0f, view.width.toFloat() - 220f)
            val maxUp = -max(0f, view.height.toFloat() - 180f)
            offsetX = (offsetX + dragAmount.x).coerceIn(maxLeft, 0f)
            offsetY = (offsetY + dragAmount.y).coerceIn(maxUp, 0f)
        }
    }

    Column(
        horizontalAlignment = Alignment.End,
        verticalArrangement = Arrangement.spacedBy(10.dp),
        modifier = modifier
            .padding(
                start = 14.dp,
                end = 14.dp,
                bottom = if (state.showKeyboardBar) 14.dp else navPad.calculateBottomPadding() + 14.dp,
            )
            .offset { IntOffset(offsetX.roundToInt(), offsetY.roundToInt()) },
    ) {
        // iOS-style Frosted Glass Context Menu anchored right above the capsule
        AnimatedVisibility(
            visible = showMenu,
            enter = fadeIn(tween(150)) + scaleIn(
                initialScale = 0.90f,
                transformOrigin = TransformOrigin(0.92f, 1.0f),
                animationSpec = tween(170),
            ),
            exit = fadeOut(tween(120)) + scaleOut(
                targetScale = 0.92f,
                transformOrigin = TransformOrigin(0.92f, 1.0f),
                animationSpec = tween(130),
            ),
        ) {
            FrostedIosContextMenu(
                state = state,
                palette = palette,
                backdrop = backdrop,
                onOpenWindows = onOpenWindows,
                onToggleOmniDesktop = onToggleOmniDesktop,
                onSetScaleMode = onSetScaleMode,
                onZoomIn = onZoomIn,
                onTogglePointerMode = onTogglePointerMode,
                onToggleHdr = onToggleHdr,
                onToggleLinkQualityBar = onToggleLinkQualityBar,
                onSendQuickKey = onSendQuickKey,
                onOpenSettings = onOpenSettings,
                onOpenDiagnostics = onOpenDiagnostics,
                onStopViewingKeepConn = onStopViewingKeepConn,
                onDisconnect = onDisconnect,
            )
        }

        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            // Matching Frosted Glass Link Quality Mini-Toolbar right to the left of the tool capsule
            AnimatedVisibility(
                visible = state.showLinkQualityBar,
                enter = fadeIn(tween(160)) + scaleIn(initialScale = 0.94f, animationSpec = tween(160)),
                exit = fadeOut(tween(130)) + scaleOut(targetScale = 0.94f, animationSpec = tween(130)),
            ) {
                FrostedLinkQualityPill(
                    state = state,
                    palette = palette,
                    backdrop = backdrop,
                    compact = configuration.screenWidthDp < 520,
                    onClick = onOpenDiagnostics,
                    modifier = dragModifier,
                )
            }

            // Exact iPhone 3-button Draggable Frosted Glass Capsule: [⌨️ | 🪟 | ⋯]
            FrostedGlassBox(
                palette = palette,
                backdrop = backdrop,
                shape = CircleShape,
                blurRadius = 26.dp,
                shadowElevation = 14.dp,
                modifier = dragModifier,
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    if (state.hasLiveVideo) {
                        IconButton(
                            onClick = onToggleKeyboard,
                            modifier = Modifier.size(width = 52.dp, height = 48.dp).testTag("phoneKeyboard"),
                        ) {
                            Icon(
                                imageVector = if (state.showKeyboardBar) Icons.Default.KeyboardHide else Icons.Default.Keyboard,
                                contentDescription = if (state.showKeyboardBar) "隐藏键盘" else "键盘",
                                tint = if (state.showKeyboardBar) palette.accentBlue else palette.primaryText,
                                modifier = Modifier.size(20.dp),
                            )
                        }
                        VerticalDivider(modifier = Modifier.height(22.dp), thickness = 0.6.dp, color = palette.dividerColor)
                    }

                    IconButton(
                        onClick = onOpenWindows,
                        enabled = state.dataChannelOpen,
                        modifier = Modifier.size(width = 52.dp, height = 48.dp).testTag("phoneChooseWindow"),
                    ) {
                        Icon(
                            imageVector = Icons.Default.Window,
                            contentDescription = "选择窗口",
                            tint = if (state.dataChannelOpen) palette.primaryText else palette.secondaryText.copy(alpha = 0.42f),
                            modifier = Modifier.size(20.dp),
                        )
                    }
                    VerticalDivider(modifier = Modifier.height(22.dp), thickness = 0.6.dp, color = palette.dividerColor)

                    IconButton(
                        onClick = onToggleMenu,
                        modifier = Modifier.size(width = 52.dp, height = 48.dp).testTag("phoneMenu"),
                    ) {
                        Icon(
                            imageVector = Icons.Default.MoreHoriz,
                            contentDescription = "窗口工具",
                            tint = if (showMenu) palette.accentBlue else palette.primaryText,
                            modifier = Modifier.size(21.dp),
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun FrostedLinkQualityPill(
    state: WorkspaceUiState,
    palette: GlassPalette,
    backdrop: LiveVideoBackdrop,
    compact: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val t = state.telemetry
    val isConnected = state.phase == ConnectionPhase.CONNECTED || state.dataChannelOpen || state.hasLiveVideo
    val rtt = t.rttMs
    val ledColor = when {
        !isConnected -> palette.secondaryText.copy(alpha = 0.45f)
        rtt == null -> Color(0xFF30D158)
        rtt < 45.0 -> Color(0xFF30D158)
        rtt < 110.0 -> Color(0xFFFF9F0A)
        else -> Color(0xFFFF453A)
    }

    val bytesPerSec = if (t.rxBytesPerSec > 0.0) t.rxBytesPerSec else (t.videoMbps * 125_000.0)
    val speedStr = when {
        !isConnected -> "—"
        bytesPerSec >= 1_000_000.0 -> String.format("%.1f MB/s", bytesPerSec / 1_000_000.0)
        bytesPerSec >= 1_000.0 -> String.format("%d KB/s", (bytesPerSec / 1_000.0).roundToInt())
        else -> "0 KB/s"
    }
    val rttStr = rtt?.let { "${it.roundToInt()} ms" } ?: "—"
    val fpsStr = if (state.hasLiveVideo) "${t.fps.roundToInt()} fps" else "—"
    val bitrateStr = if (state.hasLiveVideo || t.videoMbps > 0.01) {
        String.format("%.1f Mbps", t.videoMbps)
    } else {
        "—"
    }

    FrostedGlassBox(
        palette = palette,
        backdrop = backdrop,
        shape = CircleShape,
        blurRadius = 26.dp,
        shadowElevation = 14.dp,
        modifier = modifier
            .height(48.dp)
            .clickable(onClick = onClick)
            .testTag("linkQualityToolbar"),
    ) {
        if (compact) {
            Row(
                modifier = Modifier
                    .height(48.dp)
                    .padding(horizontal = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Box(
                    modifier = Modifier
                        .size(7.dp)
                        .clip(CircleShape)
                        .background(ledColor),
                )
                Text(
                    text = if (isConnected) "$rttStr · $fpsStr · $speedStr" else "待连接",
                    fontSize = 11.5.sp,
                    fontFamily = FontFamily.Monospace,
                    fontWeight = FontWeight.Medium,
                    color = palette.primaryText,
                    maxLines = 1,
                )
            }
        } else {
            Row(
                modifier = Modifier
                    .height(48.dp)
                    .padding(horizontal = 14.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Box(
                    modifier = Modifier
                        .size(7.5.dp)
                        .clip(CircleShape)
                        .background(ledColor),
                )
                QualityMetricCell(label = "速度", value = speedStr, palette = palette)
                VerticalDivider(modifier = Modifier.height(18.dp), thickness = 0.6.dp, color = palette.dividerColor)
                QualityMetricCell(label = "延迟", value = rttStr, palette = palette)
                VerticalDivider(modifier = Modifier.height(18.dp), thickness = 0.6.dp, color = palette.dividerColor)
                QualityMetricCell(label = "帧率", value = fpsStr, palette = palette)
                VerticalDivider(modifier = Modifier.height(18.dp), thickness = 0.6.dp, color = palette.dividerColor)
                QualityMetricCell(label = "码率", value = bitrateStr, palette = palette)
            }
        }
    }
}

@Composable
private fun QualityMetricCell(
    label: String,
    value: String,
    palette: GlassPalette,
) {
    Column(
        horizontalAlignment = Alignment.Start,
        verticalArrangement = Arrangement.Center,
    ) {
        Text(
            text = label,
            fontSize = 9.sp,
            lineHeight = 10.sp,
            fontWeight = FontWeight.Medium,
            color = palette.secondaryText,
            maxLines = 1,
        )
        Text(
            text = value,
            fontSize = 11.5.sp,
            lineHeight = 13.sp,
            fontFamily = FontFamily.Monospace,
            fontWeight = FontWeight.SemiBold,
            color = palette.primaryText,
            maxLines = 1,
        )
    }
}

@Composable
private fun FrostedIosContextMenu(
    state: WorkspaceUiState,
    palette: GlassPalette,
    backdrop: LiveVideoBackdrop,
    onOpenWindows: () -> Unit,
    onToggleOmniDesktop: () -> Unit,
    onSetScaleMode: (CanvasScaleMode) -> Unit,
    onZoomIn: () -> Unit,
    onTogglePointerMode: () -> Unit,
    onToggleHdr: () -> Unit,
    onToggleLinkQualityBar: () -> Unit,
    onSendQuickKey: (String) -> Unit,
    onOpenSettings: () -> Unit,
    onOpenDiagnostics: () -> Unit,
    onStopViewingKeepConn: () -> Unit,
    onDisconnect: () -> Unit,
) {
    FrostedGlassBox(
        palette = palette,
        backdrop = backdrop,
        shape = RoundedCornerShape(18.dp),
        blurRadius = 30.dp,
        shadowElevation = 20.dp,
        modifier = Modifier
            .width(254.dp)
            .heightIn(max = 520.dp)
            .testTag("iosContextMenu"),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState()),
        ) {
            // Header: Current Window Title (matches IPhoneWindowWorkspace Menu Section header)
            val headerTitle = state.selectedWindow?.displayLabel ?: (state.activeHost?.name ?: "KKRemote")
            Text(
                text = headerTitle,
                fontSize = 12.sp,
                fontWeight = FontWeight.Medium,
                color = palette.secondaryText,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 10.dp),
            )
            HorizontalDivider(thickness = 0.6.dp, color = palette.dividerColor)

            IosMenuRow(
                label = if (state.omniDesktopMode) "✓ Omni-Desktop 全桌面" else "Omni-Desktop 全桌面",
                icon = Icons.Default.DesktopWindows,
                palette = palette,
                onClick = onToggleOmniDesktop,
            )
            HorizontalDivider(thickness = 0.6.dp, color = palette.dividerColor)

            IosMenuRow(
                label = "切换窗口",
                icon = Icons.Default.Window,
                palette = palette,
                enabled = state.dataChannelOpen,
                onClick = onOpenWindows,
            )
            HorizontalDivider(thickness = 0.6.dp, color = palette.dividerColor)

            if (state.hasLiveVideo) {
                IosMenuRow(
                    label = if (state.scaleMode == CanvasScaleMode.FILL) "✓ 自动铺满" else "自动铺满",
                    icon = Icons.Default.Fullscreen,
                    palette = palette,
                    onClick = { onSetScaleMode(CanvasScaleMode.FILL) },
                )
                HorizontalDivider(thickness = 0.6.dp, color = palette.dividerColor)

                IosMenuRow(
                    label = if (state.scaleMode == CanvasScaleMode.FIT) "✓ 显示完整窗口" else "显示完整窗口",
                    icon = Icons.Default.FitScreen,
                    palette = palette,
                    onClick = { onSetScaleMode(CanvasScaleMode.FIT) },
                )
                HorizontalDivider(thickness = 0.6.dp, color = palette.dividerColor)

                IosMenuRow(
                    label = "放大画面",
                    icon = Icons.Default.ZoomIn,
                    palette = palette,
                    onClick = onZoomIn,
                )
                HorizontalDivider(thickness = 0.6.dp, color = palette.dividerColor)

                IosMenuRow(
                    label = if (state.inputMode == PointerInputMode.TRACKPAD) "切换为触摸" else "切换为触控板",
                    icon = if (state.inputMode == PointerInputMode.TRACKPAD) Icons.Default.TouchApp else Icons.Default.Mouse,
                    palette = palette,
                    onClick = onTogglePointerMode,
                )
                HorizontalDivider(thickness = 0.6.dp, color = palette.dividerColor)
            }

            // Segmented Display Mode Row ("画面显示：桌面 / HDR")
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 9.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Text("画面显示", fontSize = 14.sp, color = palette.primaryText)
                Row(
                    modifier = Modifier
                        .clip(RoundedCornerShape(8.dp))
                        .background(palette.dividerColor)
                        .padding(2.dp),
                    horizontalArrangement = Arrangement.spacedBy(2.dp),
                ) {
                    val sdrSelected = !state.preferHdr
                    Box(
                        modifier = Modifier
                            .clip(RoundedCornerShape(6.dp))
                            .background(if (sdrSelected) palette.elevatedCardTint else Color.Transparent)
                            .clickable { if (state.preferHdr) onToggleHdr() }
                            .padding(horizontal = 10.dp, vertical = 4.dp),
                    ) {
                        Text("桌面", fontSize = 12.sp, fontWeight = FontWeight.Medium, color = palette.primaryText)
                    }
                    Box(
                        modifier = Modifier
                            .clip(RoundedCornerShape(6.dp))
                            .background(if (!sdrSelected) palette.elevatedCardTint else Color.Transparent)
                            .clickable { if (!state.preferHdr) onToggleHdr() }
                            .padding(horizontal = 10.dp, vertical = 4.dp),
                    ) {
                        Text("HDR", fontSize = 12.sp, fontWeight = FontWeight.Medium, color = palette.primaryText)
                    }
                }
            }
            HorizontalDivider(thickness = 0.6.dp, color = palette.dividerColor)

            if (state.canControl) {
                IosMenuRow("回车", Icons.AutoMirrored.Filled.KeyboardReturn, palette, onClick = { onSendQuickKey("return") })
                HorizontalDivider(thickness = 0.6.dp, color = palette.dividerColor)
                IosMenuRow("退格", Icons.AutoMirrored.Filled.Backspace, palette, onClick = { onSendQuickKey("backspace") })
                HorizontalDivider(thickness = 0.6.dp, color = palette.dividerColor)
                IosMenuRow("取消编辑", Icons.Default.Close, palette, onClick = { onSendQuickKey("escape") })
                HorizontalDivider(thickness = 0.6.dp, color = palette.dividerColor)
            }

            IosMenuRow(
                label = if (state.showLinkQualityBar) "✓ 连接质量栏" else "连接质量栏",
                icon = Icons.Default.Speed,
                palette = palette,
                onClick = onToggleLinkQualityBar,
            )
            HorizontalDivider(thickness = 0.6.dp, color = palette.dividerColor)

            IosMenuRow(
                label = "连接设置",
                icon = Icons.Default.Settings,
                palette = palette,
                onClick = onOpenSettings,
            )
            HorizontalDivider(thickness = 0.6.dp, color = palette.dividerColor)

            IosMenuRow(
                label = "详细数据",
                icon = Icons.Default.Analytics,
                palette = palette,
                onClick = onOpenDiagnostics,
            )

            if (state.selectedWindow != null && state.dataChannelOpen) {
                HorizontalDivider(thickness = 0.6.dp, color = palette.dividerColor)
                IosMenuRow(
                    label = "停止观看，保留连接",
                    icon = Icons.Default.StopCircle,
                    palette = palette,
                    onClick = onStopViewingKeepConn,
                )
            }

            if (state.phase != ConnectionPhase.IDLE) {
                HorizontalDivider(thickness = 0.6.dp, color = palette.dividerColor)
                IosMenuRow(
                    label = "断开连接",
                    icon = Icons.Default.Close,
                    palette = palette,
                    isDestructive = true,
                    onClick = onDisconnect,
                )
            }
        }
    }
}

@Composable
private fun IosMenuRow(
    label: String,
    icon: ImageVector,
    palette: GlassPalette,
    enabled: Boolean = true,
    isDestructive: Boolean = false,
    onClick: () -> Unit,
) {
    val contentColor = when {
        !enabled -> palette.secondaryText.copy(alpha = 0.4f)
        isDestructive -> palette.destructiveRed
        else -> palette.primaryText
    }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(label, fontSize = 15.sp, color = contentColor, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Icon(icon, contentDescription = null, tint = contentColor, modifier = Modifier.size(18.dp))
    }
}

@Composable
private fun FrostedKeyboardComposerBar(
    palette: GlassPalette,
    backdrop: LiveVideoBackdrop,
    canControl: Boolean,
    onSendText: (String) -> Unit,
    onSendKey: (String) -> Unit,
    onClose: () -> Unit,
) {
    val navPad = WindowInsets.navigationBars.asPaddingValues()
    var draft by remember { mutableStateOf("") }

    FrostedGlassBox(
        palette = palette,
        backdrop = backdrop,
        shape = RoundedCornerShape(topStart = 20.dp, topEnd = 20.dp),
        blurRadius = 28.dp,
        shadowElevation = 16.dp,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(
                    start = 14.dp,
                    end = 14.dp,
                    top = 10.dp,
                    bottom = maxOf(10.dp, navPad.calculateBottomPadding()),
                ),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            val keys = listOf(
                "Esc" to "escape",
                "Tab" to "tab",
                "退格" to "backspace",
                "回车" to "return",
                "←" to "left",
                "↑" to "up",
                "↓" to "down",
                "→" to "right",
            )
            Row(
                modifier = Modifier.horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                for ((label, code) in keys) {
                    Box(
                        modifier = Modifier
                            .clip(RoundedCornerShape(9.dp))
                            .background(palette.elevatedCardTint)
                            .border(0.6.dp, palette.hairlineBorder, RoundedCornerShape(9.dp))
                            .clickable(enabled = canControl) { onSendKey(code) }
                            .padding(horizontal = 13.dp, vertical = 6.dp)
                            .testTag("keyBtn_$code"),
                    ) {
                        Text(
                            text = label,
                            fontSize = 13.sp,
                            color = if (canControl) palette.primaryText else palette.secondaryText.copy(alpha = 0.45f),
                        )
                    }
                }
            }

            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .height(42.dp)
                        .clip(RoundedCornerShape(11.dp))
                        .background(palette.elevatedCardTint)
                        .border(0.6.dp, palette.hairlineBorder, RoundedCornerShape(11.dp))
                        .padding(horizontal = 12.dp),
                    contentAlignment = Alignment.CenterStart,
                ) {
                    if (draft.isEmpty()) {
                        Text(
                            text = if (canControl) "输入中英文后发送" else "当前只读（需开启 Mac 辅助功能）",
                            fontSize = 14.sp,
                            color = palette.secondaryText,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                    BasicTextField(
                        value = draft,
                        onValueChange = { draft = it },
                        enabled = canControl,
                        singleLine = true,
                        textStyle = TextStyle(fontSize = 15.sp, color = palette.primaryText),
                        cursorBrush = SolidColor(palette.accentBlue),
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
                        keyboardActions = KeyboardActions(
                            onSend = {
                                if (draft.isNotEmpty()) {
                                    onSendText(draft)
                                    draft = ""
                                }
                            }
                        ),
                        modifier = Modifier.fillMaxWidth().testTag("inputRemoteText"),
                    )
                }

                Box(
                    modifier = Modifier
                        .clip(RoundedCornerShape(10.dp))
                        .background(
                            if (canControl && draft.isNotEmpty()) palette.accentBlue
                            else palette.dividerColor
                        )
                        .clickable(enabled = canControl && draft.isNotEmpty()) {
                            onSendText(draft)
                            draft = ""
                        }
                        .padding(horizontal = 16.dp, vertical = 10.dp)
                        .testTag("btnCommitText"),
                ) {
                    Text(
                        text = "发送",
                        fontSize = 14.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = if (canControl && draft.isNotEmpty()) Color.White else palette.secondaryText,
                    )
                }

                IconButton(onClick = onClose, modifier = Modifier.size(38.dp)) {
                    Icon(Icons.Default.KeyboardHide, contentDescription = "取消", tint = palette.secondaryText)
                }
            }
        }
    }
}

private data class DockAppGroup(
    val processID: Int,
    val application: String,
    val windows: List<RemoteWindow>,
    val iconBase64: String?,
    val hasSelectedWindow: Boolean,
)

@Composable
private fun MacHorizontalWindowDock(
    state: WorkspaceUiState,
    palette: GlassPalette,
    backdrop: LiveVideoBackdrop,
    onSelect: (RemoteWindow) -> Unit,
    onRefresh: () -> Unit,
    onCollapse: () -> Unit,
) {
    val navPad = WindowInsets.navigationBars.asPaddingValues()
    val haptics = LocalHapticFeedback.current

    val appGroups = remember(state.windows, state.selectedWindow, state.appIcons) {
        state.windows
            .groupBy { it.processID }
            .map { (pid, wins) ->
                DockAppGroup(
                    processID = pid,
                    application = wins.first().application,
                    windows = wins,
                    iconBase64 = state.appIcons[pid],
                    hasSelectedWindow = wins.any {
                        it.number == state.selectedWindow?.number && it.processID == state.selectedWindow.processID
                    },
                )
            }
    }

    var expandedPid by remember { mutableStateOf<Int?>(null) }
    var tooltipLabel by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(tooltipLabel) {
        if (tooltipLabel != null) {
            kotlinx.coroutines.delay(1600L)
            tooltipLabel = null
        }
    }

    val expandedGroup = appGroups.firstOrNull { it.processID == expandedPid }

    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier.padding(
            start = 16.dp,
            end = 16.dp,
            bottom = if (state.showKeyboardBar) 10.dp else navPad.calculateBottomPadding() + 10.dp,
        ),
    ) {
        // Authentic macOS Dock App-Window Popover (for apps with 2+ open windows)
        AnimatedVisibility(
            visible = expandedGroup != null,
            enter = fadeIn(tween(130)) + scaleIn(
                initialScale = 0.92f,
                transformOrigin = TransformOrigin(0.5f, 1.0f),
                animationSpec = tween(150),
            ),
            exit = fadeOut(tween(100)) + scaleOut(
                targetScale = 0.94f,
                transformOrigin = TransformOrigin(0.5f, 1.0f),
                animationSpec = tween(110),
            ),
        ) {
            val group = expandedGroup
            if (group != null) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    FrostedGlassBox(
                        palette = palette,
                        backdrop = backdrop,
                        shape = RoundedCornerShape(14.dp),
                        blurRadius = 30.dp,
                        shadowElevation = 16.dp,
                        modifier = Modifier
                            .widthIn(min = 190.dp, max = 300.dp)
                            .clickable(
                                interactionSource = remember { MutableInteractionSource() },
                                indication = null,
                                onClick = {},
                            ),
                    ) {
                        Column(modifier = Modifier.fillMaxWidth()) {
                            Text(
                                text = group.application,
                                fontSize = 11.5.sp,
                                fontWeight = FontWeight.SemiBold,
                                color = palette.secondaryText,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                modifier = Modifier.padding(horizontal = 14.dp, vertical = 7.dp),
                            )
                            HorizontalDivider(thickness = 0.5.dp, color = palette.dividerColor)
                            group.windows.forEachIndexed { index, win ->
                                val isCurrent = state.selectedWindow?.number == win.number &&
                                    state.selectedWindow.processID == win.processID
                                val winTitle = win.title.trim().ifEmpty {
                                    "${win.application} (${win.widthPoints.roundToInt()}×${win.heightPoints.roundToInt()})"
                                }
                                Row(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .clickable {
                                            haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                                            expandedPid = null
                                            if (isCurrent) onCollapse() else onSelect(win)
                                        }
                                        .padding(horizontal = 14.dp, vertical = 9.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                                ) {
                                    Text(
                                        text = winTitle,
                                        fontSize = 13.5.sp,
                                        fontWeight = if (isCurrent) FontWeight.SemiBold else FontWeight.Normal,
                                        color = palette.primaryText,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis,
                                        modifier = Modifier.weight(1f),
                                    )
                                    Icon(
                                        imageVector = if (isCurrent) Icons.Default.Check else Icons.Default.Window,
                                        contentDescription = null,
                                        tint = if (isCurrent) palette.accentBlue else palette.secondaryText.copy(alpha = 0.55f),
                                        modifier = Modifier.size(15.dp),
                                    )
                                }
                                if (index < group.windows.lastIndex) {
                                    HorizontalDivider(thickness = 0.5.dp, color = palette.dividerColor)
                                }
                            }
                        }
                    }
                    Spacer(Modifier.height(8.dp))
                }
            }
        }

        // Single-line macOS Dock floating tooltip pill on long-press preview
        AnimatedVisibility(
            visible = expandedGroup == null && !tooltipLabel.isNullOrBlank(),
            enter = fadeIn(tween(110)),
            exit = fadeOut(tween(140)),
        ) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                FrostedGlassBox(
                    palette = palette,
                    backdrop = backdrop,
                    shape = RoundedCornerShape(8.dp),
                    blurRadius = 22.dp,
                    shadowElevation = 8.dp,
                ) {
                    Text(
                        text = tooltipLabel.orEmpty(),
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Medium,
                        color = palette.primaryText,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier
                            .widthIn(max = 240.dp)
                            .padding(horizontal = 10.dp, vertical = 4.dp),
                    )
                }
                Spacer(Modifier.height(6.dp))
            }
        }

        // Slim, Authentic macOS Sequoia Frosted Glass Dock Shelf (icon-only, ~57dp tall)
        FrostedGlassBox(
            palette = palette,
            backdrop = backdrop,
            shape = RoundedCornerShape(18.dp),
            blurRadius = 34.dp,
            shadowElevation = 18.dp,
            modifier = Modifier
                .widthIn(max = 600.dp)
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                    onClick = {},
                )
                .testTag("macHorizontalDock"),
        ) {
            Row(
                modifier = Modifier.padding(horizontal = 8.dp, vertical = 5.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                if (state.catalogLoading && appGroups.isEmpty()) {
                    Row(
                        modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 1.8.dp, color = palette.accentBlue)
                        Text("正在读取窗口…", fontSize = 12.5.sp, color = palette.secondaryText, maxLines = 1)
                    }
                } else if (appGroups.isEmpty()) {
                    Text(
                        text = "暂无可捕获窗口",
                        fontSize = 12.5.sp,
                        color = palette.secondaryText,
                        maxLines = 1,
                        modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
                    )
                } else {
                    val listState = rememberLazyListState()
                    LaunchedEffect(appGroups.size, state.selectedWindow?.processID) {
                        val idx = appGroups.indexOfFirst { it.hasSelectedWindow }
                        if (idx > 4) {
                            runCatching { listState.scrollToItem(max(0, idx - 4)) }
                        }
                    }
                    val fadeLeft = listState.canScrollBackward
                    val fadeRight = listState.canScrollForward
                    LazyRow(
                        state = listState,
                        modifier = Modifier
                            .weight(1f, fill = false)
                            .graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }
                            .drawWithContent {
                                drawContent()
                                val w = size.width
                                if (w > 24f && (fadeLeft || fadeRight)) {
                                    val edgeFrac = (12.dp.toPx() / w).coerceIn(0.01f, 0.15f)
                                    drawRect(
                                        brush = Brush.horizontalGradient(
                                            0.0f to if (fadeLeft) Color.Transparent else Color.Black,
                                            edgeFrac to Color.Black,
                                            (1f - edgeFrac) to Color.Black,
                                            1.0f to if (fadeRight) Color.Transparent else Color.Black,
                                        ),
                                        blendMode = BlendMode.DstIn,
                                    )
                                }
                            },
                        horizontalArrangement = Arrangement.spacedBy(3.dp),
                        contentPadding = PaddingValues(horizontal = 2.dp),
                    ) {
                        items(appGroups, key = { it.processID }) { group ->
                            MacDockAppTile(
                                group = group,
                                isExpanded = expandedPid == group.processID,
                                palette = palette,
                                onClick = {
                                    haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                                    tooltipLabel = null
                                    if (group.windows.size == 1) {
                                        expandedPid = null
                                        val win = group.windows.first()
                                        val alreadyActive = state.selectedWindow?.number == win.number &&
                                            state.selectedWindow.processID == win.processID
                                        if (alreadyActive && state.hasLiveVideo && state.canControl) onCollapse() else onSelect(win)
                                    } else {
                                        expandedPid = if (expandedPid == group.processID) null else group.processID
                                    }
                                },
                                onLongPress = {
                                    haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                                    val firstTitle = group.windows.first().title.trim()
                                    tooltipLabel = when {
                                        group.windows.size > 1 -> "${group.application}（${group.windows.size} 个窗口）"
                                        firstTitle.isEmpty() || firstTitle.equals(group.application, ignoreCase = true) -> group.application
                                        else -> "${group.application} · $firstTitle"
                                    }
                                },
                            )
                        }
                    }
                }

                // Classic macOS Dock Vertical Hairline Separator
                VerticalDivider(
                    modifier = Modifier
                        .height(30.dp)
                        .padding(horizontal = 4.dp),
                    thickness = 0.8.dp,
                    color = palette.dividerColor,
                )

                // Single Icon-Only Refresh Tile (optically aligned with 41dp app icons)
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    modifier = Modifier
                        .width(42.dp)
                        .clip(RoundedCornerShape(11.dp))
                        .clickable {
                            haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                            expandedPid = null
                            onRefresh()
                        }
                        .testTag("dockUtilRefresh"),
                ) {
                    Box(
                        contentAlignment = Alignment.Center,
                        modifier = Modifier.size(41.dp),
                    ) {
                        Box(
                            contentAlignment = Alignment.Center,
                            modifier = Modifier
                                .size(34.dp)
                                .clip(RoundedCornerShape(9.dp))
                                .background(palette.elevatedCardTint)
                                .border(0.6.dp, palette.hairlineBorder, RoundedCornerShape(9.dp)),
                        ) {
                            Icon(
                                imageVector = Icons.Default.Refresh,
                                contentDescription = "刷新窗口",
                                tint = palette.primaryText.copy(alpha = 0.82f),
                                modifier = Modifier.size(17.dp),
                            )
                        }
                    }
                    Spacer(Modifier.height(6.dp))
                }
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun MacDockAppTile(
    group: DockAppGroup,
    isExpanded: Boolean,
    palette: GlassPalette,
    onClick: () -> Unit,
    onLongPress: () -> Unit,
) {
    val decodedIcon = remember(group.iconBase64) {
        if (group.iconBase64.isNullOrBlank()) null
        else runCatching {
            val bytes = Base64.decode(group.iconBase64, Base64.DEFAULT)
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.asImageBitmap()
        }.getOrNull()
    }

    val scale by animateFloatAsState(
        targetValue = if (isExpanded) 1.14f else 1.0f,
        animationSpec = spring(dampingRatio = 0.68f, stiffness = Spring.StiffnessMedium),
        label = "dockAppScale",
    )

    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier
            .width(45.dp)
            .clip(RoundedCornerShape(11.dp))
            .combinedClickable(
                onClick = onClick,
                onLongClick = onLongPress,
            )
            .semantics { contentDescription = "选择窗口 ${group.application}" },
    ) {
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .size(41.dp)
                .graphicsLayer {
                    scaleX = scale
                    scaleY = scale
                    translationY = if (isExpanded) -4f else 0f
                },
        ) {
            if (decodedIcon != null) {
                Image(
                    bitmap = decodedIcon,
                    contentDescription = group.application,
                    modifier = Modifier.size(40.dp),
                )
            } else {
                val hueSeed = (group.application.hashCode() and 0x7fffffff) % 5
                val gradColors = when (hueSeed) {
                    0 -> listOf(Color(0xFF4CA6FF), Color(0xFF0066CC))
                    1 -> listOf(Color(0xFFFF9F0A), Color(0xFFFF5E3A))
                    2 -> listOf(Color(0xFF32D74B), Color(0xFF1E9E38))
                    3 -> listOf(Color(0xFFBF5AF2), Color(0xFF6E38C9))
                    else -> listOf(Color(0xFF64D2FF), Color(0xFF2D7CF6))
                }
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier
                        .size(34.dp)
                        .shadow(3.dp, RoundedCornerShape(9.dp))
                        .clip(RoundedCornerShape(9.dp))
                        .background(Brush.verticalGradient(gradColors))
                        .border(0.5.dp, Color.White.copy(alpha = 0.28f), RoundedCornerShape(9.dp)),
                ) {
                    Text(
                        text = group.application.take(1).uppercase(),
                        fontSize = 16.sp,
                        fontWeight = FontWeight.Bold,
                        color = Color.White,
                    )
                }
            }

            // Subtle multi-window count pill only when an app owns 2+ open windows
            if (group.windows.size > 1) {
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier
                        .align(Alignment.BottomEnd)
                        .offset(x = (-1).dp, y = (-1).dp)
                        .height(13.dp)
                        .widthIn(min = 13.dp)
                        .clip(CircleShape)
                        .background(palette.elevatedCardTint)
                        .border(0.5.dp, palette.hairlineBorder, CircleShape)
                        .padding(horizontal = 3.dp),
                ) {
                    Text(
                        text = "${group.windows.size}",
                        fontSize = 8.5.sp,
                        lineHeight = 9.sp,
                        fontWeight = FontWeight.Bold,
                        color = palette.primaryText,
                    )
                }
            }
        }

        Spacer(Modifier.height(2.dp))

        // Authentic macOS Dock Active Dot Indicator
        Box(
            modifier = Modifier
                .size(4.dp)
                .clip(CircleShape)
                .background(
                    if (group.hasSelectedWindow) palette.primaryText.copy(alpha = 0.84f)
                    else Color.Transparent
                ),
        )
    }
}

@Composable
private fun FrostedSettingsAndHostsSheet(
    state: WorkspaceUiState,
    palette: GlassPalette,
    onToggleLinkQualityBar: (Boolean) -> Unit,
    onToggleOmniDesktopMode: (Boolean) -> Unit,
    onSelectOmniKeyboardStyle: (OmniKeyboardStyle) -> Unit,
    onImportLink: (String, String) -> Boolean,
    onConnectSaved: (TrustedHostProfile) -> Unit,
    onRemoveSaved: (TrustedHostProfile) -> Unit,
    onDismiss: () -> Unit,
) {
    val context = LocalContext.current
    var rawLink by remember { mutableStateOf("") }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 18.dp, vertical = 16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Spacer(Modifier.width(36.dp))
            Text("连接设置", fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = palette.primaryText)
            Text(
                text = "完成",
                fontSize = 16.sp,
                fontWeight = FontWeight.SemiBold,
                color = palette.accentBlue,
                modifier = Modifier
                    .clip(RoundedCornerShape(8.dp))
                    .clickable(onClick = onDismiss)
                    .padding(horizontal = 8.dp, vertical = 4.dp),
            )
        }

        Text("界面与工作模式", fontSize = 12.sp, fontWeight = FontWeight.Medium, color = palette.secondaryText, modifier = Modifier.padding(start = 6.dp))
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(14.dp))
                .background(palette.elevatedCardTint)
                .border(0.6.dp, palette.hairlineBorder, RoundedCornerShape(14.dp)),
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { onToggleOmniDesktopMode(!state.omniDesktopMode) }
                    .padding(horizontal = 14.dp, vertical = 10.dp)
                    .testTag("rowToggleOmniDesktop"),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Column(modifier = Modifier.weight(1f).padding(end = 10.dp)) {
                    Text("Omni-Desktop 全桌面模式", fontSize = 15.sp, fontWeight = FontWeight.Medium, color = palette.primaryText)
                    Text(
                        text = "上方 100% 满宽显示 Mac 原生桌面，下方自绘键盘与 Dock",
                        fontSize = 11.5.sp,
                        color = palette.secondaryText,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                Switch(
                    checked = state.omniDesktopMode,
                    onCheckedChange = { onToggleOmniDesktopMode(it) },
                    colors = SwitchDefaults.colors(
                        checkedThumbColor = Color.White,
                        checkedTrackColor = palette.accentBlue,
                        uncheckedThumbColor = Color.White,
                        uncheckedTrackColor = palette.dividerColor,
                    ),
                    modifier = Modifier.testTag("switchOmniDesktop"),
                )
            }

            HorizontalDivider(modifier = Modifier.padding(start = 14.dp), thickness = 0.6.dp, color = palette.dividerColor)

            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 14.dp, vertical = 10.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text("自绘虚拟键盘样式", fontSize = 14.sp, fontWeight = FontWeight.Medium, color = palette.primaryText)
                    Text(state.omniKeyboardStyle.fullLabel, fontSize = 11.5.sp, color = palette.secondaryText)
                }
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(10.dp))
                        .background(palette.dividerColor)
                        .padding(3.dp),
                    horizontalArrangement = Arrangement.spacedBy(3.dp),
                ) {
                    for (style in OmniKeyboardStyle.entries) {
                        val selected = state.omniKeyboardStyle == style
                        Box(
                            contentAlignment = Alignment.Center,
                            modifier = Modifier
                                .weight(1f)
                                .clip(RoundedCornerShape(8.dp))
                                .background(if (selected) palette.accentBlue else Color.Transparent)
                                .clickable { onSelectOmniKeyboardStyle(style) }
                                .padding(vertical = 7.dp)
                                .testTag("segOmniStyle_${style.name}"),
                        ) {
                            Text(
                                text = style.shortLabel,
                                fontSize = 12.sp,
                                fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Medium,
                                color = if (selected) Color.White else palette.primaryText,
                                maxLines = 1,
                            )
                        }
                    }
                }
            }

            HorizontalDivider(modifier = Modifier.padding(start = 14.dp), thickness = 0.6.dp, color = palette.dividerColor)

            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { onToggleLinkQualityBar(!state.showLinkQualityBar) }
                    .padding(horizontal = 14.dp, vertical = 10.dp)
                    .testTag("rowToggleLinkQualityBar"),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Column(modifier = Modifier.weight(1f).padding(end = 10.dp)) {
                    Text("显示连接质量工具栏", fontSize = 15.sp, fontWeight = FontWeight.Medium, color = palette.primaryText)
                    Text(
                        text = "实时显示速度、延迟、FPS 与码率",
                        fontSize = 11.5.sp,
                        color = palette.secondaryText,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                Switch(
                    checked = state.showLinkQualityBar,
                    onCheckedChange = { onToggleLinkQualityBar(it) },
                    colors = SwitchDefaults.colors(
                        checkedThumbColor = Color.White,
                        checkedTrackColor = palette.accentBlue,
                        uncheckedThumbColor = Color.White,
                        uncheckedTrackColor = palette.dividerColor,
                    ),
                    modifier = Modifier.testTag("switchLinkQualityBar"),
                )
            }
        }

        if (state.savedHosts.isNotEmpty()) {
            Text("已信任的 Mac 主机", fontSize = 12.sp, fontWeight = FontWeight.Medium, color = palette.secondaryText, modifier = Modifier.padding(start = 6.dp))
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(14.dp))
                    .background(palette.elevatedCardTint)
                    .border(0.6.dp, palette.hairlineBorder, RoundedCornerShape(14.dp))
            ) {
                state.savedHosts.forEachIndexed { idx, host ->
                    val isCurrent = state.activeHost?.key == host.key
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable { onConnectSaved(host) }
                            .padding(horizontal = 14.dp, vertical = 11.dp)
                            .testTag("savedHost_${host.hostId.take(6)}"),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween,
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                Text(host.name, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = palette.primaryText)
                                if (isCurrent) {
                                    Icon(Icons.Default.Check, contentDescription = null, tint = palette.accentBlue, modifier = Modifier.size(16.dp))
                                }
                            }
                            Text(
                                text = "${host.coordUrl} · ${if (host.accessGrant != null) "已获长期授权" else "待认证"}",
                                fontSize = 12.sp,
                                color = palette.secondaryText,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                        IconButton(onClick = { onRemoveSaved(host) }, modifier = Modifier.size(34.dp)) {
                            Icon(Icons.Default.DeleteOutline, contentDescription = "移除主机", tint = palette.secondaryText, modifier = Modifier.size(18.dp))
                        }
                    }
                    if (idx < state.savedHosts.lastIndex) {
                        HorizontalDivider(modifier = Modifier.padding(start = 14.dp), thickness = 0.6.dp, color = palette.dividerColor)
                    }
                }
            }
        }

        Text("导入新配对链接", fontSize = 12.sp, fontWeight = FontWeight.Medium, color = palette.secondaryText, modifier = Modifier.padding(start = 6.dp))
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(42.dp)
                .clip(RoundedCornerShape(12.dp))
                .background(palette.elevatedCardTint)
                .border(0.6.dp, palette.hairlineBorder, RoundedCornerShape(12.dp))
                .padding(horizontal = 12.dp),
            contentAlignment = Alignment.CenterStart,
        ) {
            if (rawLink.isEmpty()) {
                Text("粘贴 https://.../#host=... 配对链接", fontSize = 14.sp, color = palette.secondaryText)
            }
            BasicTextField(
                value = rawLink,
                onValueChange = { rawLink = it },
                singleLine = true,
                textStyle = TextStyle(fontSize = 14.sp, color = palette.primaryText),
                cursorBrush = SolidColor(palette.accentBlue),
                modifier = Modifier.fillMaxWidth().testTag("inputPairingUrl"),
            )
        }

        state.errorText?.let { err ->
            Text(err, fontSize = 12.sp, color = palette.destructiveRed, modifier = Modifier.padding(horizontal = 6.dp))
        }

        Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(
                modifier = Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(12.dp))
                    .background(palette.elevatedCardTint)
                    .border(0.6.dp, palette.hairlineBorder, RoundedCornerShape(12.dp))
                    .clickable {
                        val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
                        val clip = cm?.primaryClip?.getItemAt(0)?.coerceToText(context)?.toString().orEmpty()
                        if (clip.isNotBlank()) {
                            rawLink = clip
                            onImportLink(clip, "")
                        }
                    }
                    .padding(vertical = 12.dp)
                    .testTag("btnPasteAndConnect"),
                horizontalArrangement = Arrangement.Center,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Default.ContentPaste, contentDescription = null, tint = palette.accentBlue, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(6.dp))
                Text("剪贴板导入", fontSize = 14.sp, fontWeight = FontWeight.Medium, color = palette.accentBlue)
            }

            Box(
                modifier = Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(12.dp))
                    .background(if (rawLink.isNotBlank()) palette.accentBlue else palette.dividerColor)
                    .clickable(enabled = rawLink.isNotBlank()) { onImportLink(rawLink, "") }
                    .padding(vertical = 12.dp)
                    .testTag("btnConnectLink"),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = "配对并直连",
                    fontSize = 14.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = if (rawLink.isNotBlank()) Color.White else palette.secondaryText,
                )
            }
        }

        Text(
            text = "本机加密身份：${state.clientIdShort}… · 配对凭证仅经端到端加密通道传输。",
            fontSize = 11.sp,
            color = palette.secondaryText,
            modifier = Modifier.padding(horizontal = 6.dp),
        )
    }
}

@Composable
private fun FrostedDiagnosticsSheet(
    state: WorkspaceUiState,
    palette: GlassPalette,
    onSetScaleMode: (CanvasScaleMode) -> Unit,
    onTogglePreferHdr: () -> Unit,
    onReconnect: () -> Unit,
    onDismiss: () -> Unit,
) {
    val t = state.telemetry
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 18.dp, vertical = 16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = "重连",
                fontSize = 15.sp,
                color = palette.accentBlue,
                modifier = Modifier
                    .clip(RoundedCornerShape(8.dp))
                    .clickable(onClick = onReconnect)
                    .padding(horizontal = 8.dp, vertical = 4.dp),
            )
            Text("详细数据", fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = palette.primaryText)
            Text(
                text = "完成",
                fontSize = 16.sp,
                fontWeight = FontWeight.SemiBold,
                color = palette.accentBlue,
                modifier = Modifier
                    .clip(RoundedCornerShape(8.dp))
                    .clickable(onClick = onDismiss)
                    .padding(horizontal = 8.dp, vertical = 4.dp),
            )
        }

        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(14.dp))
                .background(palette.elevatedCardTint)
                .border(0.6.dp, palette.hairlineBorder, RoundedCornerShape(14.dp))
                .padding(horizontal = 14.dp, vertical = 6.dp)
        ) {
            DiagRow("当前主机", state.activeHost?.name ?: "—", palette)
            HorizontalDivider(thickness = 0.6.dp, color = palette.dividerColor)
            DiagRow("ICE 候选路径", t.candidatePair, palette)
            HorizontalDivider(thickness = 0.6.dp, color = palette.dividerColor)
            DiagRow("网络 RTT", t.rttMs?.let { String.format("%.1f ms", it) } ?: "—", palette)
            HorizontalDivider(thickness = 0.6.dp, color = palette.dividerColor)
            DiagRow("实际编码", t.codec, palette)
            HorizontalDivider(thickness = 0.6.dp, color = palette.dividerColor)
            DiagRow("硬件解码器", t.decoderName, palette)
            HorizontalDivider(thickness = 0.6.dp, color = palette.dividerColor)
            DiagRow("像素尺寸 / 帧率", "${state.videoWidthPx}×${state.videoHeightPx} / ${t.fps.roundToInt()} fps", palette)
            HorizontalDivider(thickness = 0.6.dp, color = palette.dividerColor)
            DiagRow("视频有效载荷", String.format("%.2f Mbps", t.videoMbps), palette)
            HorizontalDivider(thickness = 0.6.dp, color = palette.dividerColor)
            DiagRow("解码 / 抖动缓冲", "${t.decodeMs?.let { String.format("%.1f ms", it) } ?: "—"} / ${t.jitterMs?.let { String.format("%.1f ms", it) } ?: "—"}", palette)
            HorizontalDivider(thickness = 0.6.dp, color = palette.dividerColor)
            DiagRow("累计解码帧 / 关键帧", "${t.framesDecoded} / ${t.keyFramesDecoded}", palette)
            HorizontalDivider(thickness = 0.6.dp, color = palette.dividerColor)
            DiagRow("累计丢包 / NACK / PLI", "${t.packetsLost} / ${t.nackCount} / ${t.pliCount}", palette)
        }
    }
}

@Composable
private fun DiagRow(label: String, value: String, palette: GlassPalette) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 9.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, fontSize = 14.sp, color = palette.primaryText)
        Text(
            text = value,
            fontSize = 13.sp,
            fontFamily = FontFamily.Monospace,
            color = palette.secondaryText,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun OmniDesktopWorkspace(
    state: WorkspaceUiState,
    palette: GlassPalette,
    backdrop: LiveVideoBackdrop,
    videoTrack: VideoTrack?,
    onVideoSizeChanged: (Int, Int) -> Unit,
    onBackdropSampled: (ImageBitmap, WindowEdgeColor?, Long) -> Unit,
    onVideoRectChanged: (Rect) -> Unit,
    onZoomAndPan: (Float, Float, Float) -> Unit,
    onResetViewport: () -> Unit,
    onRemoteClick: (Double, Double, Boolean, Float, Float) -> Unit,
    onRemoteScroll: (Double, Double, Double, Double) -> Unit,
    onTrackpadDelta: (Float, Float) -> Unit,
    onTrackpadClick: (Boolean) -> Unit,
    onTrackpadScroll: (Double, Double) -> Unit,
    onSendRawKey: (Int, List<String>) -> Unit,
    onToggleInputSource: () -> Unit,
    onActivateOmniApp: (RemoteWindow) -> Unit,
    onRefreshWindows: () -> Unit,
    onCycleKeyboardStyle: () -> Unit,
    onExitOmniMode: () -> Unit,
    onConnectOrOpenSettings: () -> Unit,
    onOpenSettings: () -> Unit,
    onOpenDiagnostics: () -> Unit,
) {
    val density = LocalDensity.current
    val statusTopDp = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
    val navBottomDp = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()

    BoxWithConstraints(
        modifier = Modifier
            .fillMaxSize()
            .background(Color(0xFF0B0D12))
            .semantics { testTagsAsResourceId = true }
            .testTag("omniDesktopWorkspace"),
    ) {
        val topInsetDp = 0.dp
        val bottomInsetDp = navBottomDp.coerceAtMost(16.dp)
        val controlBarH = 36.dp
        val minKeyboardBodyH = if (state.omniKeyboardStyle == OmniKeyboardStyle.SLIM_4_ROW) 120.dp else 136.dp
        val maxKeyboardBodyH = if (state.omniKeyboardStyle == OmniKeyboardStyle.SLIM_4_ROW) 158.dp else 182.dp

        val vidW = max(1, state.videoWidthPx)
        val vidH = max(1, state.videoHeightPx)
        val videoAspect = if (state.hasLiveVideo) {
            (vidW.toFloat() / vidH.toFloat()).coerceIn(0.6f, 3.2f)
        } else {
            1728f / 1117f
        }

        // Priority 1: Lock Mac native screen to 100% edge-to-edge full horizontal width first!
        val fullWidthScreenH = maxWidth / videoAspect
        val maxAllowedScreenH = (maxHeight - topInsetDp - controlBarH - minKeyboardBodyH - bottomInsetDp)
            .coerceAtLeast(140.dp)
        val screenStageH = minOf(fullWidthScreenH, maxAllowedScreenH)

        val remainingBelowControl = (maxHeight - topInsetDp - screenStageH - controlBarH - bottomInsetDp)
            .coerceAtLeast(minKeyboardBodyH)
        val keyboardBodyH = remainingBelowControl.coerceIn(minKeyboardBodyH, maxKeyboardBodyH)
        val portraitTrackpadSlackH = (remainingBelowControl - keyboardBodyH).coerceAtLeast(0.dp)

        Column(modifier = Modifier.fillMaxSize()) {
            if (topInsetDp > 0.dp) {
                Spacer(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(topInsetDp)
                        .background(Color(0xFF0B0D12)),
                )
            }

            // 1. Top 100% Full-Width Native Mac Desktop Stage
            OmniTopDisplayStage(
                state = state,
                palette = palette,
                backdrop = backdrop,
                videoTrack = videoTrack,
                onVideoSizeChanged = onVideoSizeChanged,
                onBackdropSampled = onBackdropSampled,
                onVideoRectChanged = onVideoRectChanged,
                onZoomAndPan = onZoomAndPan,
                onResetViewport = onResetViewport,
                onRemoteClick = onRemoteClick,
                onRemoteScroll = onRemoteScroll,
                onConnectOrOpenSettings = onConnectOrOpenSettings,
                onOpenSettings = onOpenSettings,
                onExitOmniMode = onExitOmniMode,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(screenStageH),
            )

            // 2. Slim Frosted Control Strip (Link Quality + Mini Mac App Dock + Quick Shortcuts)
            OmniControlAndDockBar(
                state = state,
                palette = palette,
                onActivateOmniApp = onActivateOmniApp,
                onRefreshWindows = onRefreshWindows,
                onSendRawKey = onSendRawKey,
                onCycleKeyboardStyle = onCycleKeyboardStyle,
                onExitOmniMode = onExitOmniMode,
                onOpenSettings = onOpenSettings,
                onOpenDiagnostics = onOpenDiagnostics,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(controlBarH),
            )

            // 3. Optional Ergonomic Multi-Touch Trackpad Deck on Tall Portrait Screens
            // (Keeps the keyboard compact at the bottom instead of stretching keys huge)
            if (portraitTrackpadSlackH >= 28.dp) {
                OmniFullWidthTrackpadDeck(
                    enabled = state.canControl,
                    onDelta = onTrackpadDelta,
                    onClick = onTrackpadClick,
                    onScroll = onTrackpadScroll,
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(portraitTrackpadSlackH),
                )
            }

            // 4. Custom Self-Drawn Virtual Mac Keyboard (Zero Android System IME)
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(keyboardBodyH + bottomInsetDp)
                    .background(Color(0xFF0D0F14))
                    .padding(bottom = bottomInsetDp),
            ) {
                OmniMacKeyboard(
                    style = state.omniKeyboardStyle,
                    enabled = state.canControl,
                    onSendRawKey = onSendRawKey,
                    onToggleInputSource = onToggleInputSource,
                    onTrackpadDelta = onTrackpadDelta,
                    onTrackpadClick = onTrackpadClick,
                    onTrackpadScroll = onTrackpadScroll,
                    modifier = Modifier.fillMaxSize(),
                )
            }
        }

        // Subtle warning banner overlaid at top of Mac stage if needed
        AnimatedVisibility(
            visible = !state.bannerWarning.isNullOrBlank(),
            enter = fadeIn(tween(180)),
            exit = fadeOut(tween(220)),
            modifier = Modifier
                .align(Alignment.TopCenter)
                .padding(top = topInsetDp + 8.dp, start = 16.dp, end = 16.dp),
        ) {
            FrostedGlassBox(
                palette = palette,
                backdrop = backdrop,
                shape = CircleShape,
                blurRadius = 20.dp,
                shadowElevation = 6.dp,
            ) {
                Text(
                    text = state.bannerWarning.orEmpty(),
                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
                    fontSize = 11.5.sp,
                    color = palette.primaryText,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

@Composable
private fun OmniTopDisplayStage(
    state: WorkspaceUiState,
    palette: GlassPalette,
    backdrop: LiveVideoBackdrop,
    videoTrack: VideoTrack?,
    onVideoSizeChanged: (Int, Int) -> Unit,
    onBackdropSampled: (ImageBitmap, WindowEdgeColor?, Long) -> Unit,
    onVideoRectChanged: (Rect) -> Unit,
    onZoomAndPan: (Float, Float, Float) -> Unit,
    onResetViewport: () -> Unit,
    onRemoteClick: (Double, Double, Boolean, Float, Float) -> Unit,
    onRemoteScroll: (Double, Double, Double, Double) -> Unit,
    onConnectOrOpenSettings: () -> Unit,
    onOpenSettings: () -> Unit,
    onExitOmniMode: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val haptics = LocalHapticFeedback.current
    val density = LocalDensity.current
    var stageSize by remember { mutableStateOf(IntSize.Zero) }
    val gestureMachine = remember {
        InteractionGestureMachine().apply {
            relativeTrackpad = false
            directScroll = true
        }
    }

    val vidW = max(1, state.videoWidthPx)
    val vidH = max(1, state.videoHeightPx)
    val stW = stageSize.width.toFloat()
    val stH = stageSize.height.toFloat()

    val (drawW, drawH) = remember(stW, stH, vidW, vidH) {
        if (stW <= 1f || stH <= 1f) {
            0f to 0f
        } else {
            val s = min(stW / vidW.toFloat(), stH / vidH.toFloat())
            // Snap to exact full width when within 1.5% aspect tolerance so zero sub-pixel seams appear
            val rawW = vidW * s
            val rawH = vidH * s
            if (kotlin.math.abs(rawW - stW) <= stW * 0.015f) {
                stW to stH
            } else {
                rawW to rawH
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
            rippleAnim.animateTo(1f, tween(durationMillis = 220))
        }
    }

    Box(
        modifier = modifier
            .background(Color.Black)
            .clip(RoundedCornerShape(0.dp))
            .onSizeChanged { stageSize = it }
            .testTag("omniTopDisplayStage")
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
                                is GestureAction.RelativeMove -> Unit
                                is GestureAction.Tap -> {
                                    if (win != null && curState.hasLiveVideo) {
                                        curTransform.screenToNormalized(act.point.x, act.point.y)?.let { (u, v) ->
                                            haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                                            onRemoteClick(u * win.widthPoints, v * win.heightPoints, false, act.point.x, act.point.y)
                                        }
                                    }
                                }
                                is GestureAction.SecondaryClick -> {
                                    if (win != null && curState.hasLiveVideo) {
                                        curTransform.screenToNormalized(act.point.x, act.point.y)?.let { (u, v) ->
                                            haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                                            onRemoteClick(u * win.widthPoints, v * win.heightPoints, true, act.point.x, act.point.y)
                                        }
                                    }
                                }
                                is GestureAction.ScrollBegan -> {
                                    if (win != null) {
                                        scrollAnchorPt = curTransform.screenToNormalized(act.origin.x, act.origin.y)?.let { (u, v) ->
                                            (u * win.widthPoints) to (v * win.heightPoints)
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
            },
    ) {
        if (videoTrack != null && drawW > 1f && drawH > 1f) {
            val drawWDp = with(density) { drawW.toDp() }
            val drawHDp = with(density) { drawH.toDp() }
            AndroidView(
                factory = { ctx ->
                    WebRtcTextureView(ctx).also { v ->
                        v.setHdrPqMode(state.negotiatedHdrPq)
                        v.onVideoDimensionsChanged = onVideoSizeChanged
                        v.onBackdropSampled = onBackdropSampled
                        v.bindTrack(videoTrack)
                    }
                },
                update = { view ->
                    view.setHdrPqMode(state.negotiatedHdrPq)
                    view.onVideoDimensionsChanged = onVideoSizeChanged
                    view.onBackdropSampled = onBackdropSampled
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
                        alpha = if (state.hasLiveVideo) 1f else 0f
                    }
                    .onGloballyPositioned { coords ->
                        onVideoRectChanged(coords.boundsInRoot())
                    },
            )
        }

        if (!state.hasLiveVideo) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .background(Color(0xFF10131B))
                    .padding(horizontal = 24.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    if (state.phase == ConnectionPhase.CONNECTING_COORD ||
                        state.phase == ConnectionPhase.HANDSHAKING ||
                        state.phase == ConnectionPhase.ICE_CHECKING ||
                        (state.dataChannelOpen && state.selectedWindow != null)
                    ) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(18.dp),
                            strokeWidth = 2.dp,
                            color = Color(0xFF0A84FF),
                        )
                    } else {
                        Icon(
                            imageVector = Icons.Default.DesktopWindows,
                            contentDescription = null,
                            tint = Color(0xFF0A84FF),
                            modifier = Modifier.size(22.dp),
                        )
                    }
                    Text(
                        text = if (state.dataChannelOpen) "正在载入 Mac 原生全尺寸桌面…" else "Omni-Desktop 原生桌面工作台",
                        fontSize = 15.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = Color(0xFFF3F5FA),
                    )
                }
                Spacer(Modifier.height(6.dp))
                Text(
                    text = state.statusText,
                    fontSize = 12.sp,
                    color = Color(0xFF9AA3B8),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                if (!state.dataChannelOpen) {
                    Spacer(Modifier.height(12.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        Box(
                            modifier = Modifier
                                .clip(RoundedCornerShape(10.dp))
                                .background(Color(0xFF0A84FF))
                                .clickable(onClick = onConnectOrOpenSettings)
                                .padding(horizontal = 16.dp, vertical = 8.dp)
                                .testTag("omniBtnConnect"),
                        ) {
                            Text(
                                text = if (state.activeHost != null) "连接 ${state.activeHost.name}" else "配对并连接 Mac",
                                fontSize = 13.sp,
                                fontWeight = FontWeight.SemiBold,
                                color = Color.White,
                            )
                        }
                        Box(
                            modifier = Modifier
                                .clip(RoundedCornerShape(10.dp))
                                .background(Color(0xFF232836))
                                .clickable(onClick = onOpenSettings)
                                .padding(horizontal = 14.dp, vertical = 8.dp),
                        ) {
                            Text("设置", fontSize = 13.sp, color = Color(0xFFD5DCEB))
                        }
                    }
                }
            }
        }

        if (state.hasLiveVideo && state.zoom > 1.02f) {
            FrostedGlassBox(
                palette = palette,
                backdrop = backdrop,
                shape = CircleShape,
                blurRadius = 20.dp,
                shadowElevation = 8.dp,
                modifier = Modifier
                    .align(Alignment.BottomStart)
                    .padding(start = 10.dp, bottom = 8.dp)
                    .clickable(onClick = onResetViewport),
            ) {
                Text(
                    text = "100% 满宽",
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Medium,
                    color = palette.primaryText,
                    modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp),
                )
            }
        }

        Canvas(modifier = Modifier.fillMaxSize()) {
            val ripple = state.lastRipple
            if (ripple != null && rippleAnim.value < 0.99f) {
                val p = rippleAnim.value
                val color = if (ripple.isSecondary) Color(0xFFFF9F0A) else Color(0xFF0A84FF)
                drawCircle(
                    color = color.copy(alpha = (1f - p) * 0.65f),
                    radius = 8.dp.toPx() + p * 18.dp.toPx(),
                    center = Offset(ripple.viewX, ripple.viewY),
                    style = Stroke(width = 1.8.dp.toPx()),
                )
            }
        }
    }
}

@Composable
private fun OmniControlAndDockBar(
    state: WorkspaceUiState,
    palette: GlassPalette,
    onActivateOmniApp: (RemoteWindow) -> Unit,
    onRefreshWindows: () -> Unit,
    onSendRawKey: (Int, List<String>) -> Unit,
    onCycleKeyboardStyle: () -> Unit,
    onExitOmniMode: () -> Unit,
    onOpenSettings: () -> Unit,
    onOpenDiagnostics: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val haptics = LocalHapticFeedback.current
    val t = state.telemetry
    val isConnected = state.phase == ConnectionPhase.CONNECTED || state.dataChannelOpen || state.hasLiveVideo
    val rtt = t.rttMs
    val ledColor = when {
        !isConnected -> Color(0xFF6B7280)
        rtt == null || rtt < 45.0 -> Color(0xFF30D158)
        rtt < 110.0 -> Color(0xFFFF9F0A)
        else -> Color(0xFFFF453A)
    }
    val bytesPerSec = if (t.rxBytesPerSec > 0.0) t.rxBytesPerSec else (t.videoMbps * 125_000.0)
    val speedStr = when {
        !isConnected -> "—"
        bytesPerSec >= 1_000_000.0 -> String.format("%.1fM/s", bytesPerSec / 1_000_000.0)
        bytesPerSec >= 1_000.0 -> String.format("%dK/s", (bytesPerSec / 1_000.0).roundToInt())
        else -> "0K/s"
    }
    val rttStr = rtt?.let { "${it.roundToInt()}ms" } ?: "—"
    val fpsStr = if (state.hasLiveVideo) "${t.fps.roundToInt()}fps" else "—"

    val dockApps = remember(state.windows, state.appIcons, state.activeOmniAppPid) {
        state.windows
            .filter { !it.isFullDisplay }
            .groupBy { it.processID }
            .map { (pid, wins) ->
                Triple(wins.first(), state.appIcons[pid], state.activeOmniAppPid == pid)
            }
    }

    Row(
        modifier = modifier
            .background(Color(0xFF181B24))
            .border(BorderStroke(0.5.dp, Color.White.copy(alpha = 0.10f)))
            .padding(horizontal = 6.dp, vertical = 3.dp)
            .testTag("omniControlDockBar"),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        // 1. Live Link Quality Pill (respects showLinkQualityBar)
        if (state.showLinkQualityBar) {
            Row(
                modifier = Modifier
                    .height(28.dp)
                    .clip(RoundedCornerShape(8.dp))
                    .background(Color(0xFF222735))
                    .border(0.5.dp, Color.White.copy(alpha = 0.12f), RoundedCornerShape(8.dp))
                    .clickable(onClick = onOpenDiagnostics)
                    .padding(horizontal = 7.dp)
                    .testTag("omniLinkQualityPill"),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.5.dp),
            ) {
                Box(
                    modifier = Modifier
                        .size(6.dp)
                        .clip(CircleShape)
                        .background(ledColor),
                )
                Text(
                    text = if (isConnected) "$rttStr·$fpsStr·$speedStr" else "待直连",
                    fontSize = 10.sp,
                    fontFamily = FontFamily.Monospace,
                    fontWeight = FontWeight.Medium,
                    color = Color(0xFFE5EAF5),
                    maxLines = 1,
                )
            }
        }

        // 2. Center Scrollable Mini Mac App Dock
        LazyRow(
            modifier = Modifier
                .weight(1f)
                .height(30.dp)
                .clip(RoundedCornerShape(8.dp))
                .background(Color(0xFF13161E))
                .padding(horizontal = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            if (dockApps.isEmpty()) {
                item {
                    Text(
                        text = if (state.dataChannelOpen) "Dock 就绪 · 点刷新载入应用" else "等待连接载入 Mac Dock",
                        fontSize = 10.sp,
                        color = Color(0xFF7F8BA3),
                        modifier = Modifier
                            .clickable(enabled = state.dataChannelOpen, onClick = onRefreshWindows)
                            .padding(horizontal = 6.dp),
                    )
                }
            } else {
                items(dockApps, key = { it.first.processID }) { (win, iconB64, isFocusedApp) ->
                    OmniMiniDockIcon(
                        window = win,
                        iconBase64 = iconB64,
                        isActive = isFocusedApp,
                        onClick = {
                            haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                            onActivateOmniApp(win)
                        },
                    )
                }
            }
            if (state.dataChannelOpen) {
                item {
                    Box(
                        contentAlignment = Alignment.Center,
                        modifier = Modifier
                            .size(24.dp)
                            .clip(RoundedCornerShape(6.dp))
                            .background(Color(0xFF222735))
                            .clickable {
                                haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                                onRefreshWindows()
                            }
                            .testTag("omniDockRefresh"),
                    ) {
                        Icon(
                            imageVector = Icons.Default.Refresh,
                            contentDescription = "刷新 Dock",
                            tint = Color(0xFFA8B3CA),
                            modifier = Modifier.size(13.dp),
                        )
                    }
                }
            }
        }

        // 3. Quick Mac Chord & Mode Pills (bounded width on narrow cover screens so Dock stays visible)
        val isNarrowStrip = LocalConfiguration.current.screenWidthDp < 560
        Row(
            modifier = Modifier
                .widthIn(max = if (isNarrowStrip) 158.dp else 440.dp)
                .horizontalScroll(rememberScrollState()),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            OmniMacroChip("Esc", enabled = state.canControl, tag = "omniMacro_esc") {
                onSendRawKey(MacKeyCode.ESCAPE, emptyList())
            }
            OmniMacroChip("⌘Space", enabled = state.canControl, tag = "omniMacro_spotlight") {
                onSendRawKey(MacKeyCode.SPACE, listOf("cmd"))
            }
            OmniMacroChip("⌘Tab", enabled = state.canControl, tag = "omniMacro_cmdtab") {
                onSendRawKey(MacKeyCode.TAB, listOf("cmd"))
            }
            OmniMacroChip("⌘C", enabled = state.canControl, tag = "omniMacro_copy") {
                onSendRawKey(MacKeyCode.C, listOf("cmd"))
            }
            OmniMacroChip("⌘V", enabled = state.canControl, tag = "omniMacro_paste") {
                onSendRawKey(MacKeyCode.V, listOf("cmd"))
            }

            // 1-Tap Keyboard Layout Style Switcher
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .height(27.dp)
                    .clip(RoundedCornerShape(7.dp))
                    .background(Color(0xFF1D3557))
                    .border(0.5.dp, Color(0xFF5EA8FF).copy(alpha = 0.45f), RoundedCornerShape(7.dp))
                    .clickable {
                        haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                        onCycleKeyboardStyle()
                    }
                    .padding(horizontal = 7.dp)
                    .testTag("btnOmniCycleKeyboard"),
            ) {
                Text(
                    text = state.omniKeyboardStyle.shortLabel,
                    fontSize = 10.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = Color(0xFF9ED0FF),
                    maxLines = 1,
                )
            }

            // Exit back to Single-Window Mode
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .height(27.dp)
                    .clip(RoundedCornerShape(7.dp))
                    .background(Color(0xFF232836))
                    .border(0.5.dp, Color.White.copy(alpha = 0.12f), RoundedCornerShape(7.dp))
                    .clickable(onClick = onExitOmniMode)
                    .padding(horizontal = 7.dp)
                    .testTag("btnOmniExit"),
            ) {
                Text(
                    text = "单窗",
                    fontSize = 10.sp,
                    fontWeight = FontWeight.Medium,
                    color = Color(0xFFD5DCEB),
                    maxLines = 1,
                )
            }

            // Settings button
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .size(27.dp)
                    .clip(RoundedCornerShape(7.dp))
                    .background(Color(0xFF232836))
                    .border(0.5.dp, Color.White.copy(alpha = 0.12f), RoundedCornerShape(7.dp))
                    .clickable(onClick = onOpenSettings)
                    .testTag("btnOmniSettings"),
            ) {
                Icon(
                    imageVector = Icons.Default.Settings,
                    contentDescription = "设置",
                    tint = Color(0xFFD5DCEB),
                    modifier = Modifier.size(14.dp),
                )
            }
        }
    }
}

@Composable
private fun OmniMiniDockIcon(
    window: RemoteWindow,
    iconBase64: String?,
    isActive: Boolean,
    onClick: () -> Unit,
) {
    val decodedIcon = remember(iconBase64) {
        if (iconBase64.isNullOrBlank()) null
        else runCatching {
            val bytes = Base64.decode(iconBase64, Base64.DEFAULT)
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.asImageBitmap()
        }.getOrNull()
    }

    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .size(26.dp)
            .clip(RoundedCornerShape(6.dp))
            .background(if (isActive) Color(0xFF0A84FF).copy(alpha = 0.28f) else Color.Transparent)
            .clickable(onClick = onClick)
            .semantics { contentDescription = "激活 ${window.application}" },
    ) {
        if (decodedIcon != null) {
            Image(
                bitmap = decodedIcon,
                contentDescription = window.application,
                modifier = Modifier.size(22.dp),
            )
        } else {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .size(21.dp)
                    .clip(RoundedCornerShape(5.dp))
                    .background(Color(0xFF2E3648)),
            ) {
                Text(
                    text = window.application.take(1).uppercase(),
                    fontSize = 10.sp,
                    fontWeight = FontWeight.Bold,
                    color = Color.White,
                )
            }
        }
    }
}

@Composable
private fun OmniMacroChip(
    label: String,
    enabled: Boolean,
    tag: String,
    onClick: () -> Unit,
) {
    val haptics = LocalHapticFeedback.current
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .height(27.dp)
            .clip(RoundedCornerShape(7.dp))
            .background(Color(0xFF232836))
            .border(0.5.dp, Color.White.copy(alpha = 0.11f), RoundedCornerShape(7.dp))
            .clickable(enabled = enabled) {
                haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                onClick()
            }
            .padding(horizontal = 6.5.dp)
            .testTag(tag),
    ) {
        Text(
            text = label,
            fontSize = 10.sp,
            fontWeight = FontWeight.Medium,
            color = if (enabled) Color(0xFFE5EAF5) else Color(0xFF6B7280),
            maxLines = 1,
        )
    }
}

@Composable
private fun OmniFullWidthTrackpadDeck(
    enabled: Boolean,
    onDelta: (Float, Float) -> Unit,
    onClick: (Boolean) -> Unit,
    onScroll: (Double, Double) -> Unit,
    modifier: Modifier = Modifier,
) {
    val haptics = LocalHapticFeedback.current
    val density = LocalDensity.current.density
    val latestEnabled by remember { mutableStateOf(enabled) }.apply { value = enabled }
    var touchPos by remember { mutableStateOf<Offset?>(null) }

    Box(
        modifier = modifier
            .background(Color(0xFF12151E))
            .padding(horizontal = 8.dp, vertical = 5.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(
                Brush.verticalGradient(
                    colors = listOf(Color(0xFF191D29), Color(0xFF141720)),
                )
            )
            .border(0.7.dp, Color.White.copy(alpha = 0.09f), RoundedCornerShape(12.dp))
            .testTag("omniPortraitTrackpadDeck")
            .pointerInput(density) {
                awaitEachGesture {
                    val first = awaitPointerEvent()
                    val down = first.changes.firstOrNull { it.pressed } ?: return@awaitEachGesture
                    first.changes.forEach { it.consume() }

                    val startMs = System.currentTimeMillis()
                    var maxPointers = first.changes.count { it.pressed }
                    var travel = 0f
                    var prev = down.position
                    touchPos = prev

                    while (true) {
                        val ev = awaitPointerEvent()
                        ev.changes.forEach { it.consume() }
                        val pts = ev.changes.mapNotNull { if (it.pressed) it.position else null }
                        if (pts.isEmpty()) break
                        if (pts.size > maxPointers) {
                            maxPointers = pts.size
                            prev = Offset(pts.map { it.x }.average().toFloat(), pts.map { it.y }.average().toFloat())
                            continue
                        }
                        val cur = Offset(pts.map { it.x }.average().toFloat(), pts.map { it.y }.average().toFloat())
                        touchPos = cur
                        val dx = cur.x - prev.x
                        val dy = cur.y - prev.y
                        prev = cur
                        val dist = kotlin.math.hypot(dx, dy)
                        travel += dist
                        if (!latestEnabled || dist < 0.35f) continue
                        val dxDp = dx / max(1f, density)
                        val dyDp = dy / max(1f, density)
                        if (pts.size >= 2) {
                            onScroll((dxDp * 2.2f).toDouble(), (dyDp * 2.2f).toDouble())
                        } else {
                            val boost = min(2.5f, 1.15f + dist * 0.045f)
                            onDelta(dxDp * boost, dyDp * boost)
                        }
                    }

                    touchPos = null
                    if (latestEnabled && System.currentTimeMillis() - startMs <= 270L && travel <= 11f * density) {
                        val right = maxPointers >= 2
                        haptics.performHapticFeedback(
                            if (right) HapticFeedbackType.LongPress else HapticFeedbackType.TextHandleMove
                        )
                        onClick(right)
                    }
                }
            },
    ) {
        Canvas(modifier = Modifier.fillMaxSize()) {
            touchPos?.let { p ->
                drawCircle(Color(0xFF0A84FF).copy(alpha = 0.22f), radius = 20.dp.toPx(), center = p)
                drawCircle(Color(0xFF8EC8FF).copy(alpha = 0.85f), radius = 4.dp.toPx(), center = p)
            }
        }
        Text(
            text = "MAC MULTI-TOUCH TRACKPAD · 单指移动点按 / 双指滚动右键",
            fontSize = 9.5.sp,
            fontFamily = FontFamily.Monospace,
            color = Color(0xFF7F8BA3).copy(alpha = 0.62f),
            modifier = Modifier.align(Alignment.Center),
        )
    }
}
