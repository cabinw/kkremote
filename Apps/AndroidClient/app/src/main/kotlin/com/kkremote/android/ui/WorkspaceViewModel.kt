package com.kkremote.android.ui

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.kkremote.android.crypto.DeviceIdentity
import com.kkremote.android.crypto.PairingLinkParser
import com.kkremote.android.gesture.TouchPoint
import com.kkremote.android.network.CoordSignalingClient
import com.kkremote.android.protocol.CoordCandidatePayload
import com.kkremote.android.protocol.CoordOfferAnswerPayload
import com.kkremote.android.protocol.RemoteWindow
import com.kkremote.android.protocol.StreamTelemetry
import com.kkremote.android.protocol.TrustedHostProfile
import com.kkremote.android.protocol.WindowInput
import com.kkremote.android.protocol.WindowMessage
import com.kkremote.android.protocol.WindowViewport
import com.kkremote.android.webrtc.NativeWebRtcClient
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.webrtc.PeerConnection
import org.webrtc.VideoTrack
import java.io.File
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

enum class CanvasScaleMode(val label: String) {
    FIT("完整窗口"),
    FILL("铺满视口"),
    PIXEL_1X("1:1 原生像素"),
}

enum class PointerInputMode(val label: String) {
    DIRECT_TOUCH("直点触控"),
    TRACKPAD("触控板指针"),
}

enum class ConnectionPhase {
    IDLE,
    CONNECTING_COORD,
    WAITING_HOST,
    HANDSHAKING,
    ICE_CHECKING,
    CONNECTED,
    FAILED,
}

data class ClickRipple(
    val id: Long,
    val viewX: Float,
    val viewY: Float,
    val isSecondary: Boolean,
)

data class WorkspaceUiState(
    val clientIdShort: String = "",
    val savedHosts: List<TrustedHostProfile> = emptyList(),
    val activeHost: TrustedHostProfile? = null,
    val hostOnline: Boolean = false,
    val phase: ConnectionPhase = ConnectionPhase.IDLE,
    val statusText: String = "未连接 · 请粘贴或导入 Mac 配对链接",
    val bannerWarning: String? = null,
    val errorText: String? = null,
    val dataChannelOpen: Boolean = false,
    val windowLayoutSupported: Boolean = false,
    val windowControlSupported: Boolean = false,
    val directKeyboardSupported: Boolean = false,
    val windows: List<RemoteWindow> = emptyList(),
    val appIcons: Map<Int, String> = emptyMap(),
    val catalogLoading: Boolean = false,
    val selectedWindow: RemoteWindow? = null,
    val controlLease: String? = null,
    val controlFocus: String? = null,
    val videoWidthPx: Int = 0,
    val videoHeightPx: Int = 0,
    val telemetry: StreamTelemetry = StreamTelemetry(),
    val scaleMode: CanvasScaleMode = CanvasScaleMode.FIT,
    val inputMode: PointerInputMode = PointerInputMode.DIRECT_TOUCH,
    val preferHdr: Boolean = false,
    val negotiatedHdrPq: Boolean = false,
    val showLinkQualityBar: Boolean = true,
    val zoom: Float = 1.0f,
    val panX: Float = 0f,
    val panY: Float = 0f,
    val trackpadCursorPt: TouchPoint? = null,
    val lastRipple: ClickRipple? = null,
    val edgeColor: WindowEdgeColor = WindowEdgeColor.Initial,
    val showPairingSheet: Boolean = false,
    val showWindowSheet: Boolean = false,
    val showTelemetrySheet: Boolean = false,
    val showKeyboardBar: Boolean = false,
) {
    val canControl: Boolean
        get() = dataChannelOpen && selectedWindow != null && !controlLease.isNullOrBlank()

    val hasLiveVideo: Boolean
        get() = videoWidthPx > 0 && videoHeightPx > 0
}

@Serializable
private data class ClientUiPrefs(
    val showLinkQualityBar: Boolean = true,
)

class WorkspaceViewModel(application: Application) : AndroidViewModel(application) {

    private val storageJson = Json {
        ignoreUnknownKeys = true
        prettyPrint = true
    }

    private val baseDir = File(application.noBackupFilesDir, "kkremote").apply { mkdirs() }
    private val identity = DeviceIdentity.loadOrCreate(File(baseDir, "client-identity-v1.json"))
    private val hostsFile = File(baseDir, "trusted-hosts-v1.json")
    private val uiPrefsFile = File(baseDir, "ui-prefs-v1.json")

    private val _uiState = MutableStateFlow(
        WorkspaceUiState(
            clientIdShort = identity.deviceId.take(8),
        )
    )
    val uiState: StateFlow<WorkspaceUiState> = _uiState.asStateFlow()

