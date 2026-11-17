package com.kkremote.android.network

import android.content.Context
import android.os.Build
import com.kkremote.android.crypto.DeviceIdentity
import com.kkremote.android.protocol.CoordCandidatePayload
import com.kkremote.android.protocol.CoordConnectRequest
import com.kkremote.android.protocol.CoordOfferAnswerPayload
import com.kkremote.android.protocol.CoordRejectPayload
import com.kkremote.android.protocol.CoordWireMessage
import com.kkremote.android.protocol.TrustedHostProfile
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import java.util.UUID
import java.util.concurrent.TimeUnit
import javax.crypto.spec.SecretKeySpec

class CoordSignalingClient(
    private val appContext: Context,
    private val identity: DeviceIdentity,
    initialHost: TrustedHostProfile,
    private val Listener: ListenerCallbacks,
) {
    interface ListenerCallbacks {
        fun onStatus(status: String)
        fun onHostPresence(online: Boolean, hostUpdated: TrustedHostProfile)
        fun onOfferReceived(sessionId: String, offer: CoordOfferAnswerPayload, stunServers: List<String>, hostUpdated: TrustedHostProfile)
        fun onRemoteCandidate(sessionId: String, candidate: CoordCandidatePayload)
        fun onRejected(reason: String, hostUpdated: TrustedHostProfile)
        fun onError(message: String)
    }

    @OptIn(kotlinx.serialization.ExperimentalSerializationApi::class)
    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
        explicitNulls = false
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val inboundQueue = Channel<String>(capacity = 256)
    private var pingJob: Job? = null
    private var reconnectJob: Job? = null
    private var webSocket: WebSocket? = null
    private var wsOpen = false

    @Volatile
    private var closed = false

    @Volatile
    private var host: TrustedHostProfile = initialHost

    @Volatile
    private var stunServers: List<String> = emptyList()

    @Volatile
    private var hostOnline: Boolean = false

    @Volatile
    private var sessionId: String = ""

    @Volatile
    private var sessionKey: SecretKeySpec? = null

    init {
        scope.launch {
            for (raw in inboundQueue) {
                if (closed) break
                runCatching { handleWireText(raw) }
                    .onFailure { err ->
                        if (!closed) Listener.onError("信令解析错误：${err.message ?: err.javaClass.simpleName}")
                    }
            }
        }
    }

    fun start() {
        if (closed) return
        reconnectJob?.cancel()
        val wsUrl = toWsEndpoint(host.coordUrl)
        Listener.onStatus("正在连接协调节点…")
        val req = Request.Builder().url(wsUrl).build()
        val http = PhysicalNetworkBinder.okHttpClient(appContext)
        val socket = http.newWebSocket(req, object : WebSocketListener() {
            override fun onOpen(ws: WebSocket, response: Response) {
                if (closed || ws !== webSocket) return
                wsOpen = true
                sendClientHello(ws)
                startHeartbeat(ws)
            }

            override fun onMessage(ws: WebSocket, text: String) {
                if (!closed && ws === webSocket) inboundQueue.trySend(text)
            }

            override fun onFailure(ws: WebSocket, t: Throwable, response: Response?) {
                if (closed || ws !== webSocket) return
                wsOpen = false
                Listener.onError("协调信令重连中：${t.message ?: "网络波动"}")
                scheduleSocketReconnect()
            }

            override fun onClosed(ws: WebSocket, code: Int, reason: String) {
                if (closed || ws !== webSocket) return
                wsOpen = false
                Listener.onStatus("协调信令已断开，正在重连…")
                scheduleSocketReconnect()
            }
        })
        webSocket = socket
    }

    private fun scheduleSocketReconnect() {
        reconnectJob?.cancel()
        reconnectJob = scope.launch {
            delay(1400L)
            if (!closed && !wsOpen) {
                runCatching { webSocket?.cancel() }
                start()
            }
        }
    }

    /** Triggers a fresh E2EE WebRTC session handshake over the existing WSS connection (or reconnects WSS if closed). */
    fun requestNewSession() {
        scope.launch {
            if (closed) return@launch
            if (!wsOpen || webSocket == null) {
                start()
            } else if (hostOnline) {
                beginSessionHandshake()
            } else {
                webSocket?.let { sendClientHello(it) }
            }
        }
    }

    fun sendAnswer(
        sessionId: String,
        sdp: String,
        dtlsFingerprint: String,
        videoFormat: String,
    ) {
        scope.launch {
            if (closed || sessionId != this@CoordSignalingClient.sessionId) return@launch
            val payload = CoordOfferAnswerPayload(
                session = sessionId,
                sdp = sdp,
                dtlsFingerprint = dtlsFingerprint,
                videoFormat = videoFormat,
            )
            sendEncrypted("answer", json.encodeToString(payload))
        }
    }

    fun sendCandidate(sessionId: String, candidate: String, sdpMid: String?, sdpMLineIndex: Int?) {
        scope.launch {
            if (closed || sessionId != this@CoordSignalingClient.sessionId) return@launch
            val payload = CoordCandidatePayload(
                session = sessionId,
                candidate = candidate,
                mid = sdpMid,
                line = sdpMLineIndex,
            )
            sendEncrypted("candidate", json.encodeToString(payload))
        }
    }

    fun close() {
        closed = true
        pingJob?.cancel()
        inboundQueue.close()
        runCatching { webSocket?.close(1000, "client closed") }
        webSocket = null
        scope.cancel()
    }

    private fun sendClientHello(ws: WebSocket) {
        val ts = System.currentTimeMillis() / 1000L
        val nonce = DeviceIdentity.randomHex(12)
        val signed = "kkremote-client-hello-v1|${identity.deviceId}|${host.hostId}|${identity.kexPubB64}|$ts|$nonce"
        val sig = identity.signP1363(signed)
        val hello = CoordWireMessage(
            type = "clientHello",
            clientID = identity.deviceId,
            targetHostID = host.hostId,
            name = "Android (${Build.MODEL})",
            signPub = identity.signPubB64,
            kexPub = identity.kexPubB64,
            ts = ts,
            nonce = nonce,
            sig = sig,
        )
        ws.send(json.encodeToString(hello))
    }

    private fun startHeartbeat(ws: WebSocket) {
        pingJob?.cancel()
        pingJob = scope.launch {
            while (isActive && !closed) {
                delay(25_000L)
                ws.send("""{"type":"ping"}""")
            }
        }
    }

    private fun handleWireText(raw: String) {
        val msg = json.decodeFromString<CoordWireMessage>(raw)
        when (msg.type) {
            "welcome" -> {
                stunServers = msg.stunServers.orEmpty()
                hostOnline = msg.hostOnline == true
                if (hostOnline) {
                    if (!msg.hostSignPub.isNullOrBlank() && msg.hostSignPub != host.signPub) {
                        Listener.onError("远端主机签名公钥与本地信任记录不一致，已拒绝连接")
                        close()
                        return
                    }
                    host = host.copy(
                        kexPub = msg.hostKexPub?.takeIf { it.isNotBlank() } ?: host.kexPub,
                        name = msg.hostName?.takeIf { it.isNotBlank() } ?: host.name,
                    )
                    Listener.onHostPresence(true, host)
                    beginSessionHandshake()
                } else {
                    Listener.onHostPresence(false, host)
                    Listener.onStatus("协调节点已连通 · 等待 ${host.name} 上线…")
                }
            }

            "hostPresence" -> {
                val nowOnline = msg.hostOnline == true
                val wasOnline = hostOnline
                hostOnline = nowOnline
                host = host.copy(
                    kexPub = msg.hostKexPub?.takeIf { it.isNotBlank() } ?: host.kexPub,
                    name = msg.hostName?.takeIf { it.isNotBlank() } ?: host.name,
                )
                Listener.onHostPresence(nowOnline, host)
                if (nowOnline && (!wasOnline || sessionId.isEmpty())) {
                    beginSessionHandshake()
                } else if (!nowOnline) {
                    Listener.onStatus("${host.name} 当前已离线")
                }
            }

            "relay" -> handleRelay(msg)

            "error" -> {
                Listener.onError("协调服务提示：${msg.error ?: "未知错误"}")
            }
        }
    }

    private fun beginSessionHandshake() {
        val sid = UUID.randomUUID().toString().lowercase()
        val derivedKey = identity.deriveSessionKey(host.kexPub, sid)
        sessionId = sid
        sessionKey = derivedKey
        Listener.onStatus("正在与 ${host.name} 进行端到端加密认证…")

        val req = CoordConnectRequest(
            protocolVersion = 1,
            session = sid,
            pairToken = host.pendingPairToken,
            accessGrant = host.accessGrant,
            userAgent = "KKRemote-Android/${Build.VERSION.SDK_INT} (${Build.MODEL})",
        )
        sendEncrypted("connectRequest", json.encodeToString(req))
    }

    private fun handleRelay(msg: CoordWireMessage) {
        val from = msg.from ?: return
        val fromSignPub = msg.fromSignPub ?: return
        val sid = msg.session ?: return
        val kind = msg.kind ?: return
        val nonce = msg.e2eNonce ?: return
        val ciphertext = msg.ciphertext ?: return
        val sig = msg.payloadSig ?: return

        if (from != host.hostId || sid != sessionId) return
        if (fromSignPub != host.signPub) {
            Listener.onError("主机签名公钥校验失败，已阻断会话")
            return
        }
        if (!msg.fromKexPub.isNullOrBlank() && msg.fromKexPub != host.kexPub) {
            host = host.copy(kexPub = msg.fromKexPub)
            sessionKey = identity.deriveSessionKey(host.kexPub, sid)
        }
        val key = sessionKey ?: return
        val cleartext = identity.openUtf8(
            sessionId = sid,
            fromPeerId = from,
            peerSignSpkiB64 = host.signPub,
            kind = kind,
            nonceB64 = nonce,
            ciphertextB64 = ciphertext,
            sigB64 = sig,
            key = key,
        )

        when (kind) {
            "reject" -> {
                val rej = json.decodeFromString<CoordRejectPayload>(cleartext)
                host = host.copy(pendingPairToken = null)
                Listener.onRejected(rej.error.ifBlank { "配对凭证无效或已过期" }, host)
            }

            "offer" -> {
                val offer = json.decodeFromString<CoordOfferAnswerPayload>(cleartext)
                val sdpFps = DeviceIdentity.extractDtlsFingerprints(offer.sdp)
                if (offer.dtlsFingerprint.isBlank() || !sdpFps.contains(offer.dtlsFingerprint.uppercase())) {
                    Listener.onError("SDP DTLS 指纹与端到端签名声明不匹配，拒绝连接")
                    return
                }
                if (!offer.accessGrant.isNullOrBlank()) {
                    host = host.copy(
                        accessGrant = offer.accessGrant,
                        pendingPairToken = null,
                        lastConnectedEpochMs = System.currentTimeMillis(),
                    )
                } else {
                    host = host.copy(lastConnectedEpochMs = System.currentTimeMillis())
                }
                Listener.onOfferReceived(sid, offer, stunServers, host)
            }

            "candidate" -> {
                val cand = json.decodeFromString<CoordCandidatePayload>(cleartext)
                if (cand.candidate.isNotBlank()) {
                    Listener.onRemoteCandidate(sid, cand)
                }
            }
        }
    }

    private fun sendEncrypted(kind: String, plaintextJson: String) {
        val ws = webSocket ?: return
        val sid = sessionId.takeIf { it.isNotEmpty() } ?: return
        val key = sessionKey ?: return
        val sealed = identity.sealUtf8(
            plaintextJson = plaintextJson,
            sessionId = sid,
            toPeerId = host.hostId,
            kind = kind,
            key = key,
        )
        val wire = CoordWireMessage(
            type = "relay",
            to = host.hostId,
            session = sid,
            kind = kind,
            e2eNonce = sealed.nonceB64,
            ciphertext = sealed.ciphertextB64,
            payloadSig = sealed.payloadSigB64,
        )
        ws.send(json.encodeToString(wire))
    }

    companion object {
        fun toWsEndpoint(coordBaseUrl: String): String {
            var raw = coordBaseUrl.trim().trimEnd('/')
            raw = when {
                raw.startsWith("https://", true) -> "wss://" + raw.substring("https://".length)
                raw.startsWith("http://", true) -> "ws://" + raw.substring("http://".length)
                else -> raw
            }
            return if (raw.endsWith("/v1/ws")) raw else "$raw/v1/ws"
        }
    }
}
