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
        for hostKind in [BridgeTransportKind.network, .socket] {
            for viewerKind in [BridgeTransportKind.network, .socket] {
                try socketRoundTrip(key: key, hostKind: hostKind, viewerKind: viewerKind)
            }
        }
        try socketRoundTrip(key: key, hostKind: .socket, viewerKind: .network, version: .v1)
        try socketAdmission(key: key)
        print("DATAGRAM_BRIDGE_TESTS_PASSED: UDP echo, full-size path admission, pinned source, wrong-key rejection")
    }
    static func socketRoundTrip(key: Data, hostKind: BridgeTransportKind, viewerKind: BridgeTransportKind, version: MediaWireVersion = .v2) throws {
        let host = try DatagramBridge(secret: key, session: "mixed", isHost: true, version: version, transport: hostKind)
        let viewer = try DatagramBridge(secret: key, session: "mixed", isHost: false, version: version, transport: viewerKind)
        let queue = DispatchQueue(label: "mixed-test")
        let a = try LoopbackDatagramPort(queue: queue), b = try LoopbackDatagramPort(queue: queue)
        a.setPeer(port: host.localPort); host.setLocalPeer(port: a.port)
        b.setPeer(port: viewer.localPort); viewer.setLocalPeer(port: b.port)
        let payload = Data(repeating: 39, count: 16384)
        var passed = false, error: String?
        a.onPacket = { data in DispatchQueue.main.async { passed = data == payload } }
        b.onPacket = { b.send($0) }
        a.start(); b.start()
        let port = UInt16.random(in: 49000...59000)
        host.onFailure = { error = $0 }; viewer.onFailure = { error = $0 }
        host.onReady = { try! viewer.startViewer(host: "127.0.0.1", port: port) }
        viewer.onAuthenticated = { queue.async { a.send(payload) } }
        try host.startHost(port: port)
        let deadline = Date().addingTimeInterval(3)
        while !passed, error == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        precondition(passed && error == nil, "Mixed transport echo failed: \(hostKind)/\(viewerKind), \(error ?? "timeout")")
        precondition(host.snapshot().authenticated && viewer.snapshot().authenticated)
        if version == .v2 {
            precondition(host.snapshot().pathDatagramBytes == 1280 && viewer.snapshot().pathDatagramBytes == 1280)
        }
        if hostKind == .socket {
            let stranger = try LoopbackDatagramPort(queue: queue)
            stranger.setPeer(port: port)
            var codec = try MediaDatagramCodec(secret: key, session: "mixed", isHost: false)
            let probe = codec.seal(Data(count: codec.probeBytes), kind: .probe)[0]
            queue.sync { stranger.send(probe); stranger.stop() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            precondition(host.snapshot().socketRejectedPeers > 0, "Pinned socket accepted a different source")
        }
        host.stop(); viewer.stop(); queue.sync { a.stop(); b.stop() }
    }

    static func socketAdmission(key: Data) throws {
        let host = try DatagramBridge(secret: key, session: "socket-admission", isHost: true, transport: .socket)
        let queue = DispatchQueue(label: "socket-admission-test")
        let sender = try LoopbackDatagramPort(queue: queue)
        let port = UInt16.random(in: 49000...59000)
        sender.setPeer(port: port)
        var ready = false
        host.onReady = { ready = true }
        try host.startHost(port: port)
        let deadline = Date().addingTimeInterval(2)
        while !ready, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        precondition(ready)
        var wrong = try MediaDatagramCodec(secret: Data(repeating: 99, count: 32), session: "socket-admission", isHost: false)
        let invalid = wrong.seal(Data(count: wrong.probeBytes), kind: .probe)[0]
        queue.sync { sender.send(invalid) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(!host.snapshot().authenticated && host.snapshot().rejectedDatagrams > 0)
        var valid = try MediaDatagramCodec(secret: key, session: "socket-admission", isHost: false)
        let small = valid.seal(Data(count: 8), kind: .probe)[0]
        queue.sync { sender.send(small) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(!host.snapshot().authenticated, "Socket admitted a small probe")
        let full = valid.seal(Data(count: valid.probeBytes), kind: .probe)[0]
        queue.sync { sender.send(full) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(host.snapshot().authenticated && host.snapshot().pathDatagramBytes == 1280)
        host.stop(); queue.sync { sender.stop() }
    }

}