    private val _videoTrack = MutableStateFlow<VideoTrack?>(null)
    val videoTrack: StateFlow<VideoTrack?> = _videoTrack.asStateFlow()

    private var coordClient: CoordSignalingClient? = null
    private var rtcClient: NativeWebRtcClient? = null
    private var activeSessionId: String = ""
    private var autoRetryCount: Int = 0
    private var iceDisconnectWatchdogJob: Job? = null
    private var pendingAutoSelectApp: String? = null

    // Strictly ordered input queue matching macOS HostWindowControl invariants
    private var inputSequence: Int = 0
    private val queuedInputs = ArrayDeque<WindowMessage>()
    private var inFlightInputId: String? = null
    private var inFlightTimeoutJob: Job? = null

    // Coalesced smooth scrolling
    private var pendingScrollPt: TouchPoint? = null
    private var pendingScrollDx: Double = 0.0
    private var pendingScrollDy: Double = 0.0
    private var scrollFlushJob: Job? = null
    private var warningDismissJob: Job? = null
    private var resizeDebounceJob: Job? = null
    private var desiredViewport: WindowViewport? = null
    private var appliedViewport: WindowViewport? = null
    private var pendingViewport: WindowViewport? = null
    private var rippleCounter: Long = 0L

    init {
        val loaded = loadSavedHosts()
        val uiPrefs = loadUiPrefs()
        val mostRecent = loaded.maxByOrNull { it.lastConnectedEpochMs }
        _uiState.update {
            it.copy(
                savedHosts = loaded,
                activeHost = mostRecent,
                showLinkQualityBar = uiPrefs.showLinkQualityBar,
                showPairingSheet = false,
            )
        }
        // Automatically connect to the most recently trusted host on launch if it already holds an AccessGrant!
        if (mostRecent != null && (!mostRecent.accessGrant.isNullOrBlank() || !mostRecent.pendingPairToken.isNullOrBlank())) {
            connectToHost(mostRecent)
        }
    }

    private fun postTransientWarning(message: String?) {
        warningDismissJob?.cancel()
        _uiState.update { it.copy(bannerWarning = message) }
        if (!message.isNullOrBlank()) {
            warningDismissJob = viewModelScope.launch {
                delay(3600L)
                _uiState.update { if (it.bannerWarning == message) it.copy(bannerWarning = null) else it }
            }
        }
    }

    fun importPairingLink(rawLink: String, fallbackCoordUrl: String = ""): Boolean {
        val parsed = PairingLinkParser.parse(rawLink, fallbackCoordUrl)
        if (parsed == null) {
            _uiState.update { it.copy(errorText = "配对链接格式无效，请粘贴完整的 https://.../#host=... 链接") }
            return false
        }
        val existing = _uiState.value.savedHosts.firstOrNull { it.key == parsed.key }
        val merged = parsed.copy(
            accessGrant = existing?.accessGrant,
            lastConnectedEpochMs = System.currentTimeMillis(),
            lastWindowTitle = existing?.lastWindowTitle,
        )
        upsertHost(merged)
        connectToHost(merged)
        return true
    }

    fun connectToHost(profile: TrustedHostProfile) {
        disconnectInternal(keepSheetClosed = true)
        autoRetryCount = 0
        pendingAutoSelectApp = profile.autoSelectApp ?: profile.lastWindowTitle
        _uiState.update {
            it.copy(
                activeHost = profile,
                phase = ConnectionPhase.CONNECTING_COORD,
                statusText = "正在连接协调节点…",
                errorText = null,
                bannerWarning = null,
                showPairingSheet = false,
            )
        }

        val client = CoordSignalingClient(
            appContext = getApplication(),
            identity = identity,
            initialHost = profile,
            Listener = object : CoordSignalingClient.ListenerCallbacks {
                override fun onStatus(status: String) {
                    viewModelScope.launch {
                        _uiState.update { st ->
                            val nextPhase = if (status.contains("等待") && status.contains("上线")) {
                                ConnectionPhase.WAITING_HOST
                            } else if (status.contains("加密认证")) {
                                ConnectionPhase.HANDSHAKING
                            } else st.phase
                            st.copy(statusText = status, phase = nextPhase)
                        }
                    }
                }

                override fun onHostPresence(online: Boolean, hostUpdated: TrustedHostProfile) {
                    viewModelScope.launch {
                        upsertHost(hostUpdated)
                        _uiState.update { st ->
                            st.copy(
                                activeHost = hostUpdated,
                                hostOnline = online,
                                phase = if (!online && st.phase != ConnectionPhase.CONNECTED) {
                                    ConnectionPhase.WAITING_HOST
                                } else st.phase,
                            )
                        }
                    }
                }

                override fun onOfferReceived(
                    sessionId: String,
                    offer: CoordOfferAnswerPayload,
                    stunServers: List<String>,
                    hostUpdated: TrustedHostProfile,
                ) {
                    viewModelScope.launch {
                        upsertHost(hostUpdated)
                        startRtcForOffer(sessionId, offer, stunServers, hostUpdated)
                    }
                }

                override fun onRemoteCandidate(sessionId: String, candidate: CoordCandidatePayload) {
                    viewModelScope.launch {
                        if (sessionId == activeSessionId) {
                            rtcClient?.addRemoteCandidate(candidate)
                        }
                    }
                }

                override fun onRejected(reason: String, hostUpdated: TrustedHostProfile) {
                    viewModelScope.launch {
                        upsertHost(hostUpdated)
                        tearDownMediaOnly()
                        _uiState.update {
                            it.copy(
                                activeHost = hostUpdated,
                                phase = ConnectionPhase.FAILED,
                                statusText = "主机拒绝配对",
                                errorText = reason,
                                showPairingSheet = true,
                            )
                        }
                    }
                }

                override fun onError(message: String) {
                    viewModelScope.launch {
                        if (_uiState.value.phase == ConnectionPhase.CONNECTED) {
                            postTransientWarning(message)
                        } else {
                            _uiState.update { st ->
                                st.copy(
                                    phase = ConnectionPhase.FAILED,
                                    statusText = "连接受阻",
                                    errorText = message,
                                )
                            }
                        }
                    }
                }
            }
        )
        coordClient = client
        client.start()
    }

