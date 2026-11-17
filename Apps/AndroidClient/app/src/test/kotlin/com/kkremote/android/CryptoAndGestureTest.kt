package com.kkremote.android

import com.kkremote.android.crypto.DeviceIdentity
import com.kkremote.android.crypto.PairingLinkParser
import com.kkremote.android.gesture.GestureAction
import com.kkremote.android.gesture.InteractionGestureMachine
import com.kkremote.android.gesture.TouchContact
import com.kkremote.android.gesture.TouchPoint
import com.kkremote.android.network.PhysicalNetworkBinder
import com.kkremote.android.protocol.CoordConnectRequest
import com.kkremote.android.protocol.DataChannelSignalEnvelope
import com.kkremote.android.protocol.RemoteWindow
import com.kkremote.android.protocol.WindowInput
import com.kkremote.android.protocol.WindowMessage
import com.kkremote.android.protocol.WindowViewport
import com.kkremote.android.ui.WindowEdgeColorEstimator
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.net.URLEncoder

class CryptoAndGestureTest {

    @Test
    fun deviceIdentityPersistenceEcdhE2eeAndSpoofRejection() {
        val dir = Files.createTempDirectory("kkremote-id-test").toFile()
        try {
            val idFile = File(dir, "client-id.json")
            val client = DeviceIdentity.loadOrCreate(idFile)
            val reloaded = DeviceIdentity.loadOrCreate(idFile)
            assertEquals(client.deviceId, reloaded.deviceId)
            assertEquals(32, client.deviceId.length)
            assertEquals(client.signPubB64, reloaded.signPubB64)
            assertEquals(client.kexPubB64, reloaded.kexPubB64)

            val host = DeviceIdentity.generate()
            val intruder = DeviceIdentity.generate()
            val sessionId = "6e30f9dc-1111-4444-8888-abcdef012345"

            val clientKey = client.deriveSessionKey(host.kexPubB64, sessionId)
            val hostKey = host.deriveSessionKey(client.kexPubB64, sessionId)

            val payload = """{"protocolVersion":1,"session":"$sessionId"}"""
            val sealed = client.sealUtf8(
                plaintextJson = payload,
                sessionId = sessionId,
                toPeerId = host.deviceId,
                kind = "connectRequest",
                key = clientKey,
            )

            val opened = host.openUtf8(
                sessionId = sessionId,
                fromPeerId = client.deviceId,
                peerSignSpkiB64 = client.signPubB64,
                kind = "connectRequest",
                nonceB64 = sealed.nonceB64,
                ciphertextB64 = sealed.ciphertextB64,
                sigB64 = sealed.payloadSigB64,
                key = hostKey,
            )
            assertEquals(payload, opened)

            // Reject forged sender key
            val spoofAttempt = runCatching {
                host.openUtf8(
                    sessionId = sessionId,
                    fromPeerId = client.deviceId,
                    peerSignSpkiB64 = intruder.signPubB64,
                    kind = "connectRequest",
                    nonceB64 = sealed.nonceB64,
                    ciphertextB64 = sealed.ciphertextB64,
                    sigB64 = sealed.payloadSigB64,
                    key = hostKey,
                )
            }
            assertTrue(spoofAttempt.isFailure)
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun pairingLinkParserHandlesHttpsFragmentAndCustomScheme() {
        val host = DeviceIdentity.generate()
        val pubEnc = URLEncoder.encode(host.signPubB64, "UTF-8")
        val kexEnc = URLEncoder.encode(host.kexPubB64, "UTF-8")
        val httpsUrl = "https://coord.example.com/#host=${host.deviceId}&pub=$pubEnc&kex=$kexEnc&pair=tok123&name=My+Mac"
        val parsed = PairingLinkParser.parse(httpsUrl)
        assertNotNull(parsed)
        assertEquals("https://coord.example.com", parsed!!.coordUrl)
        assertEquals(host.deviceId, parsed.hostId)
        assertEquals(host.signPubB64, parsed.signPub)
        assertEquals(host.kexPubB64, parsed.kexPub)
        assertEquals("tok123", parsed.pendingPairToken)
        assertEquals("My Mac", parsed.name)

        val customScheme = "kkremote://pair?coord=https%3A%2F%2Fcoord.example.com#host=${host.deviceId}&pub=$pubEnc&kex=$kexEnc"
        val parsedCustom = PairingLinkParser.parse(customScheme)
        assertNotNull(parsedCustom)
        assertEquals("https://coord.example.com", parsedCustom!!.coordUrl)

        assertNull(PairingLinkParser.parse("https://coord.example.com/#host=invalid"))
    }

    @Test
    fun gestureMachineLocksPinchWithoutLeakingRemoteScroll() {
        val machine = InteractionGestureMachine(directScroll = true, relativeTrackpad = false)

        // Tap -> Click
        assertTrue(machine.update(listOf(TouchContact(0, TouchPoint(100f, 200f))), 1.0).isEmpty())
        val tapActions = machine.update(emptyList(), 1.12)
        assertEquals(listOf(GestureAction.Tap(TouchPoint(100f, 200f))), tapActions)

        // Long press -> SecondaryClick
        machine.update(listOf(TouchContact(0, TouchPoint(100f, 200f))), 2.0)
        val rightClick = machine.update(emptyList(), 2.50)
        assertEquals(listOf(GestureAction.SecondaryClick(TouchPoint(100f, 200f))), rightClick)

        // Pinch -> Zoom + Pan only, never Scroll
        machine.update(
            listOf(TouchContact(0, TouchPoint(100f, 100f)), TouchContact(1, TouchPoint(200f, 100f))),
            3.0,
        )
        val zoomStep = machine.update(
            listOf(TouchContact(0, TouchPoint(80f, 100f)), TouchContact(1, TouchPoint(240f, 100f))),
            3.05,
        )
        assertTrue(zoomStep.any { it is GestureAction.Zoom })
        assertFalse(zoomStep.any { it is GestureAction.Scroll || it is GestureAction.ScrollBegan })
        val endZoom = machine.update(emptyList(), 3.2)
        assertTrue(endZoom.isEmpty())
    }

    @OptIn(ExperimentalSerializationApi::class)
    @Test
    fun wireJsonEncodesRequiredDefaultProtocolFieldsWhileOmittingNulls() {
        val wireJson = Json {
            ignoreUnknownKeys = true
            encodeDefaults = true
            explicitNulls = false
        }
        val reqJson = wireJson.encodeToString(CoordConnectRequest(session = "s1", pairToken = "p1"))
        assertTrue(reqJson.contains("\"protocolVersion\":1"))
        assertFalse(reqJson.contains("accessGrant"))

        val dcJson = wireJson.encodeToString(
            DataChannelSignalEnvelope(
                session = "ws1",
                window = WindowMessage(
                    action = "resize",
                    requestID = "r1",
                    windowID = "w1",
                    viewport = WindowViewport(width = 902.0, height = 766.0, displayScale = 2.75),
                ),
            )
        )
        assertTrue(dcJson.contains("\"type\":\"window\""))
        assertTrue(dcJson.contains("\"version\":1"))
        assertTrue(dcJson.contains("\"width\":902.0"))
        assertTrue(dcJson.contains("\"height\":766.0"))
        assertFalse(dcJson.contains("\"windows\""))
    }

    @Test
    fun windowEdgeColorEstimatorRejectsOutliersAndDetectsLuminance() {
        val estimator = WindowEdgeColorEstimator()
        val lightTitlebar = IntArray(40) { idx ->
            if (idx < 4) (0xFF shl 24) or (0xFF shl 16) or (0x5F shl 8) or 0x57 // red traffic-light outlier
            else (0xFF shl 24) or (0xF2 shl 16) or (0xF3 shl 8) or 0xF7
        }
        val sampledLight = estimator.consumeArgbPixels(lightTitlebar)
        assertNotNull(sampledLight)
        assertFalse(sampledLight!!.prefersLightContent)

        val darkTitlebar = IntArray(40) { (0xFF shl 24) or (0x18 shl 16) or (0x1A shl 8) or 0x22 }
        // First frame arms pending debounce, second frame confirms transition
        assertNull(estimator.consumeArgbPixels(darkTitlebar))
        val sampledDark = estimator.consumeArgbPixels(darkTitlebar)
        assertNotNull(sampledDark)
        assertTrue(sampledDark!!.prefersLightContent)
    }

    @Test
    fun vpnAndCgnatCandidateFilterRejectsTunnelIpsAndKeepsPhysicalIps() {
        assertTrue(PhysicalNetworkBinder.isVpnOrCgnatTunnelIp("candidate:1 1 udp 2122260223 100.64.0.42 51234 typ host"))
        assertTrue(PhysicalNetworkBinder.isVpnOrCgnatTunnelIp("candidate:2 1 udp 2122260223 198.18.0.1 45000 typ host"))
        assertTrue(PhysicalNetworkBinder.isVpnOrCgnatTunnelIp("172.19.0.1"))
        assertFalse(PhysicalNetworkBinder.isVpnOrCgnatTunnelIp("candidate:3 1 udp 2122260223 192.168.1.25 52000 typ host"))
        assertFalse(PhysicalNetworkBinder.isVpnOrCgnatTunnelIp("candidate:4 1 udp 1686052607 203.0.113.12 39001 typ srflx"))
    }

    @OptIn(ExperimentalSerializationApi::class)
    @Test
    fun omniDesktopDisplayAndRawKeyWireModelsSerializeCleanly() {
        val json = Json { encodeDefaults = true; explicitNulls = false; ignoreUnknownKeys = true }
        val disp = RemoteWindow(
            id = RemoteWindow.MAIN_DISPLAY_HANDLE,
            number = 1L,
            processID = 0,
            application = "macOS 桌面",
            title = "1728×1117",
            widthPoints = 1728.0,
            heightPoints = 1117.0,
        )
        assertTrue(disp.isFullDisplay)

        val rawChordMsg = WindowMessage(
            action = "input",
            requestID = "req1",
            windowID = disp.id,
            mediaSession = "sess1",
            input = WindowInput(
                lease = "lease1",
                sequence = 1,
                kind = "rawKey",
                keyCode = 8,
                modifiers = listOf("cmd", "shift"),
            ),
        )
        val encoded = json.encodeToString(rawChordMsg)
        assertTrue(encoded.contains("\"kind\":\"rawKey\""))
        assertTrue(encoded.contains("\"keyCode\":8"))
        assertTrue(encoded.contains("\"modifiers\":[\"cmd\",\"shift\"]"))
        val decoded = json.decodeFromString<WindowMessage>(encoded)
        assertEquals(8, decoded.input?.keyCode)
        assertEquals(listOf("cmd", "shift"), decoded.input?.modifiers)
    }
}
