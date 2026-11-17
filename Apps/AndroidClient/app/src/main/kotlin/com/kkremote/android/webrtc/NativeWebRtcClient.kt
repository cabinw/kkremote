package com.kkremote.android.webrtc

import android.content.Context
import com.kkremote.android.crypto.DeviceIdentity
import com.kkremote.android.network.PhysicalNetworkBinder
import com.kkremote.android.protocol.CoordCandidatePayload
import com.kkremote.android.protocol.CoordOfferAnswerPayload
import com.kkremote.android.protocol.DataChannelSignalEnvelope
import com.kkremote.android.protocol.StreamTelemetry
import com.kkremote.android.protocol.WindowMessage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.webrtc.DataChannel
import org.webrtc.DefaultVideoDecoderFactory
import org.webrtc.DefaultVideoEncoderFactory
import org.webrtc.EglBase
import org.webrtc.IceCandidate
import org.webrtc.MediaConstraints
import org.webrtc.MediaStream
import org.webrtc.PeerConnection
import org.webrtc.PeerConnectionFactory
import org.webrtc.RTCStatsReport
import org.webrtc.RtpCapabilities
import org.webrtc.RtpReceiver
import org.webrtc.RtpTransceiver
import org.webrtc.SdpObserver
import org.webrtc.SessionDescription
import org.webrtc.VideoCodecInfo
import org.webrtc.VideoDecoder
import org.webrtc.VideoDecoderFactory
import org.webrtc.VideoTrack
import java.math.BigInteger
import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets

/**
 * org.webrtc's default Android MediaCodecVideoDecoderFactory hardcodes Level 3.1 (640c1f / 42e01f)
 * in getSupportedCodecs(), which causes macOS VideoToolbox to reject >720p Retina window frames.
 * This wrapper advertises Level 5.1 (640c33 / 640033 / 42e033) for SDP negotiation while delegating
 * actual Annex-B decoding to Qualcomm/MediaCodec hardware AVC/HEVC decoders.
 */
private class HighLevelVideoDecoderFactory(eglContext: EglBase.Context) : VideoDecoderFactory {
    private val delegate = DefaultVideoDecoderFactory(eglContext)

    override fun createDecoder(codecInfo: VideoCodecInfo): VideoDecoder? {
        delegate.createDecoder(codecInfo)?.let { return it }
        if (codecInfo.name.equals("H264", ignoreCase = true)) {
            val plid = codecInfo.params["profile-level-id"]?.lowercase().orEmpty()
            val mappedPlid = if (plid.startsWith("64")) "640c1f" else "42e01f"
            val mapped = VideoCodecInfo(
                "H264",
                mapOf(
                    "level-asymmetry-allowed" to "1",
                    "packetization-mode" to "1",
                    "profile-level-id" to mappedPlid,
                ),
                emptyList(),
            )
            return delegate.createDecoder(mapped)
                ?: delegate.createDecoder(
                    VideoCodecInfo(
                        "H264",
                        mapOf(
                            "level-asymmetry-allowed" to "1",
                            "packetization-mode" to "1",
                            "profile-level-id" to "42e01f",
                        ),
                        emptyList(),
                    )
                )
        }
        if (codecInfo.name.equals("H265", ignoreCase = true)) {
            return delegate.createDecoder(VideoCodecInfo("H265", emptyMap<String, String>(), emptyList()))
        }
        return null
    }

    override fun getSupportedCodecs(): Array<VideoCodecInfo> {
        val base = delegate.supportedCodecs.toList()
        val extra = ArrayList<VideoCodecInfo>()
        for (plid in listOf("640c33", "640033", "42e033")) {
            extra.add(
                VideoCodecInfo(
                    "H264",
                    mapOf(
                        "level-asymmetry-allowed" to "1",
                        "packetization-mode" to "1",
                        "profile-level-id" to plid,
                    ),
                    emptyList(),
                )
            )
        }
        if (base.any { it.name.equals("H265", ignoreCase = true) }) {
            extra.add(
                VideoCodecInfo(
                    "H265",
                    mapOf(
                        "profile-id" to "2",
                        "tier-flag" to "0",
                        "level-id" to "150",
                        "tx-mode" to "SRST",
                    ),
                    emptyList(),
                )
            )
        }
        return (extra + base).toTypedArray()
    }
}

