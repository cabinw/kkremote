import Foundation
import CryptoKit

@main
struct DeviceIdentityTests {
    static func main() throws {
        let host = DeviceIdentity()
        let viewer = DeviceIdentity()
        assert(host.deviceID.count == 32, "Expected 32-hex deviceID")
        assert(host.deviceID != viewer.deviceID, "Distinct identities required")

        // 1. Pairing token verification & rotation
        let initialToken = host.currentPairToken
        assert(host.verifyPairToken(initialToken), "Active pair token must verify")
        assert(!host.verifyPairToken("wrong-token"), "Wrong pair token must fail")
        let rotated = host.rotatePairToken()
        assert(!host.verifyPairToken(initialToken), "Old token must fail after rotation")
        assert(host.verifyPairToken(rotated), "Rotated token must verify")

        // 2. Pairing URL keeps all material inside #fragment, never query string
        let url = host.makePairingURL(coordBaseURL: "https://coord.example.test", hostName: "Demo Mac")
        assert(url.hasPrefix("https://coord.example.test/#"), "Pairing material must stay in URL fragment")
        assert(!url.contains("?"), "Pairing URL must not put secrets in query string")

        // 3. AccessGrant binds hostID + clientID + expiration
        let grant = try host.issueAccessGrant(forClientID: viewer.deviceID, ttlSeconds: 600)
        assert(host.verifyAccessGrant(grant, expectedClientID: viewer.deviceID), "Valid grant must pass")
        assert(!host.verifyAccessGrant(grant, expectedClientID: host.deviceID), "Grant bound to different clientID must fail")
        let expiredGrant = try host.issueAccessGrant(forClientID: viewer.deviceID, ttlSeconds: -5)
        assert(!host.verifyAccessGrant(expiredGrant, expectedClientID: viewer.deviceID), "Expired grant must fail")

        // 4. End-to-end ECDH + HKDF + AES-GCM + ECDSA P1363 roundtrip & tamper rejection
        let sessionID = "sess-unit-test-0001"
        let viewerKey = try viewer.deriveSessionKey(peerKexSPKIB64: host.kexPubB64, sessionID: sessionID)
        let hostKey = try host.deriveSessionKey(peerKexSPKIB64: viewer.kexPubB64, sessionID: sessionID)

        let req = CoordConnectRequest(protocolVersion: 1, session: sessionID, pairToken: rotated, accessGrant: nil, userAgent: "UnitTest")
        let sealed = try viewer.sealJSON(req, sessionID: sessionID, to: host.deviceID, kind: "connectRequest", key: viewerKey)

        let opened = try host.openJSON(
            CoordConnectRequest.self,
            sessionID: sessionID,
            from: viewer.deviceID,
            peerSignSPKIB64: viewer.signPubB64,
            kind: "connectRequest",
            nonceB64: sealed.nonceB64,
            ciphertextB64: sealed.ciphertextB64,
            sigB64: sealed.sigB64,
            key: hostKey
        )
        assert(opened.session == sessionID && opened.pairToken == rotated, "Decrypted payload mismatch")

        // Reject wrong session AAD / signature
        var rejectedWrongSession = false
        do {
            _ = try host.openJSON(
                CoordConnectRequest.self,
                sessionID: "sess-tampered",
                from: viewer.deviceID,
                peerSignSPKIB64: viewer.signPubB64,
                kind: "connectRequest",
                nonceB64: sealed.nonceB64,
                ciphertextB64: sealed.ciphertextB64,
                sigB64: sealed.sigB64,
                key: hostKey
            )
        } catch {
            rejectedWrongSession = true
        }
        assert(rejectedWrongSession, "Cross-session replay must be rejected")

        print("DEVICE_IDENTITY_TESTS_PASSED")
    }
}
