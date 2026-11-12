import Foundation

@main
enum MediaDatagramTests {
    static func main() throws {
        let key = Data(repeating: 42, count: 32)
        func host(_ session: String = "test") throws -> MediaDatagramCodec { try MediaDatagramCodec(secret: key, session: session, isHost: true) }
        func viewer() throws -> MediaDatagramCodec { try MediaDatagramCodec(secret: key, session: "test", isHost: false) }
        var sender = try host(), receiver = try viewer()
        for size in [1, 8, 1168, 1169, 1199, 1200, 1201, 1248, 1249, 4096, 16384] {
            let payload = Data((0..<size).map { UInt8($0 % 251) })
            let frames = sender.seal(payload)
            precondition(frames.allSatisfy { $0.count <= 1280 })
            var result: Data?
            for frame in frames.reversed() { if let packet = receiver.open(frame, now: 0) { result = packet.payload } }
            precondition(result == payload, "Reordering/reassembly failed at \(size)")
            for frame in frames { precondition(receiver.open(frame, now: 0) == nil, "Replay accepted") }
        }
        precondition(sender.seal(Data()).isEmpty && sender.seal(Data(count: 16385)).isEmpty)
        precondition(sender.seal(Data(count: 1200)).count == 1, "v2 must avoid fragmentation at WebRTC's 1200-byte packet size")
        precondition(sender.seal(Data(count: 1248)).count == 1 && sender.seal(Data(count: 1249)).count == 2)
        // Explicit v1 compatibility and cross-version rejection; never silently downgrade.
        var legacyHost = try MediaDatagramCodec(secret: key, session: "test", isHost: true, version: .v1)
        var legacyViewer = try MediaDatagramCodec(secret: key, session: "test", isHost: false, version: .v1)
        let legacyPayload = Data(repeating: 13, count: 1200), legacyFrames = legacyHost.seal(Data(repeating: 13, count: 1200))
        precondition(legacyFrames.count == 2)
        precondition(legacyViewer.open(legacyFrames[1], now: 0) == nil)
        precondition(legacyViewer.open(legacyFrames[0], now: 0)?.payload == legacyPayload)
        precondition(receiver.open(legacyFrames[0], now: 0) == nil)
        precondition(legacyViewer.open(sender.seal(Data(count: 1200))[0], now: 0) == nil)
        precondition(sender.seal(Data(count: 9), kind: .probe).isEmpty)
        let fullProbe = sender.seal(Data(repeating: 27, count: sender.probeBytes), kind: .probe)
        precondition(fullProbe.count == 1 && fullProbe[0].count == 1280)
        precondition(receiver.open(fullProbe[0], now: 0)?.payload.count == 1248)
        let probe = sender.seal(Data(count: 8), kind: .probe)[0]
        precondition(receiver.open(probe, now: 0)?.kind == .probe)
        precondition(sender.open(probe, now: 0) == nil, "Reflected packet accepted")
        var wrongKey = try MediaDatagramCodec(secret: Data(repeating: 41, count: 32), session: "test", isHost: false)
        precondition(wrongKey.open(probe, now: 0) == nil)
        var wrongSession = try MediaDatagramCodec(secret: key, session: "other", isHost: false)
        precondition(wrongSession.open(probe, now: 0) == nil)
        let fresh = sender.seal(Data(count: 100))[0]
        for i in fresh.indices {
            var modified = fresh; modified[i] ^= 1
            precondition(receiver.open(modified, now: 0) == nil, "Tampered byte \(i) accepted")
        }
        for length in 0..<fresh.count { precondition(receiver.open(fresh.prefix(length), now: 0) == nil) }
        precondition(receiver.open(fresh, now: 0) != nil, "Invalid frames consumed replay sequence")
        var partialSender = try host(), partialReceiver = try viewer()
        for _ in 0..<65 { _ = partialReceiver.open(partialSender.seal(Data(count: 2000))[0], now: 0) }
        precondition(partialReceiver.pendingAssemblies == 64)
        partialReceiver.prune(now: 0.251)
        precondition(partialReceiver.pendingAssemblies == 0 && partialReceiver.expiredAssemblies == 64)
        let late = partialSender.seal(Data(count: 2000))
        precondition(partialReceiver.open(late[0], now: 1) == nil)
        precondition(partialReceiver.open(late[1], now: 1.3) == nil, "Expired fragments combined")
        var window = ReplayWindow()
        precondition(!window.accept(0))
        for n: UInt64 in [1, 2, 64, 65, 128, 129, 255, 256, 257, 511, 512, 768, 1024, 8191, 8192, 8193, 16384, UInt64.max] {
            precondition(window.accept(n)); precondition(!window.accept(n))
            if n > ReplayWindow.capacity { precondition(!window.accept(n - ReplayWindow.capacity)) }
        }
        // Compare to a simple reference set across thousands of deterministic out-of-order arrivals.
        var reference = Set<UInt64>(), highest: UInt64 = 0, replay = ReplayWindow(), random: UInt64 = 77
        for _ in 0..<20000 {
            random = random &* 6364136223846793005 &+ 1
            let candidate = random % 7 == 0 ? highest + 1 + random % 9000 : (highest > 10000 ? highest - random % 10000 : random % 10000)
            let expected = candidate > 0 && (candidate > highest || highest - candidate < ReplayWindow.capacity) && !reference.contains(candidate)
            precondition(replay.accept(candidate) == expected, "Replay window disagrees with reference")
            if expected { highest = max(highest, candidate); reference.insert(candidate) }
            reference = reference.filter { highest - $0 < ReplayWindow.capacity }
        }
        print("MEDIA_DATAGRAM_TESTS_PASSED: authentication, direction/session binding, replay, reordering, fragmentation and bounds")
    }
}
