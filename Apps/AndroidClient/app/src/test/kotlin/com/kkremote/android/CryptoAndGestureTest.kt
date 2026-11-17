package com.kkremote.android

import com.kkremote.android.crypto.DeviceIdentity
import com.kkremote.android.crypto.PairingLinkParser
import com.kkremote.android.gesture.GestureAction
import com.kkremote.android.gesture.InteractionGestureMachine
import com.kkremote.android.gesture.TouchContact
import com.kkremote.android.gesture.TouchPoint
import com.kkremote.android.protocol.CoordConnectRequest
import com.kkremote.android.protocol.DataChannelSignalEnvelope
import com.kkremote.android.protocol.WindowMessage
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
                window = WindowMessage(action = "list", requestID = "r1"),
            )
        )
        assertTrue(dcJson.contains("\"type\":\"window\""))
        assertTrue(dcJson.contains("\"version\":1"))
        assertFalse(dcJson.contains("\"windows\""))
    }
}
