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

    static func runPair(wrongKey: Bool) throws {
        let server = SignalTransport(), client = SignalTransport()
        defer { server.stop(); client.stop() }
        let key = try SignalTransport.newPairingKey()
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
        try runPair(wrongKey: false)
        try runPair(wrongKey: true)
        print("SIGNAL_TESTS_PASSED")
    }
}