    fun reconnectActiveHost() {
        val target = _uiState.value.activeHost ?: _uiState.value.savedHosts.firstOrNull()
        if (target != null) {
            connectToHost(target)
        } else {
            _uiState.update { it.copy(showPairingSheet = true) }
        }
    }

    fun disconnect() {
        disconnectInternal(keepSheetClosed = false)
    }

    fun removeHost(profile: TrustedHostProfile) {
        if (_uiState.value.activeHost?.key == profile.key) {
            disconnectInternal(keepSheetClosed = false)
        }
        val remaining = _uiState.value.savedHosts.filterNot { it.key == profile.key }
        persistHosts(remaining)
        _uiState.update {
            it.copy(
                savedHosts = remaining,
                activeHost = remaining.firstOrNull(),
                showPairingSheet = remaining.isEmpty() || it.showPairingSheet,
            )
        }
    }

    fun refreshWindows() {
        val rtc = rtcClient ?: return
        _uiState.update { it.copy(catalogLoading = true) }
        val sent = rtc.sendWindowCommand(
            WindowMessage(
                action = "list",
                requestID = DeviceIdentity.randomHex(8),
            )
        )
        if (!sent) {
            _uiState.update { it.copy(catalogLoading = false) }
        }
    }

    fun onClientViewportChanged(widthDp: Double, heightDp: Double, displayScale: Double) {
        if (!widthDp.isFinite() || !heightDp.isFinite() || !displayScale.isFinite()) return
        val clampedW = widthDp.roundToInt().toDouble().coerceIn(200.0, 2000.0)
        val clampedH = heightDp.roundToInt().toDouble().coerceIn(150.0, 2000.0)
        val clampedScale = ((displayScale * 100.0).roundToInt() / 100.0).coerceIn(1.0, 3.0)
        val prev = desiredViewport
        if (prev != null &&
            abs(prev.width - clampedW) < 4.0 &&
            abs(prev.height - clampedH) < 4.0 &&
            abs((prev.displayScale ?: clampedScale) - clampedScale) < 0.05
        ) {
            return
        }
        desiredViewport = WindowViewport(width = clampedW, height = clampedH, displayScale = clampedScale)
        scheduleWindowResizeIfNeeded()
    }

    private fun scheduleWindowResizeIfNeeded() {
        resizeDebounceJob?.cancel()
        resizeDebounceJob = viewModelScope.launch {
            delay(350L)
            val st = _uiState.value
            val win = st.selectedWindow ?: return@launch
            val vp = desiredViewport ?: return@launch
            val rtc = rtcClient ?: return@launch
            if (!st.dataChannelOpen || !st.windowLayoutSupported || vp == appliedViewport) return@launch
            pendingViewport = vp
            rtc.sendWindowCommand(
                WindowMessage(
                    action = "resize",
                    requestID = DeviceIdentity.randomHex(8),
                    windowID = win.id,
                    viewport = vp,
                )
            )
        }
    }

