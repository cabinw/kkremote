import Foundation

@main
enum SignalTransportTests {
    static func require(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else { print("FAIL: \(label)"); exit(1) }
    }

    static func wait(seconds: TimeInterval = 8, until condition: () -> Bool) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !condition() && ProcessInfo.processInfo.systemUptime < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    static func runPair(wrongKey: Bool, shortCode: Bool = false) throws {
        let server = SignalTransport(), client = SignalTransport()
        defer { server.stop(); client.stop() }
        let key = try shortCode ? "482691" : SignalTransport.newPairingKey()
        let port = UInt16.random(in: 49000...59000)
        var listening = false, ready = false, failed = false
        var received: [SignalMessage] = []
        server.onStatus = { if $0.hasPrefix("等待连接") { listening = true } }
        server.onFailure = { _ in failed = true }
        client.onFailure = { _ in failed = true }
        client.onReady = { ready = true }
        server.onMessage = { received.append($0) }
        try server.listen(key: key, port: port)
        require(wait { listening || failed } && listening && !failed, "listener starts")
        try client.connect(host: "127.0.0.1", key: wrongKey ? SignalTransport.newPairingKey() : key, port: port)
        if wrongKey {
            require(wait { ready || failed } && failed && !ready, "wrong key never authenticates")
            require(received.isEmpty, "wrong key delivers no messages")
            print("PASS: wrong pairing key rejected")
            return
        }
        require(wait { ready || failed } && ready && !failed, "matching key authenticates")
        // Larger than a receive chunk, with UTF-8 and newlines; followed immediately by another frame.
        let payload = String(repeating: "窗口测试\n", count: 6000)
        client.send(SignalMessage(type: "offer", session: "test", sdp: payload))
        client.send(SignalMessage(type: "candidate", session: "test", candidate: "second-frame"))
        require(wait { received.count == 2 || failed } && !failed && received.count == 2, "framing survives chunk boundaries")
        require(received[0].sdp == payload && received[1].candidate == "second-frame", "payloads remain intact and ordered")
        client.send(SignalMessage(type: "offer", session: "test", sdp: String(repeating: "x", count: SignalTransport.maximumMessage + 1)))
        require(wait { failed }, "oversized message rejected")
        require(received.count == 2, "oversized message not delivered")
        print("PASS: TLS pairing, fragmented framing, message size bound")
    }

    static func main() throws {
        // Build 5's synthesized Codable ignores the added optional property.
        struct LegacyMessage: Decodable { let type: String; let session: String; let sdp: String? }
        let hdrOffer = SignalMessage(type: "offer", session: "hdr-test", sdp: "sdp", videoFormat: "hevc-main10-pq")
        let legacy = try JSONDecoder().decode(LegacyMessage.self, from: JSONEncoder().encode(hdrOffer))
        require(legacy.type == "offer" && legacy.sdp == "sdp", "legacy receiver ignores optional HDR field")
        let oldAnswer = try JSONDecoder().decode(SignalMessage.self, from: Data(#"{"type":"answer","session":"old","sdp":"h264"}"#.utf8))
        require(oldAnswer.videoFormat == nil, "old answer has no HDR capability")
        print("PASS: optional HDR signaling is backward compatible")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("pairing.key").path
        let key = try LabHostKey.loadOrCreate(at: path, reuseExisting: true)
        let reused = try LabHostKey.loadOrCreate(at: path, reuseExisting: true)
        require(key == reused && Data(base64Encoded: key)?.count == 32, "persistent host reuses key")
        func rejects(_ path: String, reuse: Bool = true) -> Bool {
            do { _ = try LabHostKey.loadOrCreate(at: path, reuseExisting: reuse); return false }
            catch { return true }
        }
        require(rejects(path, reuse: false), "ephemeral host refuses existing file")
        let link = directory.appendingPathComponent("link.key").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: path)
        require(rejects(link), "persistent host rejects symlink")
        chmod(path, 0o644)
        require(rejects(path), "persistent host rejects shared-readable key")
        chmod(path, 0o600)
        try Data("invalid-key".utf8).write(to: URL(fileURLWithPath: path))
        require(rejects(path), "persistent host rejects invalid key")
        print("PASS: persistent key reuse, exclusive creation, private file checks")
        try runPair(wrongKey: false)
        try runPair(wrongKey: false, shortCode: true)
        try runPair(wrongKey: true)
        print("SIGNAL_TESTS_PASSED")
    }
}
