import Foundation
import Network

@main
enum DatagramBridgeTests {
    static func main() throws {
        let key = Data(repeating: 23, count: 32)
        let queue = DispatchQueue(label: "bridge-test")
        let host = try DatagramBridge(secret: key, session: "integration", isHost: true)
        let viewer = try DatagramBridge(secret: key, session: "integration", isHost: false)
        let hostPeer = try LoopbackDatagramPort(queue: queue), viewerPeer = try LoopbackDatagramPort(queue: queue)
        host.setLocalPeer(port: hostPeer.port); viewer.setLocalPeer(port: viewerPeer.port)
        hostPeer.setPeer(port: host.localPort); viewerPeer.setPeer(port: viewer.localPort)
        let payload = Data((0..<16384).map { UInt8($0 % 251) })
        var echoed = false, failure: String?
        hostPeer.onPacket = { bytes in DispatchQueue.main.async { echoed = bytes == payload } }
        viewerPeer.onPacket = { bytes in viewerPeer.send(bytes) }
        hostPeer.start(); viewerPeer.start()
        let port = UInt16.random(in: 49000...59000)
        host.onFailure = { failure = $0 }; viewer.onFailure = { failure = $0 }
        host.onReady = { try! viewer.startViewer(host: "127.0.0.1", port: port) }
        viewer.onAuthenticated = { queue.async { hostPeer.send(payload) } }
        try host.startHost(port: port)
        let deadline = Date().addingTimeInterval(5)
        while !echoed, failure == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        precondition(failure == nil && echoed, "Real UDP fragmented round trip failed: \(failure ?? "timeout")")
        precondition(host.snapshot().authenticated && viewer.snapshot().authenticated)
        precondition(host.snapshot().pathDatagramBytes == 1280 && viewer.snapshot().pathDatagramBytes == 1280,
                     "v2 must probe a full-sized UDP payload in both directions")
        precondition(viewer.snapshot().innerDatagramsReceived >= 1 && host.snapshot().innerDatagramsReceived >= 1)
        // A different local process/socket cannot inject into the pinned WebRTC endpoint.
        let stranger = try LoopbackDatagramPort(queue: queue)
        stranger.setPeer(port: host.localPort)
        queue.sync { stranger.send(Data(count: 100)); stranger.stop() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(host.snapshot().localSocketDrops >= 1)
        host.stop(); viewer.stop()
        queue.sync { hostPeer.stop(); viewerPeer.stop() }

        let rejectedHost = try DatagramBridge(secret: key, session: "reject", isHost: true)
        let wrongViewer = try DatagramBridge(secret: Data(repeating: 99, count: 32), session: "reject", isHost: false)
        let rejectPort = UInt16.random(in: 49000...59000)
        var ready = false
        rejectedHost.onReady = { ready = true; try! wrongViewer.startViewer(host: "127.0.0.1", port: rejectPort) }
        try rejectedHost.startHost(port: rejectPort)
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        precondition(ready && !rejectedHost.snapshot().authenticated && !wrongViewer.snapshot().authenticated)
        precondition(rejectedHost.snapshot().rejectedDatagrams > 0)
        rejectedHost.stop(); wrongViewer.stop()

        // An authenticated small packet alone must not qualify the v2 media path.
        let sizeHost = try DatagramBridge(secret: key, session: "path-size", isHost: true)
        var smallCodec = try MediaDatagramCodec(secret: key, session: "path-size", isHost: false)
        let sizePort = UInt16.random(in: 49000...59000)
        let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: sizePort)!, using: .udp)
        var probeReady = false
        client.stateUpdateHandler = { state in if case .ready = state { probeReady = true } }
        sizeHost.onReady = { client.start(queue: .main) }
        try sizeHost.startHost(port: sizePort)
        let readyDeadline = Date().addingTimeInterval(2)
        while !probeReady, Date() < readyDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        precondition(probeReady)
        client.send(content: smallCodec.seal(Data(count: 8), kind: .probe)[0], completion: .contentProcessed { _ in })
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        precondition(!sizeHost.snapshot().authenticated, "8-byte probe falsely qualified the v2 path")
        client.send(content: smallCodec.seal(Data(count: smallCodec.probeBytes), kind: .probe)[0], completion: .contentProcessed { _ in })
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        precondition(sizeHost.snapshot().authenticated && sizeHost.snapshot().pathDatagramBytes == 1280)
        client.cancel(); sizeHost.stop()
        print("DATAGRAM_BRIDGE_TESTS_PASSED: UDP echo, full-size path admission, pinned source, wrong-key rejection")
    }
}