    fun selectWindow(window: RemoteWindow) {
        val rtc = rtcClient
        if (rtc == null) {
            pendingAutoSelectApp = window.application
            _uiState.update { it.copy(showWindowSheet = false) }
            reconnectActiveHost()
            return
        }
        resizeDebounceJob?.cancel()
        resetInputQueue()
        val vp = if (_uiState.value.windowLayoutSupported) desiredViewport else null
        pendingViewport = vp
        _uiState.update {
            it.copy(
                statusText = "正在切换窗口…",
                showWindowSheet = false,
            )
        }
        val sent = rtc.sendWindowCommand(
            WindowMessage(
                action = "select",
                requestID = DeviceIdentity.randomHex(8),
                windowID = window.id,
                viewport = vp,
            )
        )
        if (!sent) {
            pendingAutoSelectApp = window.application
            handleMediaLostAndRecover("控制通道已断开，正在自动恢复并切换窗口…")
        }
    }

    fun stopViewingKeepConnection() {
        val rtc = rtcClient ?: return
        resizeDebounceJob?.cancel()
        pendingViewport = null
        appliedViewport = null
        resetInputQueue()
        _uiState.update {
            it.copy(
                selectedWindow = null,
                controlLease = null,
                videoWidthPx = 0,
                videoHeightPx = 0,
                edgeColor = WindowEdgeColor.Initial,
                showWindowSheet = true,
                showKeyboardBar = false,
                statusText = "请选择远端窗口",
            )
        }
        rtc.sendWindowCommand(
            WindowMessage(
                action = "unsubscribe",
                requestID = DeviceIdentity.randomHex(8),
            )
        )
    }

    fun onEdgeColorSampled(color: WindowEdgeColor?) {
        if (color != null) {
            _uiState.update { it.copy(edgeColor = color) }
        }
    }

    fun zoomInStep() {
        _uiState.update { st ->
            st.copy(zoom = (st.zoom + 0.5f).coerceIn(1.0f, 4.0f))
        }
    }

    fun onVideoSizeChanged(widthPx: Int, heightPx: Int) {
        _uiState.update { it.copy(videoWidthPx = widthPx, videoHeightPx = heightPx) }
    }

    fun setScaleMode(mode: CanvasScaleMode) {
        _uiState.update { it.copy(scaleMode = mode, zoom = 1.0f, panX = 0f, panY = 0f) }
    }

    fun togglePointerMode() {
        _uiState.update { st ->
            val next = if (st.inputMode == PointerInputMode.DIRECT_TOUCH) {
                PointerInputMode.TRACKPAD
            } else {
                PointerInputMode.DIRECT_TOUCH
            }
            val initialCursor = st.selectedWindow?.let { win ->
                TouchPoint((win.widthPoints * 0.5).toFloat(), (win.heightPoints * 0.5).toFloat())
            }
            st.copy(inputMode = next, trackpadCursorPt = initialCursor)
        }
    }

    fun togglePreferHdr() {
        val next = !_uiState.value.preferHdr
        _uiState.update { it.copy(preferHdr = next) }
        if (_uiState.value.phase == ConnectionPhase.CONNECTED) {
            coordClient?.requestNewSession()
        }
    }

    fun updateZoomAndPan(zoomFactor: Float, panDx: Float, panDy: Float) {
        _uiState.update { st ->
            val newZoom = (st.zoom * zoomFactor).coerceIn(1.0f, 4.0f)
            if (newZoom <= 1.01f && st.scaleMode == CanvasScaleMode.FIT) {
                st.copy(zoom = 1.0f, panX = 0f, panY = 0f)
            } else {
                st.copy(
                    zoom = newZoom,
                    panX = (st.panX + panDx).coerceIn(-2400f, 2400f),
                    panY = (st.panY + panDy).coerceIn(-2400f, 2400f),
                )
            }
        }
    }

    fun resetViewport() {
        _uiState.update { it.copy(zoom = 1.0f, panX = 0f, panY = 0f) }
    }

    fun moveTrackpadCursor(deltaPtX: Float, deltaPtY: Float) {
        val win = _uiState.value.selectedWindow ?: return
        _uiState.update { st ->
            val cur = st.trackpadCursorPt
                ?: TouchPoint((win.widthPoints * 0.5).toFloat(), (win.heightPoints * 0.5).toFloat())
            val nx = (cur.x + deltaPtX).coerceIn(0f, max(0f, win.widthPoints.toFloat() - 0.5f))
            val ny = (cur.y + deltaPtY).coerceIn(0f, max(0f, win.heightPoints.toFloat() - 0.5f))
            st.copy(trackpadCursorPt = TouchPoint(nx, ny))
        }
    }

    fun sendRemoteClick(macX: Double, macY: Double, isSecondary: Boolean, rippleViewX: Float, rippleViewY: Float) {
        rippleCounter += 1L
        _uiState.update {
            it.copy(
                lastRipple = ClickRipple(rippleCounter, rippleViewX, rippleViewY, isSecondary),
                trackpadCursorPt = TouchPoint(macX.toFloat(), macY.toFloat()),
            )
        }
        val win = _uiState.value.selectedWindow ?: return
        if (!_uiState.value.canControl) return
        val clampedX = min(win.widthPoints - 0.5, max(0.0, macX))
        val clampedY = min(win.heightPoints - 0.5, max(0.0, macY))
        enqueueInput(
            kind = if (isSecondary) "secondary" else "click",
            x = clampedX,
            y = clampedY,
        )
    }

