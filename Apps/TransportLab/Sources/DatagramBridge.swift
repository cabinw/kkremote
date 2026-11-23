import Foundation
import Network

struct BridgeSample: Codable {
    var transport = "network"
    var socketReceiveBufferBytes: Int32?
    var socketRejectedPeers = 0
    var socketTruncatedPackets = 0
    var socketKernelTimestampEnabled: Bool?
    var socketKernelTimestampPackets: Int?
    var socketKernelTimestampMissing: Int?
    var receiveDepth = 1
    var acceptedPackets: UInt64 = 0
    var sequenceHoles: UInt64 = 0
    var reorderedPackets = 0
    var largestSequenceGap: UInt64 = 0
    var wireVersion = 2
    var pathDatagramBytes = 0
    var fragmentedInnerDatagrams = 0
    var rtpSizeCounts: [String: Int] = [:]
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
    var localRejectedSources = 0
    var localSendErrors = 0
    var localUnboundSends = 0
    var localInvalidSizes = 0
    var pendingPackets = 0
    var maxQueueAgeMilliseconds: Double = 0
    var probeRTTMilliseconds: Double? = nil
    var simulatedDrops = 0
    var oldestWaitingMilliseconds: Double = 0
    var impairment: ImpairmentSample? = nil
}

/// In-process endpoint adapter: WebRTC loopback UDP <-> authenticated fixed-endpoint UDP.
/// The external direction is always initiated by the viewer, including NAT/Ponte cases.
final class DatagramBridge {
    // Explicit CLI self-test only; captured once per host bridge, never enabled by remote input.
    static var simulateLossInSelfTest = false
    static var simulatedOutageMilliseconds = 200
    static var diagnosticImpairment = TransportImpairmentProfile.none
    let localPort: UInt16
    private let queue = DispatchQueue(label: "kkremote.media-udp", qos: .userInteractive)
    private let local: LoopbackDatagramPort
    private var codec: MediaDatagramCodec
    private var socket: UDPSocket?
    private let transport: BridgeTransportKind
    private var hasEndpoint: Bool { active != nil || socket?.hasPeer == true }
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var active: NWConnection?
    private var timer: DispatchSourceTimer?
    private var stopped = false
    private var state = BridgeSample()
    private struct WaitingPacket {
        let data: Data
        let queuedNs: UInt64
        let tracePacket: RTPTrace.Packet?
    }
    private var waiting: [WaitingPacket] = []
    private let trace: RTPTrace?
    private var inFlight = 0
    private var started = ProcessInfo.processInfo.systemUptime
    private var lastReceived: TimeInterval = 0
    private var lastProbe: TimeInterval = 0
    private var probes: [UInt64: TimeInterval] = [:]
    private let isHost: Bool
    private let simulateLoss: Bool
    private let outageSeconds: Double
    private var impairmentPackets = 0
    private var impairment: TransportImpairment
    private var impairmentState: ImpairmentSample
    private struct DelayedPacket {
        let at: UInt64
        let data: Data
        let tracePacket: RTPTrace.Packet?
    }
    private var delayed: [DelayedPacket] = []
    private var delayTimer: DispatchSourceTimer?
    var onReady: (() -> Void)?
    var onAuthenticated: (() -> Void)?
    var onFailure: ((String) -> Void)?

    init(secret: Data, session: String, isHost: Bool, version: MediaWireVersion = .v2, receiveDepth: Int = 16, transport: BridgeTransportKind = .network, trace: RTPTrace? = nil) throws {
        self.trace = trace
        guard [1, 16].contains(receiveDepth) else { throw LabError.message("无效 UDP 接收深度") }
        self.isHost = isHost; self.transport = transport
        self.simulateLoss = isHost && Self.simulateLossInSelfTest
        self.outageSeconds = Double(Self.simulatedOutageMilliseconds) / 1000
        let profile = isHost ? Self.diagnosticImpairment : .none
        impairment = TransportImpairment(profile)
        impairmentState = ImpairmentSample(profile: profile, startSeconds: profile.interval?.lowerBound,
            endSeconds: profile.interval?.upperBound)
        state.transport = transport.rawValue
        state.receiveDepth = receiveDepth
        state.wireVersion = version.rawValue
        codec = try MediaDatagramCodec(secret: secret, session: session, isHost: isHost, version: version)
        local = try LoopbackDatagramPort(queue: queue); localPort = local.port
        local.onPacket = { [weak self] data in self?.send(data, kind: .media) }
    }

