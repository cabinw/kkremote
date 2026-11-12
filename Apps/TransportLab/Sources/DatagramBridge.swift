import Foundation
import Network

struct BridgeSample: Codable {
    var authenticated = false
    var endpointScope = "unresolved"
    var sentWireBytes: UInt64 = 0
    var receivedWireBytes: UInt64 = 0
    var sentDatagrams = 0
    var receivedDatagrams = 0
    var innerDatagramsSent = 0
    var innerDatagramsReceived = 0
    var queueDrops = 0
    var queueOverflowDrops = 0
    var queueDeadlineDrops = 0
    var sendErrors = 0
    var queueHighWater = 0
    var rejectedDatagrams = 0
    var expiredAssemblies = 0
    var localSocketDrops = 0
    var pendingPackets = 0
    var maxQueueAgeMilliseconds: Double = 0
    var probeRTTMilliseconds: Double? = nil
}

/// In-process endpoint adapter: WebRTC loopback UDP <-> authenticated fixed-endpoint UDP.
/// The external direction is always initiated by the viewer, including NAT/Ponte cases.
final class DatagramBridge {
    let localPort: UInt16
    private let queue = DispatchQueue(label: "kkremote.media-udp", qos: .userInteractive)
    private let local: LoopbackDatagramPort
    private var codec: MediaDatagramCodec
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var active: NWConnection?
    private var timer: DispatchSourceTimer?
    private var stopped = false
    private var state = BridgeSample()
    private var waiting: [(Data, TimeInterval)] = []
    private var inFlight = 0
    private var started = ProcessInfo.processInfo.systemUptime
    private var lastReceived: TimeInterval = 0
    private var lastProbe: TimeInterval = 0
    private var probes: [UInt64: TimeInterval] = [:]
    private let isHost: Bool
    var onReady: (() -> Void)?
    var onAuthenticated: (() -> Void)?
    var onFailure: ((String) -> Void)?

    init(secret: Data, session: String, isHost: Bool) throws {
        self.isHost = isHost
        codec = try MediaDatagramCodec(secret: secret, session: session, isHost: isHost)
        local = try LoopbackDatagramPort(queue: queue); localPort = local.port
        local.onPacket = { [weak self] data in self?.send(data, kind: .media) }
    }

    func setLocalPeer(port: UInt16) { queue.async { [weak self] in self?.local.setPeer(port: port) } }