    fun queueRemoteScroll(macX: Double, macY: Double, dxPoints: Double, dyPoints: Double) {
        val win = _uiState.value.selectedWindow ?: return
        if (!_uiState.value.canControl) return
        val clampedX = min(win.widthPoints - 0.5, max(0.0, macX))
        val clampedY = min(win.heightPoints - 0.5, max(0.0, macY))
        pendingScrollPt = TouchPoint(clampedX.toFloat(), clampedY.toFloat())
        pendingScrollDx = (pendingScrollDx + dxPoints).coerceIn(-900.0, 900.0)
        pendingScrollDy = (pendingScrollDy + dyPoints).coerceIn(-900.0, 900.0)
        if (scrollFlushJob != null) return
        scrollFlushJob = viewModelScope.launch {
            delay(45L)
            scrollFlushJob = null
            val pt = pendingScrollPt ?: return@launch
            val dx = pendingScrollDx
            val dy = pendingScrollDy
            pendingScrollDx = 0.0
            pendingScrollDy = 0.0
            if (dx != 0.0 || dy != 0.0) {
                enqueueInput(
                    kind = "scroll",
                    x = pt.x.toDouble(),
                    y = pt.y.toDouble(),
                    dx = dx,
                    dy = dy,
                )
            }
        }
    }

    fun sendRemoteText(text: String) {
        val clean = text.replace("\u0000", "")
        if (clean.isEmpty() || !_uiState.value.canControl) return
        if (_uiState.value.controlFocus == null) {
            enqueueInput(kind = "focus")
        }
        enqueueInput(kind = "insertText", text = clean.take(2000))
    }

    fun sendRemoteKey(keyName: String) {
        if (!_uiState.value.canControl) return
        if (_uiState.value.controlFocus == null) {
            enqueueInput(kind = "focus")
        }
        enqueueInput(kind = "key", key = keyName)
    }

    fun setShowPairingSheet(visible: Boolean) = _uiState.update { it.copy(showPairingSheet = visible, errorText = null) }
    fun setShowWindowSheet(visible: Boolean) {
        _uiState.update { it.copy(showWindowSheet = visible) }
        if (visible) refreshWindows()
    }
    fun setShowTelemetrySheet(visible: Boolean) = _uiState.update { it.copy(showTelemetrySheet = visible) }
    fun setShowLinkQualityBar(enabled: Boolean) {
        _uiState.update { it.copy(showLinkQualityBar = enabled) }
        persistUiPrefs(ClientUiPrefs(showLinkQualityBar = enabled))
    }
    fun toggleLinkQualityBar() {
        setShowLinkQualityBar(!_uiState.value.showLinkQualityBar)
    }
    fun setShowKeyboardBar(visible: Boolean) {
        _uiState.update { it.copy(showKeyboardBar = visible) }
        if (visible && _uiState.value.canControl) {
            enqueueInput(kind = "focus")
        }
    }