object WebRtcRuntime {
    @Volatile
    private var initialized = false

    val eglBase: EglBase by lazy { EglBase.create() }

    private var factoryInstance: PeerConnectionFactory? = null

    @Synchronized
    fun factory(appContext: Context): PeerConnectionFactory {
        PhysicalNetworkBinder.ensureStarted(appContext)
        if (!initialized) {
            PeerConnectionFactory.initialize(
                PeerConnectionFactory.InitializationOptions.builder(appContext.applicationContext)
                    .setEnableInternalTracer(false)
                    .createInitializationOptions()
            )
            initialized = true
        }
        factoryInstance?.let { return it }
        val decoderFactory = HighLevelVideoDecoderFactory(eglBase.eglBaseContext)
        val encoderFactory = DefaultVideoEncoderFactory(eglBase.eglBaseContext, true, true)
        val options = PeerConnectionFactory.Options().apply {
            // Bypass Android VPN TUN interfaces (e.g. Tailscale / Surge / Clash exit nodes) so libwebrtc
            // binds UDP sockets directly to physical 5G / Wi-Fi networks via android_setsocknetwork.
            networkIgnoreMask = PeerConnectionFactory.Options.ADAPTER_TYPE_VPN
        }
        return PeerConnectionFactory.builder()
            .setOptions(options)
            .setVideoDecoderFactory(decoderFactory)
            .setVideoEncoderFactory(encoderFactory)
            .createPeerConnectionFactory()
            .also { factoryInstance = it }
    }
}