    func startHost(port: UInt16) throws {
        guard port > 0 else { throw LabError.message("固定媒体端口不能为 0") }
        let listener = try NWListener(using: .udp, on: NWEndpoint.Port(rawValue: port)!)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, !self.stopped, self.active == nil, self.connections.count < 4 else { connection.cancel(); return }
            self.attach(connection)
        }
        listener.stateUpdateHandler = { [weak self] status in
            guard let self, !self.stopped else { return }
            if case .ready = status { DispatchQueue.main.async { self.onReady?() } }
            if case .failed(let error) = status { self.fail("UDP 媒体监听失败：\(error.localizedDescription)") }
        }
        queue.async { [weak self] in self?.begin() }
        listener.start(queue: queue)
    }

    func startViewer(host: String, port: UInt16) throws {
        guard port > 0, !host.isEmpty else { throw LabError.message("无效固定 UDP 媒体端点") }
        // Keep .sgponte intact. Network.framework uses the current system resolver/route.
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .udp)
        queue.async { [weak self] in
            guard let self else { return }
            self.begin(); self.active = connection; self.attach(connection)
        }
    }

    func snapshot() -> BridgeSample {
        queue.sync {
            var value = state
            value.pendingPackets = waiting.count + inFlight
            value.rejectedDatagrams = codec.rejectedPackets
            value.expiredAssemblies = codec.expiredAssemblies
            value.localSocketDrops = local.dropped
            return value
        }
    }

    func stop() {
        queue.async { [self] in
            guard !stopped else { return }; stopped = true
            timer?.cancel(); timer = nil; listener?.cancel(); listener = nil
            connections.values.forEach { $0.cancel() }; connections.removeAll(); active = nil
            local.stop(); waiting.removeAll(); probes.removeAll()
        }
    }

    private func begin() {
        started = ProcessInfo.processInfo.systemUptime
        local.start()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer; timer.resume()
    }

    private func attach(_ connection: NWConnection) {
        connections[ObjectIdentifier(connection)] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] status in
            guard let self, let connection, !self.stopped else { return }
            switch status {
            case .ready:
                if !self.isHost {
                    self.state.endpointScope = Self.scope(connection.currentPath?.remoteEndpoint)
                    DispatchQueue.main.async { self.onReady?() }
                    self.probe()
                }
                self.receive(connection)
            case .failed(let error):
                if self.active === connection { self.fail("UDP 端点连接失败：\(error.localizedDescription)") }
                self.remove(connection)
            case .cancelled: self.connections.removeValue(forKey: ObjectIdentifier(connection))
            default: break
            }
        }
        connection.start(queue: queue)
        if isHost {
            queue.asyncAfter(deadline: .now() + 2) { [weak self, weak connection] in
                guard let self, let connection, self.active !== connection else { return }
                self.remove(connection)
            }
        }
    }

    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] bytes, _, _, error in
            guard let self, let connection, !self.stopped else { return }
            if let bytes {
                let now = ProcessInfo.processInfo.systemUptime
                if let packet = self.codec.open(bytes, now: now) {
                    if self.isHost && self.active == nil {
                        guard packet.kind == .probe else { self.remove(connection); return }
                        self.active = connection
                        self.state.endpointScope = Self.scope(connection.endpoint)
                        for other in Array(self.connections.values) where other !== connection { self.remove(other) }
                    }
                    guard self.active === connection else { self.remove(connection); return }
                    self.lastReceived = now
                    self.state.receivedWireBytes += UInt64(bytes.count); self.state.receivedDatagrams += 1
                    if !self.state.authenticated {
                        self.state.authenticated = true
                        DispatchQueue.main.async { self.onAuthenticated?() }
                    }
                    switch packet.kind {
                    case .media:
                        self.state.innerDatagramsReceived += 1
                        self.local.send(packet.payload)
                    case .probe: self.send(packet.payload, kind: .acknowledgement)
                    case .acknowledgement:
                        let nonce = packet.payload.integer(at: 0, as: UInt64.self)
                        if let sent = self.probes.removeValue(forKey: nonce) { self.state.probeRTTMilliseconds = (now - sent) * 1000 }
                    }
                } else if self.active === connection {
                    // Authenticated fragment arrivals also count as wire traffic, not delivered inner packets.
                    self.state.receivedWireBytes += UInt64(bytes.count); self.state.receivedDatagrams += 1
                } else { self.remove(connection); return }
            }
            if let error {
                if self.active === connection { self.fail("UDP 接收失败：\(error.localizedDescription)") }
                self.remove(connection); return
            }
            self.receive(connection)
        }
    }

    private func send(_ payload: Data, kind: MediaDatagramCodec.Kind) {
        guard !stopped, active != nil, kind != .media || state.authenticated else { return }
        let packets = codec.seal(payload, kind: kind)
        guard waiting.count + packets.count <= 256 else {
            state.queueDrops += packets.count; state.queueOverflowDrops += packets.count; return
        }
        if kind == .media { state.innerDatagramsSent += 1 }
        let now = ProcessInfo.processInfo.systemUptime
        waiting.append(contentsOf: packets.map { ($0, now) })
        state.queueHighWater = max(state.queueHighWater, waiting.count + inFlight)
        pump()
    }

    private func pump() {
        guard !stopped, let connection = active else { return }
        while inFlight < 32, !waiting.isEmpty {
            let (data, queued) = waiting.removeFirst()
            let age = (ProcessInfo.processInfo.systemUptime - queued) * 1000
            state.maxQueueAgeMilliseconds = max(state.maxQueueAgeMilliseconds, age)
            guard age <= 25 else { state.queueDrops += 1; state.queueDeadlineDrops += 1; continue }
            inFlight += 1
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self, !self.stopped else { return }
                self.inFlight -= 1
                if error != nil { self.state.queueDrops += 1; self.state.sendErrors += 1 }
                else { self.state.sentWireBytes += UInt64(data.count); self.state.sentDatagrams += 1 }
                self.pump()
            })
        }
    }

    private func probe() {
        guard !isHost, let active, case .ready = active.state else { return }
        let now = ProcessInfo.processInfo.systemUptime
        probes = probes.filter { now - $0.value < 3 }
        let nonce = DispatchTime.now().uptimeNanoseconds
        probes[nonce] = now; lastProbe = now
        var data = Data(); data.appendInteger(nonce); send(data, kind: .probe)
    }
    private func tick() {
        guard !stopped else { return }
        let now = ProcessInfo.processInfo.systemUptime
        codec.prune(now: now)
        if !state.authenticated && now - started > 15 {
            fail("TLS 已通，但固定 UDP 媒体端点未通过认证探测；检查 Ponte 接管、主机名和媒体端口")
        } else if state.authenticated && now - lastReceived > 8 {
            fail("UDP 媒体路径已中断，停止并重新连接")
        } else if !isHost && now - lastProbe >= (state.authenticated ? 1 : 0.25) { probe() }
    }
    private func remove(_ connection: NWConnection) { connection.cancel(); connections.removeValue(forKey: ObjectIdentifier(connection)) }
    private func fail(_ message: String) {
        guard !stopped else { return }
        DispatchQueue.main.async { [weak self] in self?.onFailure?(message) }
        stop()
    }
    private static func scope(_ endpoint: NWEndpoint?) -> String {
        guard case .hostPort(let host, _) = endpoint else { return "unresolved" }
        let text = String(describing: host)
        // A remote Ponte session can be handed to the host through a local Surge proxy socket.
        if text.hasPrefix("127.") || text == "::1" { return "loopback socket endpoint (remote topology unknown)" }
        if text.hasPrefix("198.18.") || text.hasPrefix("198.19.") { return "overlay virtual address (outer path unknown)" }
        return "non-loopback endpoint (outer path unknown)"
    }
}