    private fun startRtcForOffer(
        sessionId: String,
        offer: CoordOfferAnswerPayload,
        stunServers: List<String>,
        hostUpdated: TrustedHostProfile,
    ) {
        if (pendingAutoSelectApp == null) {
            pendingAutoSelectApp = _uiState.value.selectedWindow?.application ?: hostUpdated.lastWindowTitle
        }
        tearDownMediaOnly()
        activeSessionId = sessionId
        val winSession = offer.windowSession.orEmpty()
        _uiState.update {
            it.copy(
                phase = ConnectionPhase.ICE_CHECKING,
                statusText = "正在与 ${hostUpdated.name} 建立原生 P2P 打洞…",
                windowLayoutSupported = offer.windowLayout == true,
                windowControlSupported = offer.windowControl == true,
                directKeyboardSupported = offer.windowKeyboard == true,
                errorText = null,
            )
        }

        val rtc = NativeWebRtcClient(
            context = getApplication(),
            sessionId = sessionId,
            windowSession = winSession,
            stunServers = stunServers,
            preferHdr = _uiState.value.preferHdr,
            callbacks = object : NativeWebRtcClient.Callbacks {
                override fun onLocalAnswer(sessionId: String, sdp: String, dtlsFingerprint: String, videoFormat: String) {
                    viewModelScope.launch {
                        if (sessionId == activeSessionId) {
                            _uiState.update { it.copy(negotiatedHdrPq = videoFormat == "hevc-main10-pq") }
                        }
                    }
                    coordClient?.sendAnswer(sessionId, sdp, dtlsFingerprint, videoFormat)
                }

                override fun onLocalIceCandidate(sessionId: String, candidate: String, sdpMid: String?, sdpMLineIndex: Int) {
                    coordClient?.sendCandidate(sessionId, candidate, sdpMid, sdpMLineIndex)
                }

                override fun onIceConnectionState(sessionId: String, state: PeerConnection.IceConnectionState) {
                    viewModelScope.launch {
                        if (sessionId != activeSessionId) return@launch
                        when (state) {
                            PeerConnection.IceConnectionState.CHECKING -> {
                                iceDisconnectWatchdogJob?.cancel()
                                _uiState.update { it.copy(phase = ConnectionPhase.ICE_CHECKING, statusText = "ICE 打洞中…") }
                            }

                            PeerConnection.IceConnectionState.CONNECTED,
                            PeerConnection.IceConnectionState.COMPLETED -> {
                                iceDisconnectWatchdogJob?.cancel()
                                autoRetryCount = 0
                                _uiState.update {
                                    it.copy(
                                        phase = ConnectionPhase.CONNECTED,
                                        statusText = "原生 P2P 已直连",
                                        bannerWarning = null,
                                        errorText = null,
                                    )
                                }
                            }

                            PeerConnection.IceConnectionState.DISCONNECTED -> {
                                postTransientWarning("无线链路短暂波动，正在等待恢复…")
                                iceDisconnectWatchdogJob?.cancel()
                                iceDisconnectWatchdogJob = viewModelScope.launch {
                                    delay(4000L)
                                    if (sessionId == activeSessionId) {
                                        handleMediaLostAndRecover("网络路径变更，正在自动重新打洞…")
                                    }
                                }
                            }

                            PeerConnection.IceConnectionState.FAILED,
                            PeerConnection.IceConnectionState.CLOSED -> {
                                iceDisconnectWatchdogJob?.cancel()
                                handleMediaLostAndRecover("5G/NAT 端口跳变，正在自动重协商直连…")
                            }

                            else -> Unit
                        }
                    }
                }

                override fun onVideoTrack(sessionId: String, track: VideoTrack) {
                    viewModelScope.launch {
                        if (sessionId == activeSessionId) {
                            _videoTrack.value = track
                        }
                    }
                }

                override fun onDataChannelOpen(sessionId: String) {
                    viewModelScope.launch {
                        if (sessionId != activeSessionId) return@launch
                        _uiState.update { it.copy(dataChannelOpen = true) }
                        refreshWindows()
                    }
                }

                override fun onDataChannelClosed(sessionId: String) {
                    viewModelScope.launch {
                        if (sessionId != activeSessionId) return@launch
                        handleMediaLostAndRecover("控制通道已断开，正在自动恢复连接…")
                    }
                }

                override fun onWindowMessage(sessionId: String, message: WindowMessage) {
                    viewModelScope.launch {
                        if (sessionId == activeSessionId) {
                            handleWindowMessage(message)
                        }
                    }
                }

                override fun onTelemetry(sessionId: String, telemetry: StreamTelemetry) {
                    viewModelScope.launch {
                        if (sessionId == activeSessionId) {
                            _uiState.update { st ->
                                val isHdrStream = when {
                                    telemetry.codec.contains("H265", ignoreCase = true) -> true
                                    telemetry.codec.contains("H264", ignoreCase = true) -> false
                                    else -> st.negotiatedHdrPq
                                }
                                st.copy(
                                    telemetry = telemetry,
                                    negotiatedHdrPq = isHdrStream,
                                    videoWidthPx = if (telemetry.width > 0) telemetry.width else st.videoWidthPx,
                                    videoHeightPx = if (telemetry.height > 0) telemetry.height else st.videoHeightPx,
                                )
                            }
                        }
                    }
                }

                override fun onError(sessionId: String, message: String) {
                    viewModelScope.launch {
                        if (sessionId == activeSessionId) {
                            _uiState.update { it.copy(bannerWarning = message) }
                        }
                    }
                }
            }
        )
        rtcClient = rtc
        rtc.acceptOffer(offer)
    }