class NativeWebRtcClient(
    context: Context,
    val sessionId: String,
    val windowSession: String,
    stunServers: List<String>,
    private val preferHdr: Boolean,
    private val callbacks: Callbacks,
) {
    interface Callbacks {
        fun onLocalAnswer(sessionId: String, sdp: String, dtlsFingerprint: String, videoFormat: String)
        fun onLocalIceCandidate(sessionId: String, candidate: String, sdpMid: String?, sdpMLineIndex: Int)
        fun onIceConnectionState(sessionId: String, state: PeerConnection.IceConnectionState)
        fun onVideoTrack(sessionId: String, track: VideoTrack)
        fun onDataChannelOpen(sessionId: String)
        fun onDataChannelClosed(sessionId: String)
        fun onWindowMessage(sessionId: String, message: WindowMessage)
        fun onTelemetry(sessionId: String, telemetry: StreamTelemetry)
        fun onError(sessionId: String, message: String)
    }

    @OptIn(kotlinx.serialization.ExperimentalSerializationApi::class)
    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
        explicitNulls = false
    }

    private val factory = WebRtcRuntime.factory(context)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var peerConnection: PeerConnection? = null
    private var dataChannel: DataChannel? = null
    private var statsJob: Job? = null

    @Volatile
    private var closed = false

    @Volatile
    private var remoteDescriptionSet = false
    private val pendingCandidates = ArrayList<IceCandidate>()

    private var prevBytesReceived: Long = 0L
    private var prevStatsTimestampUs: Double = 0.0
    private var prevFramesDecoded: Long = 0L
    private var prevDecodeSec: Double = 0.0
    private var prevJitterDelaySec: Double = 0.0
    private var prevJitterEmitted: Long = 0L

    init {
        val iceList = if (stunServers.isNotEmpty()) {
            listOf(PeerConnection.IceServer.builder(stunServers).createIceServer())
        } else {
            emptyList()
        }
        val rtcConfig = PeerConnection.RTCConfiguration(iceList).apply {
            sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN
            bundlePolicy = PeerConnection.BundlePolicy.MAXBUNDLE
            rtcpMuxPolicy = PeerConnection.RtcpMuxPolicy.REQUIRE
            tcpCandidatePolicy = PeerConnection.TcpCandidatePolicy.DISABLED
            continualGatheringPolicy = PeerConnection.ContinualGatheringPolicy.GATHER_CONTINUALLY
        }

        peerConnection = factory.createPeerConnection(rtcConfig, object : PeerConnection.Observer {
            override fun onSignalingChange(newState: PeerConnection.SignalingState?) {}

            override fun onIceConnectionChange(newState: PeerConnection.IceConnectionState?) {
                if (closed || newState == null) return
                callbacks.onIceConnectionState(sessionId, newState)
                if (newState == PeerConnection.IceConnectionState.CONNECTED ||
                    newState == PeerConnection.IceConnectionState.COMPLETED
                ) {
                    startStatsLoop()
                }
            }

            override fun onIceConnectionReceivingChange(receiving: Boolean) {}
            override fun onIceGatheringChange(newState: PeerConnection.IceGatheringState?) {}

            override fun onIceCandidate(candidate: IceCandidate?) {
                if (closed || candidate == null) return
                if (PhysicalNetworkBinder.isVpnOrCgnatTunnelIp(candidate.sdp)) return
                callbacks.onLocalIceCandidate(sessionId, candidate.sdp, candidate.sdpMid, candidate.sdpMLineIndex)
            }

            override fun onIceCandidatesRemoved(candidates: Array<out IceCandidate>?) {}
            override fun onAddStream(stream: MediaStream?) {}
            override fun onRemoveStream(stream: MediaStream?) {}

            override fun onDataChannel(dc: DataChannel?) {
                if (closed || dc == null) return
                dataChannel = dc
                dc.registerObserver(object : DataChannel.Observer {
                    override fun onBufferedAmountChange(previousAmount: Long) {}

                    override fun onStateChange() {
                        if (closed) return
                        when (dc.state()) {
                            DataChannel.State.OPEN -> callbacks.onDataChannelOpen(sessionId)
                            DataChannel.State.CLOSING,
                            DataChannel.State.CLOSED -> callbacks.onDataChannelClosed(sessionId)
                            else -> Unit
                        }
                    }

                    override fun onMessage(buffer: DataChannel.Buffer?) {
                        if (closed || buffer == null) return
                        val bytes = ByteArray(buffer.data.remaining())
                        buffer.data.get(bytes)
                        val text = String(bytes, StandardCharsets.UTF_8)
                        if (text.startsWith("ping:")) {
                            if (dc.bufferedAmount() < 8192L) {
                                val pong = ("pong:" + text.substring(5)).toByteArray(StandardCharsets.UTF_8)
                                dc.send(DataChannel.Buffer(ByteBuffer.wrap(pong), false))
                            }
                            return
                        }
                        if (text.startsWith("{")) {
                            runCatching {
                                val env = json.decodeFromString<DataChannelSignalEnvelope>(text)
                                if (env.type == "window" && env.session == windowSession && env.window != null) {
                                    callbacks.onWindowMessage(sessionId, env.window)
                                }
                            }
                        }
                    }
                })
                if (dc.state() == DataChannel.State.OPEN) {
                    callbacks.onDataChannelOpen(sessionId)
                }
            }

            override fun onRenegotiationNeeded() {}

            override fun onAddTrack(receiver: RtpReceiver?, mediaStreams: Array<out MediaStream>?) {
                val track = receiver?.track() as? VideoTrack ?: return
                if (!closed) {
                    track.setEnabled(true)
                    callbacks.onVideoTrack(sessionId, track)
                }
            }

            override fun onTrack(transceiver: RtpTransceiver?) {
                val track = transceiver?.receiver?.track() as? VideoTrack ?: return
                if (!closed) {
                    track.setEnabled(true)
                    callbacks.onVideoTrack(sessionId, track)
                }
            }
        })
    }

    fun acceptOffer(offer: CoordOfferAnswerPayload) {
        val pc = peerConnection ?: return
        val remoteDesc = SessionDescription(SessionDescription.Type.OFFER, offer.sdp)
        pc.setRemoteDescription(object : SimpleSdpObserver() {
            override fun onSetSuccess() {
                if (closed) return
                val wantHevcHdr = preferHdr && offerContainsHevcMain10(offer.sdp)
                applyReceiverCodecPreferences(pc, wantHevcHdr)

                synchronized(pendingCandidates) {
                    remoteDescriptionSet = true
                    for (cand in pendingCandidates) {
                        pc.addIceCandidate(cand)
                    }
                    pendingCandidates.clear()
                }

                pc.createAnswer(object : SimpleSdpObserver() {
                    override fun onCreateSuccess(answerDesc: SessionDescription?) {
                        if (closed || answerDesc == null) return
                        pc.setLocalDescription(object : SimpleSdpObserver() {
                            override fun onSetSuccess() {
                                if (closed) return
                                val fps = DeviceIdentity.extractDtlsFingerprints(answerDesc.description)
                                val fp = fps.firstOrNull().orEmpty()
                                val negotiatedHevc = wantHevcHdr && answerPrefersHevc(answerDesc.description)
                                val videoFormat = if (negotiatedHevc) "hevc-main10-pq" else "h264-sdr"
                                callbacks.onLocalAnswer(sessionId, answerDesc.description, fp, videoFormat)
                            }

                            override fun onSetFailure(err: String?) {
                                if (!closed) callbacks.onError(sessionId, "设置本地 Answer 失败：$err")
                            }
                        }, answerDesc)
                    }

                    override fun onCreateFailure(err: String?) {
                        if (!closed) callbacks.onError(sessionId, "创建 SDP Answer 失败：$err")
                    }
                }, MediaConstraints())
            }

            override fun onSetFailure(err: String?) {
                if (!closed) callbacks.onError(sessionId, "解析远端 Offer 失败：$err")
            }
        }, remoteDesc)
    }

    fun addRemoteCandidate(payload: CoordCandidatePayload) {
        val pc = peerConnection ?: return
        val cand = IceCandidate(payload.mid ?: "0", payload.line ?: 0, payload.candidate)
        synchronized(pendingCandidates) {
            if (remoteDescriptionSet) {
                pc.addIceCandidate(cand)
            } else if (pendingCandidates.size < 128) {
                pendingCandidates.add(cand)
            }
        }
    }

    fun sendWindowCommand(message: WindowMessage): Boolean {
        val dc = dataChannel ?: return false
        if (closed || dc.state() != DataChannel.State.OPEN || dc.bufferedAmount() > 262_144L) return false
        val envelope = DataChannelSignalEnvelope(
            type = "window",
            session = windowSession,
            window = message,
        )
        val bytes = json.encodeToString(envelope).toByteArray(StandardCharsets.UTF_8)
        if (bytes.size > 65_536) return false
        return dc.send(DataChannel.Buffer(ByteBuffer.wrap(bytes), false))
    }

    fun close() {
        if (closed) return
        closed = true
        statsJob?.cancel()
        scope.cancel()
        runCatching { dataChannel?.close() }
        dataChannel = null
        runCatching { peerConnection?.close() }
        runCatching { peerConnection?.dispose() }
        peerConnection = null
    }

    private fun applyReceiverCodecPreferences(pc: PeerConnection, preferHevcMain10: Boolean) {
        runCatching {
            val caps = factory.getRtpReceiverCapabilities(org.webrtc.MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO)
            val available = caps.codecs ?: return
            val ranked = available
                .filter { codec ->
                    val name = codec.name.ifBlank { codec.mimeType.substringAfter('/') }.lowercase()
                    name == "h264" || (preferHevcMain10 && name == "h265") ||
                        name == "rtx" || name == "red" || name == "ulpfec"
                }
                .sortedBy { codec -> rankCodec(codec, preferHevcMain10) }

            if (ranked.isNotEmpty()) {
                for (transceiver in pc.transceivers) {
                    if (transceiver.mediaType == org.webrtc.MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO) {
                        runCatching { transceiver.setCodecPreferences(ranked) }
                    }
                }
            }
        }
    }

    private fun rankCodec(codec: RtpCapabilities.CodecCapability, preferHevcMain10: Boolean): Int {
        val name = codec.name.ifBlank { codec.mimeType.substringAfter('/') }.lowercase()
        val params = codec.parameters.entries.joinToString(";") { "${it.key}=${it.value}" }.lowercase()
        if (preferHevcMain10 && name == "h265") {
            return if (params.contains("profile-id=2")) 0 else 1
        }
        if (name == "h264") {
            val pktMode1 = !params.contains("packetization-mode=0")
            val base = if (pktMode1) 0 else 10
            return base + when {
                params.contains("640c") || params.contains("6400") -> 2
                params.contains("4d") -> 3
                params.contains("42") -> 4
                else -> 5
            }
        }
        return 20
    }

    private fun offerContainsHevcMain10(sdp: String): Boolean =
        sdp.contains("H265/90000", ignoreCase = true) && sdp.contains("profile-id=2", ignoreCase = true)

    private fun answerPrefersHevc(sdp: String): Boolean {
        val lines = sdp.lines().map { it.trim() }
        val mVideo = lines.firstOrNull { it.startsWith("m=video ") } ?: return false
        val primaryPt = mVideo.split(' ').getOrNull(3) ?: return false
        return lines.any { it.equals("a=rtpmap:$primaryPt H265/90000", ignoreCase = true) }
    }

    private fun startStatsLoop() {
        if (statsJob != null) return
        statsJob = scope.launch {
            while (isActive && !closed) {
                delay(1000L)
                val pc = peerConnection ?: break
                pc.getStats { report ->
                    if (!closed) consumeStats(report)
                }
            }
        }
    }

    private fun consumeStats(report: RTCStatsReport) {
        val statsMap = report.statsMap
        val localTypes = HashMap<String, String>()
        val remoteTypes = HashMap<String, String>()
        val codecNames = HashMap<String, String>()

        for ((id, st) in statsMap) {
            when (st.type) {
                "local-candidate" -> {
                    val ct = st.members["candidateType"]?.toString() ?: "local"
                    val proto = st.members["protocol"]?.toString() ?: "udp"
                    localTypes[id] = "$ct/$proto"
                }

                "remote-candidate" -> {
                    val ct = st.members["candidateType"]?.toString() ?: "remote"
                    val proto = st.members["protocol"]?.toString() ?: "udp"
                    remoteTypes[id] = "$ct/$proto"
                }

                "codec" -> {
                    val mime = st.members["mimeType"]?.toString()?.substringAfter('/') ?: ""
                    val fmtp = st.members["sdpFmtpLine"]?.toString().orEmpty()
                    val profile = Regex("profile-level-id=([0-9a-fA-F]+)").find(fmtp)?.groupValues?.getOrNull(1)
                        ?: Regex("profile-id=([0-9]+)").find(fmtp)?.groupValues?.getOrNull(1)?.let { "Main10($it)" }
                    codecNames[id] = if (profile != null) "$mime ($profile)" else mime
                }
            }
        }

        var rttMs: Double? = null
        var candidatePairLabel = "—"
        for ((_, st) in statsMap) {
            if (st.type == "candidate-pair") {
                val state = st.members["state"]?.toString()
                val nominated = st.members["nominated"] == true
                if (state == "succeeded" && (nominated || rttMs == null)) {
                    rttMs = st.members["currentRoundTripTime"].asDouble()?.times(1000.0)
                    val lId = st.members["localCandidateId"]?.toString()
                    val rId = st.members["remoteCandidateId"]?.toString()
                    candidatePairLabel = "${localTypes[lId] ?: "local"} → ${remoteTypes[rId] ?: "remote"}"
                }
            }
        }

        for ((_, st) in statsMap) {
            if (st.type == "inbound-rtp" && st.members["kind"] == "video") {
                val width = st.members["frameWidth"].asLong()?.toInt() ?: 0
                val height = st.members["frameHeight"].asLong()?.toInt() ?: 0
                val fps = st.members["framesPerSecond"].asDouble() ?: 0.0
                val framesDecoded = st.members["framesDecoded"].asLong() ?: 0L
                val keyFrames = st.members["keyFramesDecoded"].asLong() ?: 0L
                val bytesRecv = st.members["bytesReceived"].asLong() ?: 0L
                val packetsLost = st.members["packetsLost"].asLong()?.toInt() ?: 0
                val nackCount = st.members["nackCount"].asLong() ?: 0L
                val pliCount = st.members["pliCount"].asLong() ?: 0L
                val totalDecodeTime = st.members["totalDecodeTime"].asDouble() ?: 0.0
                val jitterDelay = st.members["jitterBufferDelay"].asDouble() ?: 0.0
                val jitterEmitted = st.members["jitterBufferEmittedCount"].asLong() ?: 0L
                val decoderImpl = st.members["decoderImplementation"]?.toString() ?: "Hardware MediaCodec"
                val codecId = st.members["codecId"]?.toString()
                val codecLabel = codecNames[codecId] ?: "H264"

                val nowUs = st.timestampUs
                var mbps = 0.0
                if (prevStatsTimestampUs > 0.0 && nowUs > prevStatsTimestampUs && bytesRecv >= prevBytesReceived) {
                    val deltaSec = (nowUs - prevStatsTimestampUs) / 1_000_000.0
                    mbps = ((bytesRecv - prevBytesReceived) * 8.0) / (deltaSec * 1_000_000.0)
                }
                prevStatsTimestampUs = nowUs
                prevBytesReceived = bytesRecv

                val deltaFrames = framesDecoded - prevFramesDecoded
                val decodeMs = if (deltaFrames > 0 && totalDecodeTime >= prevDecodeSec) {
                    ((totalDecodeTime - prevDecodeSec) / deltaFrames) * 1000.0
                } else null
                prevFramesDecoded = framesDecoded
                prevDecodeSec = totalDecodeTime

                val deltaJitterCount = jitterEmitted - prevJitterEmitted
                val jitterMs = if (deltaJitterCount > 0 && jitterDelay >= prevJitterDelaySec) {
                    ((jitterDelay - prevJitterDelaySec) / deltaJitterCount) * 1000.0
                } else null
                prevJitterEmitted = jitterEmitted
                prevJitterDelaySec = jitterDelay

                callbacks.onTelemetry(
                    sessionId,
                    StreamTelemetry(
                        width = width,
                        height = height,
                        fps = fps,
                        framesDecoded = framesDecoded,
                        keyFramesDecoded = keyFrames,
                        videoMbps = mbps,
                        rttMs = rttMs,
                        packetsLost = packetsLost,
                        nackCount = nackCount,
                        pliCount = pliCount,
                        jitterMs = jitterMs,
                        decodeMs = decodeMs,
                        candidatePair = candidatePairLabel,
                        codec = codecLabel,
                        decoderName = decoderImpl,
                    )
                )
                break
            }
        }
    }

    private fun Any?.asLong(): Long? = when (this) {
        is Number -> this.toLong()
        is BigInteger -> this.toLong()
        is String -> this.toLongOrNull()
        else -> null
    }

    private fun Any?.asDouble(): Double? = when (this) {
        is Number -> this.toDouble()
        is String -> this.toDoubleOrNull()
        else -> null
    }
}

private open class SimpleSdpObserver : SdpObserver {
    override fun onCreateSuccess(desc: SessionDescription?) {}
    override fun onSetSuccess() {}
    override fun onCreateFailure(err: String?) {}
    override fun onSetFailure(err: String?) {}
}
