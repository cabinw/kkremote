package com.kkremote.android.protocol

import kotlinx.serialization.Serializable

@Serializable
data class CoordWireMessage(
    val type: String,
    val role: String? = null,
    val hostID: String? = null,
    val clientID: String? = null,
    val targetHostID: String? = null,
    val name: String? = null,
    val signPub: String? = null,
    val kexPub: String? = null,
    val ts: Long? = null,
    val nonce: String? = null,
    val sig: String? = null,
    val stunServers: List<String>? = null,
    val hostOnline: Boolean? = null,
    val hostSignPub: String? = null,
    val hostKexPub: String? = null,
    val hostName: String? = null,
    val to: String? = null,
    val from: String? = null,
    val fromSignPub: String? = null,
    val fromKexPub: String? = null,
    val session: String? = null,
    val kind: String? = null,
    val e2eNonce: String? = null,
    val ciphertext: String? = null,
    val payloadSig: String? = null,
    val error: String? = null,
)

@Serializable
data class CoordConnectRequest(
    val protocolVersion: Int = 1,
    val session: String,
    val pairToken: String? = null,
    val accessGrant: String? = null,
    val userAgent: String? = null,
)

@Serializable
data class CoordRejectPayload(
    val error: String = "",
)

@Serializable
data class CoordOfferAnswerPayload(
    val session: String,
    val sdp: String,
    val dtlsFingerprint: String,
    val videoFormat: String? = null,
    val accessGrant: String? = null,
    val windowProtocol: Int? = null,
    val windowSession: String? = null,
    val windowLayout: Boolean? = null,
    val windowControl: Boolean? = null,
    val windowKeyboard: Boolean? = null,
)

@Serializable
data class CoordCandidatePayload(
    val session: String,
    val candidate: String,
    val mid: String? = null,
    val line: Int? = null,
)

@Serializable
data class RemoteWindow(
    val id: String,
    val number: Long,
    val processID: Int,
    val application: String,
    val title: String = "",
    val widthPoints: Double,
    val heightPoints: Double,
) {
    val displayLabel: String
        get() = if (title.isBlank()) application else "$application · $title"
}

@Serializable
data class WindowControlState(
    val focus: String? = null,
)

@Serializable
data class WindowInput(
    val lease: String,
    val sequence: Int,
    val kind: String,
    val x: Double? = null,
    val y: Double? = null,
    val dx: Double? = null,
    val dy: Double? = null,
    val text: String? = null,
    val focus: String? = null,
    val key: String? = null,
)

@Serializable
data class WindowViewport(
    val width: Double,
    val height: Double,
    val displayScale: Double? = null,
)

@Serializable
data class WindowMessage(
    val version: Int = 1,
    val action: String,
    val requestID: String,
    val windowID: String? = null,
    val windows: List<RemoteWindow>? = null,
    val selected: RemoteWindow? = null,
    val mediaSession: String? = null,
    val error: String? = null,
    val viewport: WindowViewport? = null,
    val controlLease: String? = null,
    val input: WindowInput? = null,
    val controlState: WindowControlState? = null,
    val appIcons: Map<String, String>? = null,
)

@Serializable
data class DataChannelSignalEnvelope(
    val type: String = "window",
    val session: String,
    val window: WindowMessage? = null,
)

@Serializable
data class TrustedHostProfile(
    val coordUrl: String,
    val hostId: String,
    val name: String,
    val signPub: String,
    val kexPub: String,
    val accessGrant: String? = null,
    val pendingPairToken: String? = null,
    val autoSelectApp: String? = null,
    val lastConnectedEpochMs: Long = 0L,
    val lastWindowTitle: String? = null,
) {
    val key: String get() = "${coordUrl.trimEnd('/')}|${hostId.lowercase()}"
}

data class StreamTelemetry(
    val width: Int = 0,
    val height: Int = 0,
    val fps: Double = 0.0,
    val framesDecoded: Long = 0L,
    val keyFramesDecoded: Long = 0L,
    val videoMbps: Double = 0.0,
    val rttMs: Double? = null,
    val packetsLost: Int = 0,
    val nackCount: Long = 0L,
    val pliCount: Long = 0L,
    val jitterMs: Double? = null,
    val decodeMs: Double? = null,
    val candidatePair: String = "—",
    val codec: String = "—",
    val decoderName: String = "—",
)