    private fun handleWindowMessage(cmd: WindowMessage) {
        when (cmd.action) {
            "catalog" -> {
                val list = cmd.windows.orEmpty()
                val newIcons = cmd.appIcons?.mapNotNull { (k, v) ->
                    k.toIntOrNull()?.let { pid -> pid to v }
                }?.toMap().orEmpty()
                _uiState.update {
                    it.copy(
                        windows = list,
                        appIcons = if (newIcons.isEmpty()) it.appIcons else (it.appIcons + newIcons),
                        catalogLoading = false,
                        bannerWarning = cmd.error ?: it.bannerWarning,
                    )
                }
                val currentSelected = _uiState.value.selectedWindow
                val autoTarget = pendingAutoSelectApp
                if (currentSelected == null && list.isNotEmpty()) {
                    val matched = if (!autoTarget.isNullOrBlank()) {
                        list.firstOrNull { win ->
                            win.displayLabel.contains(autoTarget, ignoreCase = true)
                        }
                    } else null
                    pendingAutoSelectApp = null
                    if (matched != null) {
                        selectWindow(matched)
                    } else {
                        _uiState.update { it.copy(showWindowSheet = true) }
                    }
                }
            }

            "selected" -> {
                val win = cmd.selected
                appliedViewport = if (win != null && cmd.error.isNullOrBlank()) {
                    pendingViewport ?: appliedViewport
                } else {
                    null
                }
                pendingViewport = null
                resetInputQueue()
                val initialCursor = win?.let {
                    TouchPoint((it.widthPoints * 0.5).toFloat(), (it.heightPoints * 0.5).toFloat())
                }
                _uiState.update { st ->
                    val controlNote = if (!cmd.controlLease.isNullOrBlank()) {
                        "轻点操作 · 滑动滚动"
                    } else {
                        cmd.error ?: "接收中 · 当前仅支持观看"
                    }
                    st.copy(
                        selectedWindow = win,
                        controlLease = cmd.controlLease,
                        controlFocus = cmd.controlState?.focus ?: if (!cmd.controlLease.isNullOrBlank()) "window" else null,
                        trackpadCursorPt = initialCursor,
                        videoWidthPx = if (win == null) 0 else st.videoWidthPx,
                        videoHeightPx = if (win == null) 0 else st.videoHeightPx,
                        edgeColor = if (win == null) WindowEdgeColor.Initial else st.edgeColor,
                        zoom = 1.0f,
                        panX = 0f,
                        panY = 0f,
                        statusText = if (win != null) "${win.application} · $controlNote" else "请选择远端窗口",
                    )
                }
                if (win != null && !cmd.error.isNullOrBlank()) {
                    postTransientWarning(cmd.error)
                } else {
                    postTransientWarning(null)
                }
                if (win != null && cmd.error.isNullOrBlank()) {
                    _uiState.value.activeHost?.let { active ->
                        upsertHost(active.copy(lastWindowTitle = win.application))
                    }
                    scheduleWindowResizeIfNeeded()
                } else if (win != null) {
                    _uiState.value.activeHost?.let { active ->
                        upsertHost(active.copy(lastWindowTitle = win.application))
                    }
                }
            }

            "inputResult" -> {
                if (cmd.requestID == inFlightInputId) {
                    inFlightTimeoutJob?.cancel()
                    inFlightTimeoutJob = null
                    inFlightInputId = null
                }
                if (!cmd.error.isNullOrBlank()) {
                    postTransientWarning(cmd.error)
                } else if (cmd.controlState?.focus != null) {
                    _uiState.update { it.copy(controlFocus = cmd.controlState.focus) }
                }
                drainNextInput()
            }

            "unavailable" -> {
                resizeDebounceJob?.cancel()
                pendingViewport = null
                appliedViewport = null
                resetInputQueue()
                _uiState.update {
                    it.copy(
                        selectedWindow = null,
                        controlLease = null,
                        videoWidthPx = 0,
                        videoHeightPx = 0,
                        edgeColor = WindowEdgeColor.Initial,
                        showWindowSheet = true,
                        showKeyboardBar = false,
                        statusText = "请选择远端窗口",
                    )
                }
                postTransientWarning(cmd.error ?: "目标窗口已结束观看，请重新选择窗口")
                refreshWindows()
            }

            "error" -> {
                pendingViewport = null
                postTransientWarning(cmd.error ?: "窗口操作未完成，请稍后重试")
                if (_uiState.value.selectedWindow == null) {
                    _uiState.update { it.copy(showWindowSheet = true) }
                }
            }
        }
    }

    private fun enqueueInput(
        kind: String,
        x: Double? = null,
        y: Double? = null,
        dx: Double? = null,
        dy: Double? = null,
        text: String? = null,
        key: String? = null,
    ) {
        val st = _uiState.value
        val lease = st.controlLease ?: return
        val win = st.selectedWindow ?: return
        if (activeSessionId.isEmpty() || queuedInputs.size >= 96) return

        inputSequence += 1
        val input = WindowInput(
            lease = lease,
            sequence = inputSequence,
            kind = kind,
            x = x,
            y = y,
            dx = dx,
            dy = dy,
            text = text,
            focus = st.controlFocus ?: "pending",
            key = key,
        )
        val msg = WindowMessage(
            action = "input",
            requestID = DeviceIdentity.randomHex(8),
            windowID = win.id,
            mediaSession = activeSessionId,
            input = input,
        )
        queuedInputs.addLast(msg)
        drainNextInput()
    }