    func setLocalPeer(port: UInt16) { queue.async { [weak self] in self?.local.setPeer(port: port) } }

    func startHost(port: UInt16) throws {
        guard port > 0 else { throw LabError.message("固定媒体端口不能为 0") }
        if transport == .socket { startSocket(host: nil, port: port); return }
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
        if transport == .socket { startSocket(host: host, port: port); return }
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
            value.oldestWaitingMilliseconds = waiting.first.map { Double(DispatchTime.now().uptimeNanoseconds - $0.queuedNs) / 1e6 } ?? 0
            value.rejectedDatagrams = codec.rejectedPackets
            value.expiredAssemblies = codec.expiredAssemblies
            value.localSocketDrops = local.dropped
            value.localRejectedSources = local.rejectedSources
            value.localSendErrors = local.sendErrors
            value.localUnboundSends = local.unboundSends
            value.localInvalidSizes = local.invalidSizes
            value.socketReceiveBufferBytes = socket?.receiveBufferBytes
            value.socketRejectedPeers = socket?.rejectedPeers ?? 0
            value.socketTruncatedPackets = socket?.truncatedPackets ?? 0
            value.socketKernelTimestampEnabled = socket?.kernelTimestampEnabled
            value.socketKernelTimestampPackets = socket?.kernelTimestampPackets
            value.socketKernelTimestampMissing = socket?.kernelTimestampMissing
            value.acceptedPackets = codec.acceptedPackets
            value.sequenceHoles = codec.sequenceHoles
            value.reorderedPackets = codec.reorderedPackets
            value.largestSequenceGap = codec.largestSequenceGap
            if impairment.profile != .none {
                var diagnostic = impairmentState; diagnostic.pending = delayed.count
                value.impairment = diagnostic
            }
            return value
        }
    }

    func stop(completion: @escaping () -> Void = {}) {
        queue.async { [self] in
            guard !stopped else { DispatchQueue.main.async(execute: completion); return }; stopped = true
            let group = DispatchGroup()
            timer?.cancel(); timer = nil
            delayTimer?.cancel(); delayTimer = nil
            impairmentState.cancelled += delayed.count
            for entry in delayed { trace?.completed(entry.tracePacket, reason: "impairment_stop") }
            delayed.removeAll()
            if let listener {
                group.enter()
                listener.stateUpdateHandler = { if case .cancelled = $0 { group.leave() } }
                listener.cancel(); self.listener = nil
            }
            for connection in connections.values {
                group.enter()
                connection.stateUpdateHandler = { if case .cancelled = $0 { group.leave() } }
                connection.cancel()
            }
            connections.removeAll(); active = nil
            group.enter(); local.stop { group.leave() }
            if let socket { group.enter(); socket.stop { group.leave() }; self.socket = nil }
            for entry in waiting { trace?.completed(entry.tracePacket, reason: "stop_waiting") }
            waiting.removeAll(); probes.removeAll()
            group.notify(queue: .main, execute: completion)
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
                // Keep receive requests available while earlier callbacks run. All
                // completions still execute on the same serial bridge queue.
                connection.batch {
                    for _ in 0..<self.state.receiveDepth { self.receive(connection) }
                }
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

    private func startSocket(host: String?, port: UInt16) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            do {
                let socket = try UDPSocket(queue: self.queue, host: host, port: port, traceKernelArrival: self.trace != nil)
                self.socket = socket
                socket.onFailure = { [weak self] in self?.fail($0) }
                socket.onPacket = { [weak self, weak socket] bytes, sender, kernelArrivalNs in
                    guard let self, let socket, !self.stopped else { return }
                    self.ingest(bytes, activeSource: socket.hasPeer, kernelArrivalNs: kernelArrivalNs) {
                        guard socket.pin(sender) else { return false }
                        self.state.endpointScope = sender.scope; return true
                    }
                }
                self.begin(); socket.start()
                DispatchQueue.main.async { self.onReady?() }
                if !self.isHost { self.probe() }
            } catch { self.fail(error.localizedDescription) }
        }
    }

    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] bytes, _, _, error in
            guard let self, let connection, !self.stopped else { return }
            guard self.active == nil || self.active === connection else { self.remove(connection); return }
            if let bytes {
                let accepted = self.ingest(bytes, activeSource: self.active === connection) {
                    if self.isHost && self.active == nil {
                        self.active = connection
                        self.state.endpointScope = Self.scope(connection.endpoint)
                        for other in Array(self.connections.values) where other !== connection { self.remove(other) }
                    }
                    return self.active === connection
                }
                if !accepted && self.active !== connection { self.remove(connection); return }
            }
            if let error {
                if self.active === connection { self.fail("UDP 接收失败：\(error.localizedDescription)") }
                self.remove(connection); return
            }
            self.receive(connection)
        }
    }

    @discardableResult
    private func ingest(_ bytes: Data, activeSource: Bool, kernelArrivalNs: UInt64? = nil, select: () -> Bool) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        guard let packet = codec.open(bytes, now: now) else {
            if activeSource { state.receivedWireBytes += UInt64(bytes.count); state.receivedDatagrams += 1 }
            return activeSource
        }
        if !state.authenticated {
            let expectedKind: MediaDatagramCodec.Kind = isHost ? .probe : .acknowledgement
            // A small but valid probe doesn't qualify the path, and should not
            // prevent this same peer from retrying with a full-size probe.
            guard packet.kind == expectedKind, packet.payload.count == codec.probeBytes else { return true }
            if !isHost, probes[packet.payload.integer(at: 0, as: UInt64.self)] == nil { return true }
            state.pathDatagramBytes = bytes.count
        }
        guard select() else { return false }
        lastReceived = now
        state.receivedWireBytes += UInt64(bytes.count); state.receivedDatagrams += 1
        if !state.authenticated {
            state.authenticated = true
            DispatchQueue.main.async { self.onAuthenticated?() }
        }
        switch packet.kind {
        case .media:
            state.innerDatagramsReceived += 1
            let observation = trace?.observe(packet.payload, direction: "inbound", kernelArrivalNs: kernelArrivalNs)
            let accepted = local.send(packet.payload)
            trace?.completed(observation, reason: accepted ? nil : "loopback_send_failure")
        case .probe: send(packet.payload, kind: .acknowledgement)
        case .acknowledgement:
            let nonce = packet.payload.integer(at: 0, as: UInt64.self)
            if let sent = probes.removeValue(forKey: nonce) { state.probeRTTMilliseconds = (now - sent) * 1000 }
        }
        return true
    }

    private func send(_ payload: Data, kind: MediaDatagramCodec.Kind) {
        guard !stopped, hasEndpoint, kind != .media || state.authenticated else { return }
        let observation = kind == .media ? trace?.observe(payload, direction: "outbound") : nil
        let packets = codec.seal(payload, kind: kind)
        trace?.prepare(observation, fragments: max(1, packets.count))
        if packets.isEmpty { trace?.completed(observation, reason: "envelope_rejected"); return }
        if simulateLoss, kind == .media, payload.count >= 12, payload[0] & 0xc0 == 0x80,
           !(192...223).contains(Int(payload[1])) {
            impairmentPackets += 1
            let age = ProcessInfo.processInfo.systemUptime - started
            if (age >= 5 && age < 15 && impairmentPackets % 100 == 0) || (age >= 15 && age < 15 + outageSeconds) {
                state.simulatedDrops += packets.count
                for _ in packets { trace?.completed(observation, reason: "simulated_loss") }
                return
            }
        }
        if kind == .media, let first = payload.first, first & 0xc0 == 0x80 {
            let bucket = payload.count <= 1168 ? "<=1168" : payload.count <= 1200 ? "1169-1200" : payload.count <= 1248 ? "1201-1248" : ">1248"
            state.rtpSizeCounts[bucket, default: 0] += 1
        }
        if impairment.profile != .none, kind == .media, payload.count >= 12,
           payload[0] & 0xc0 == 0x80, !(192...223).contains(Int(payload[1])) {
            state.innerDatagramsSent += 1
            if packets.count > 1 { state.fragmentedInnerDatagrams += 1 }
            let now = DispatchTime.now().uptimeNanoseconds
            let age = ProcessInfo.processInfo.systemUptime - started
            for data in packets {
                impairmentState.considered += 1
                switch impairment.decide(age: age, nowNs: now, bytes: data.count) {
                case .pass: enqueue([data], observation: observation)
                case .drop:
                    impairmentState.dropped += 1; state.simulatedDrops += 1
                    trace?.completed(observation, reason: "impairment_\(impairment.profile.rawValue)")
                case .delay(let at):
                    guard delayed.count < 256 else {
                        impairmentState.capacityDrops += 1; state.simulatedDrops += 1
                        trace?.completed(observation, reason: "impairment_capacity"); continue
                    }
                    impairmentState.delayed += 1
                    impairmentState.maximumDelayMilliseconds = max(impairmentState.maximumDelayMilliseconds, Double(at - now) / 1e6)
                    // Equal-time datagrams preserve insertion order. Variable delays can reorder.
                    let position = delayed.firstIndex { $0.at > at } ?? delayed.endIndex
                    delayed.insert(DelayedPacket(at: at, data: data, tracePacket: observation), at: position)
                    impairmentState.highWater = max(impairmentState.highWater, delayed.count)
                }
            }
            armDelayed(); return
        }
        if kind == .media {
            state.innerDatagramsSent += 1
            if packets.count > 1 { state.fragmentedInnerDatagrams += 1 }
        }
        enqueue(packets, observation: observation)
    }

    private func armDelayed() {
        guard let first = delayed.first else { delayTimer?.cancel(); delayTimer = nil; return }
        if delayTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler { [weak self] in
                guard let self, !self.stopped else { return }
                let now = DispatchTime.now().uptimeNanoseconds
                while let packet = self.delayed.first, packet.at <= now {
                    self.delayed.removeFirst(); self.enqueue([packet.data], observation: packet.tracePacket)
                }
                self.armDelayed()
            }
            delayTimer = timer; timer.resume()
        }
        delayTimer?.schedule(deadline: DispatchTime(uptimeNanoseconds: first.at), leeway: .microseconds(100))
    }

    private func enqueue(_ packets: [Data], observation: RTPTrace.Packet?) {
        guard waiting.count + packets.count <= 256 else {
            state.queueDrops += packets.count; state.queueOverflowDrops += packets.count
            for _ in packets { trace?.completed(observation, reason: "queue_overflow") }
            return
        }
        let now = DispatchTime.now().uptimeNanoseconds
        waiting.append(contentsOf: packets.map { WaitingPacket(data: $0, queuedNs: now, tracePacket: observation) })
        state.queueHighWater = max(state.queueHighWater, waiting.count + inFlight)
        pump()
    }

    private func pump() {
        guard !stopped, hasEndpoint else { return }
        while inFlight < 32, !waiting.isEmpty {
            let depth = waiting.count + inFlight
            let entry = waiting.removeFirst(), data = entry.data
            let now = DispatchTime.now().uptimeNanoseconds
            let age = Double(now - entry.queuedNs) / 1e6
            trace?.dequeued(entry.tracePacket, queuedNs: entry.queuedNs, depth: depth, at: now)
            state.maxQueueAgeMilliseconds = max(state.maxQueueAgeMilliseconds, age)
            guard age <= 25 else {
                state.queueDrops += 1; state.queueDeadlineDrops += 1
                trace?.completed(entry.tracePacket, reason: "queue_deadline"); continue
            }
            if let socket {
                if socket.send(data) {
                    state.sentWireBytes += UInt64(data.count); state.sentDatagrams += 1
                    trace?.completed(entry.tracePacket)
                }
                else { state.queueDrops += 1; state.sendErrors += 1; trace?.completed(entry.tracePacket, reason: "socket_send_failure") }
                continue
            }
            guard let connection = active else { return }
            inFlight += 1
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.trace?.completed(entry.tracePacket, reason: error == nil ? nil : "network_send_failure")
                guard !self.stopped else { return }
                self.inFlight -= 1
                if error != nil { self.state.queueDrops += 1; self.state.sendErrors += 1 }
                else { self.state.sentWireBytes += UInt64(data.count); self.state.sentDatagrams += 1 }
                self.pump()
            })
        }
    }

    private func probe() {
        guard !isHost, hasEndpoint else { return }
        if let active, case .ready = active.state {} else if socket == nil { return }
        let now = ProcessInfo.processInfo.systemUptime
        probes = probes.filter { now - $0.value < 3 }
        let nonce = DispatchTime.now().uptimeNanoseconds
        probes[nonce] = now; lastProbe = now
        var data = Data(); data.appendInteger(nonce)
        if !state.authenticated { data.append(Data(repeating: 0, count: codec.probeBytes - 8)) }
        send(data, kind: .probe)
    }
    private func tick() {
        guard !stopped else { return }
        let now = ProcessInfo.processInfo.systemUptime
        codec.prune(now: now)
        if !state.authenticated && now - started > 15 {
            fail("固定 UDP v\(state.wireVersion) 未通过双向认证探测（\(codec.wireBytes) 字节上限）；检查路径、主机名和媒体端口")
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