    private fun drainNextInput() {
        if (inFlightInputId != null || queuedInputs.isEmpty()) return
        val rtc = rtcClient ?: run {
            queuedInputs.clear()
            return
        }
        val next = queuedInputs.removeFirst()
        val currentFocus = _uiState.value.controlFocus ?: "pending"
        val updatedMsg = next.copy(
            input = next.input?.copy(focus = currentFocus)
        )
        if (rtc.sendWindowCommand(updatedMsg)) {
            val reqId = updatedMsg.requestID
            inFlightInputId = reqId
            inFlightTimeoutJob?.cancel()
            inFlightTimeoutJob = viewModelScope.launch {
                delay(900L)
                if (inFlightInputId == reqId) {
                    inFlightInputId = null
                    drainNextInput()
                }
            }
        }
    }

    private fun resetInputQueue() {
        inFlightTimeoutJob?.cancel()
        inFlightTimeoutJob = null
        inFlightInputId = null
        scrollFlushJob?.cancel()
        scrollFlushJob = null
        queuedInputs.clear()
        inputSequence = 0
    }

    private fun handleMediaLostAndRecover(reasonStatus: String) {
        if (pendingAutoSelectApp == null) {
            pendingAutoSelectApp = _uiState.value.selectedWindow?.application
                ?: _uiState.value.activeHost?.lastWindowTitle
        }
        tearDownMediaOnly()
        if (autoRetryCount < 2) {
            autoRetryCount += 1
            _uiState.update {
                it.copy(
                    phase = ConnectionPhase.ICE_CHECKING,
                    statusText = reasonStatus,
                    showWindowSheet = false,
                )
            }
            coordClient?.requestNewSession()
        } else {
            _uiState.update {
                it.copy(
                    phase = ConnectionPhase.FAILED,
                    statusText = "原生 P2P 直连中断",
                    errorText = "网络或 VPN 路由变化导致连接中断，点击下方即可重连",
                    showWindowSheet = false,
                )
            }
        }
    }

    private fun tearDownMediaOnly() {
        iceDisconnectWatchdogJob?.cancel()
        iceDisconnectWatchdogJob = null
        resizeDebounceJob?.cancel()
        pendingViewport = null
        appliedViewport = null
        resetInputQueue()
        activeSessionId = ""
        _videoTrack.value = null
        rtcClient?.close()
        rtcClient = null
        _uiState.update {
            it.copy(
                dataChannelOpen = false,
                selectedWindow = null,
                controlLease = null,
                negotiatedHdrPq = false,
                videoWidthPx = 0,
                videoHeightPx = 0,
                edgeColor = WindowEdgeColor.Initial,
                telemetry = StreamTelemetry(),
            )
        }
    }

    private fun disconnectInternal(keepSheetClosed: Boolean) {
        coordClient?.close()
        coordClient = null
        tearDownMediaOnly()
        _uiState.update {
            it.copy(
                phase = ConnectionPhase.IDLE,
                hostOnline = false,
                statusText = "已断开连接",
                showPairingSheet = if (keepSheetClosed) false else true,
            )
        }
    }

    private fun upsertHost(profile: TrustedHostProfile) {
        val nextList = buildList {
            add(profile)
            for (item in _uiState.value.savedHosts) {
                if (item.key != profile.key) add(item)
            }
        }
        persistHosts(nextList)
        _uiState.update { it.copy(savedHosts = nextList) }
    }

    private fun loadSavedHosts(): List<TrustedHostProfile> {
        if (!hostsFile.exists()) return emptyList()
        return runCatching {
            storageJson.decodeFromString<List<TrustedHostProfile>>(hostsFile.readText())
        }.getOrDefault(emptyList())
    }

    private fun persistHosts(list: List<TrustedHostProfile>) {
        runCatching {
            hostsFile.writeText(storageJson.encodeToString(list))
            hostsFile.setReadable(false, false)
            hostsFile.setReadable(true, true)
            hostsFile.setWritable(false, false)
            hostsFile.setWritable(true, true)
        }
    }

    private fun loadUiPrefs(): ClientUiPrefs {
        if (!uiPrefsFile.exists()) return ClientUiPrefs()
        return runCatching {
            storageJson.decodeFromString<ClientUiPrefs>(uiPrefsFile.readText())
        }.getOrDefault(ClientUiPrefs())
    }

    private fun persistUiPrefs(prefs: ClientUiPrefs) {
        runCatching {
            uiPrefsFile.writeText(storageJson.encodeToString(prefs))
            uiPrefsFile.setReadable(false, false)
            uiPrefsFile.setReadable(true, true)
            uiPrefsFile.setWritable(false, false)
            uiPrefsFile.setWritable(true, true)
        }
    }

    override fun onCleared() {
        disconnectInternal(keepSheetClosed = true)
        super.onCleared()
    }
}
