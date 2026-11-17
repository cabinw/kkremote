#if os(macOS)
import Foundation
import Darwin

/// Binds a real physical NIC (e.g. en0) via IP_BOUND_IF so macOS TUN/Fake-IP proxies
/// (Surge Enhanced Mode / Clash TUN) cannot hijack Native Direct WebRTC UDP into an overseas proxy.
final class PhysicalDirectBridge {
    struct Endpoint: Hashable {
        let ip: String
        let port: UInt16
        var addr: sockaddr_in {
            var sin = sockaddr_in()
            sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            sin.sin_family = sa_family_t(AF_INET)
            sin.sin_port = port.bigEndian
            _ = ip.withCString { inet_pton(AF_INET, $0, &sin.sin_addr) }
            return sin
        }
    }

    let localPort: UInt16
    private(set) var lanIP: String = ""
    private(set) var physicalPort: UInt16 = 0
    private(set) var srflxEndpoint: Endpoint?

    private let queue = DispatchQueue(label: "kkremote.physical-direct-udp", qos: .userInteractive)
    private let local: LoopbackDatagramPort
    private let portMapper = RouterPortMapper()
    private var boundIfIndex: UInt32 = 0
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var stopped = false
    private var stunServerIPs: Set<String> = []
    private var targets: [Endpoint] = []
    private var neighborTargets: [Endpoint] = []
    private var srflxPortsByIP: [String: [UInt16]] = [:]
    private var activePeer: Endpoint?
    private var lastInboundAt: TimeInterval = 0
    private var lastSweepAt: TimeInterval = 0

    init() throws {
        local = try LoopbackDatagramPort(queue: queue)
        localPort = local.port
        local.onPacket = { [weak self] data in
            self?.sendOutbound(data)
        }
    }

    func setLocalPeer(port: UInt16) {
        queue.async { [weak self] in self?.local.setPeer(port: port) }
    }

    /// Discovers physical hardware interface, binds IP_BOUND_IF, and queries numeric STUN servers.
    func prepare(stunServers: [String], completion: @escaping (Result<[String], Error>) -> Void) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            do {
                let (ifName, ifIndex, localIPv4) = try Self.findPhysicalIPv4Interface()
                self.lanIP = localIPv4
                self.boundIfIndex = ifIndex

                let sock = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
                guard sock >= 0 else { throw LabError.message("无法创建物理网卡 UDP 套接字") }
                var idx = ifIndex
                guard setsockopt(sock, IPPROTO_IP, IP_BOUND_IF, &idx, socklen_t(MemoryLayout<UInt32>.size)) == 0 else {
                    Darwin.close(sock)
                    throw LabError.message("无法绑定物理网卡 \(ifName)")
                }
                var sndBuf: Int32 = 1_048_576
                var rcvBuf: Int32 = 2_097_152
                _ = setsockopt(sock, SOL_SOCKET, SO_SNDBUF, &sndBuf, socklen_t(MemoryLayout<Int32>.size))
                _ = setsockopt(sock, SOL_SOCKET, SO_RCVBUF, &rcvBuf, socklen_t(MemoryLayout<Int32>.size))

                var bindAddr = sockaddr_in()
                bindAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                bindAddr.sin_family = sa_family_t(AF_INET)
                bindAddr.sin_port = 0
                bindAddr.sin_addr.s_addr = INADDR_ANY
                let bound = withUnsafePointer(to: &bindAddr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                guard bound == 0 else {
                    Darwin.close(sock)
                    throw LabError.message("无法分配物理网卡本地 UDP 端口")
                }

                var actual = sockaddr_in()
                var actualLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                _ = withUnsafeMutablePointer(to: &actual) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        getsockname(sock, $0, &actualLen)
                    }
                }
                self.physicalPort = UInt16(bigEndian: actual.sin_port)
                self.stunServerIPs = Set(stunServers.compactMap { raw in
                    let trimmed = raw.replacingOccurrences(of: "stun:", with: "")
                    return trimmed.split(separator: ":").first.map(String.init)
                })

                // Synchronous short STUN Binding query on the exact physical socket before switching non-blocking.
                self.srflxEndpoint = Self.querySTUN(sock: sock, stunServers: stunServers)

                // Attempt ephemeral NAT-PMP / UPnP mapping on the local gateway so Symmetric 5G peers can traverse NAT3.
                let gw = Self.guessGateway(fromLANIP: localIPv4)
                let mappedExtPort = self.portMapper.mapUDP(ifIndex: ifIndex, lanIP: localIPv4, gatewayIP: gw, internalPort: self.physicalPort)

                let flags = fcntl(sock, F_GETFL, 0)
                _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)
                self.fd = sock
                self.local.start()
                self.startReadLoop(sock: sock)

                var candidates: [String] = [
                    "candidate:kkphys1 1 udp 2122260223 \(self.lanIP) \(self.physicalPort) typ host generation 0"
                ]
                if let srflx = self.srflxEndpoint {
                    let advPort = mappedExtPort ?? srflx.port
                    candidates.append("candidate:kkphys2 1 udp 1686052607 \(srflx.ip) \(advPort) typ srflx raddr \(self.lanIP) rport \(self.physicalPort) generation 0")
                    if let mappedExtPort, mappedExtPort != srflx.port {
                        candidates.append("candidate:kkphys3 1 udp 1686052606 \(srflx.ip) \(srflx.port) typ srflx raddr \(self.lanIP) rport \(self.physicalPort) generation 0")
                    }
                }
                DispatchQueue.main.async { completion(.success(candidates)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func addRemoteCandidate(_ sdp: String) {
        let cleaned = sdp.hasPrefix("a=") ? String(sdp.dropFirst(2)) : sdp
        let parts = cleaned.split(separator: " ")
        guard parts.count >= 6, parts[2].lowercased() == "udp",
              let port = UInt16(parts[5]), port > 0 else { return }
        let ip = String(parts[4])
        var addr = in_addr()
        guard inet_pton(AF_INET, ip, &addr) == 1 else { return }
        // Ignore loopback / link-local / fake-ip 198.18.0.0/15 / Clash TUN 172.19.0.1
        if ip.hasPrefix("127.") || ip.hasPrefix("169.254.") || ip.hasPrefix("198.18.") || ip.hasPrefix("198.19.") || ip.hasPrefix("0.") || ip == "172.19.0.1" {
            return
        }
        let isSrflx = cleaned.contains(" typ srflx")
        let ep = Endpoint(ip: ip, port: port)
        queue.async { [weak self] in
            guard let self, !self.stopped, !self.stunServerIPs.contains(ip) else { return }
            if !self.targets.contains(ep), self.targets.count < 16 {
                self.targets.append(ep)
            }
            if isSrflx {
                var seen = self.srflxPortsByIP[ip, default: []]
                if !seen.contains(port) { seen.append(port) }
                self.srflxPortsByIP[ip] = seen
                if let hi = seen.max(), let lo = seen.min() {
                    for delta in 1...16 where hi <= UInt16.max - UInt16(delta) {
                        let pred = Endpoint(ip: ip, port: hi + UInt16(delta))
                        if !self.targets.contains(pred), !self.neighborTargets.contains(pred), self.neighborTargets.count < 24 {
                            self.neighborTargets.append(pred)
                        }
                    }
                    for delta in 1...2 where lo > UInt16(delta) + 1024 {
                        let pred = Endpoint(ip: ip, port: lo - UInt16(delta))
                        if !self.targets.contains(pred), !self.neighborTargets.contains(pred), self.neighborTargets.count < 24 {
                            self.neighborTargets.append(pred)
                        }
                    }
                }
            }
        }
    }

    private func startReadLoop(sock: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: sock, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self, !self.stopped, self.fd >= 0 else { return }
            var buf = [UInt8](repeating: 0, count: 2048)
            while true {
                var sender = sockaddr_in()
                var senderLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &sender) { sPtr in
                    sPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                        buf.withUnsafeMutableBytes { rawPtr in
                            recvfrom(sock, rawPtr.baseAddress, rawPtr.count, 0, saPtr, &senderLen)
                        }
                    }
                }
                if n <= 0 { break }
                guard sender.sin_family == sa_family_t(AF_INET) else { continue }
                var cstr = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var inAddr = sender.sin_addr
                guard inet_ntop(AF_INET, &inAddr, &cstr, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
                let ip = String(cString: cstr)
                let port = UInt16(bigEndian: sender.sin_port)
                let ep = Endpoint(ip: ip, port: port)
                let packet = Data(bytes: buf, count: n)

                // Never accept traffic from STUN servers themselves once session read loop starts.
                guard !self.stunServerIPs.contains(ip) else { continue }
                if let first = packet.first {
                    let looksValidICEOrMedia = (first == 0x00 || first == 0x01 || (20...63).contains(first) || (128...191).contains(first))
                    guard looksValidICEOrMedia else { continue }
                }
                // Accept traffic from declared candidate IPs, LAN peers, or valid peer ICE STUN packets (request 0x0001 or response 0x0101 + magic cookie).
                let knownIP = self.targets.contains(where: { $0.ip == ip }) || ip.hasPrefix("192.168.") || ip.hasPrefix("10.") || ip.hasPrefix("172.")
                let isPeerICEPacket = packet.count >= 28 && (packet[0] == 0x00 || packet[0] == 0x01) && packet[1] == 0x01
                    && packet[4] == 0x21 && packet[5] == 0x12 && packet[6] == 0xA4 && packet[7] == 0x42
                if knownIP || (self.activePeer == nil && isPeerICEPacket) {
                    self.activePeer = ep
                    self.lastInboundAt = ProcessInfo.processInfo.systemUptime
                    if !self.targets.contains(ep), self.targets.count < 24 {
                        self.targets.append(ep)
                    }
                    self.local.send(packet)
                }
            }
        }
        self.readSource = source
        source.resume()
    }

    private func sendOutbound(_ data: Data) {
        guard !stopped, fd >= 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // If we have an active peer that spoke within the last 5 seconds, send directly to it;
        // otherwise (during ICE hole punching or path recovery), fan out connectivity checks to all candidates.
        if let peer = activePeer, now - lastInboundAt < 5.0 {
            sendDatagram(data, to: peer)
        } else {
            for target in targets {
                sendDatagram(data, to: target)
            }
            if now - lastSweepAt >= 0.25 {
                lastSweepAt = now
                for pred in neighborTargets {
                    sendDatagram(data, to: pred)
                }
            }
        }
    }

    private func sendDatagram(_ data: Data, to endpoint: Endpoint) {
        guard fd >= 0 else { return }
        var dst = endpoint.addr
        _ = data.withUnsafeBytes { rawPtr in
            withUnsafePointer(to: &dst) { dPtr in
                dPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    sendto(fd, rawPtr.baseAddress, rawPtr.count, 0, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    func stop(completion: @escaping () -> Void = {}) {
        queue.async { [self] in
            guard !stopped else { DispatchQueue.main.async(execute: completion); return }
            stopped = true
            if boundIfIndex > 0 { portMapper.unmap(ifIndex: boundIfIndex) }
            let sock = fd
            fd = -1
            if let readSource {
                readSource.setCancelHandler {
                    if sock >= 0 { Darwin.close(sock) }
                }
                readSource.cancel()
                self.readSource = nil
            } else if sock >= 0 {
                Darwin.close(sock)
            }
            local.stop {
                DispatchQueue.main.async(execute: completion)
            }
        }
    }

    private static func querySTUN(sock: Int32, stunServers: [String]) -> Endpoint? {
        var tv = timeval(tv_sec: 1, tv_usec: 500_000)
        _ = setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        defer {
            var zero = timeval(tv_sec: 0, tv_usec: 0)
            _ = setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &zero, socklen_t(MemoryLayout<timeval>.size))
        }

        for raw in stunServers {
            let trimmed = raw.replacingOccurrences(of: "stun:", with: "")
            let parts = trimmed.split(separator: ":")
            guard let host = parts.first.map(String.init) else { continue }
            let port = parts.count > 1 ? (UInt16(parts[1]) ?? 3478) : 3478
            var sin = sockaddr_in()
            sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            sin.sin_family = sa_family_t(AF_INET)
            sin.sin_port = port.bigEndian
            guard inet_pton(AF_INET, host, &sin.sin_addr) == 1 else { continue }

            var req = Data([0x00, 0x01, 0x00, 0x00, 0x21, 0x12, 0xA4, 0x42])
            var txid = [UInt8](repeating: 0, count: 12)
            _ = SecRandomCopyBytes(kSecRandomDefault, 12, &txid)
            req.append(contentsOf: txid)

            let sent = req.withUnsafeBytes { rawPtr in
                withUnsafePointer(to: &sin) { sPtr in
                    sPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                        sendto(sock, rawPtr.baseAddress, rawPtr.count, 0, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            guard sent == 20 else { continue }

            var resp = [UInt8](repeating: 0, count: 512)
            let n = resp.withUnsafeMutableBytes { rawPtr in
                recv(sock, rawPtr.baseAddress, rawPtr.count, 0)
            }
            guard n >= 28, resp[0] == 0x01, resp[1] == 0x01,
                  Array(resp[8..<20]) == txid else { continue }

            var offset = 20
            while offset + 4 <= n {
                let attrType = (UInt16(resp[offset]) << 8) | UInt16(resp[offset + 1])
                let attrLen = Int((UInt16(resp[offset + 2]) << 8) | UInt16(resp[offset + 3]))
                if attrType == 0x0020, offset + 4 + attrLen <= n, attrLen >= 8, resp[offset + 5] == 0x01 {
                    let xport = ((UInt16(resp[offset + 6]) << 8) | UInt16(resp[offset + 7])) ^ 0x2112
                    let b0 = resp[offset + 8] ^ 0x21
                    let b1 = resp[offset + 9] ^ 0x12
                    let b2 = resp[offset + 10] ^ 0xA4
                    let b3 = resp[offset + 11] ^ 0x42
                    return Endpoint(ip: "\(b0).\(b1).\(b2).\(b3)", port: xport)
                }
                offset += 4 + ((attrLen + 3) & ~3)
            }
        }
        return nil
    }

    private static func guessGateway(fromLANIP ip: String) -> String {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return "192.168.1.1" }
        return "\(parts[0]).\(parts[1]).\(parts[2]).1"
    }

    private static func findPhysicalIPv4Interface() throws -> (String, UInt32, String) {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else {
            throw LabError.message("无法读取系统网络接口")
        }
        defer { freeifaddrs(first) }

        var candidates: [(String, UInt32, String)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let item = current.pointee
            cursor = item.ifa_next
            let flags = Int32(item.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0, (flags & IFF_POINTOPOINT) == 0,
                  let addr = item.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: item.ifa_name)
            guard name.hasPrefix("en") else { continue }
            let sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            var cstr = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var inAddr = sin.sin_addr
            guard inet_ntop(AF_INET, &inAddr, &cstr, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let ip = String(cString: cstr)
            guard !ip.hasPrefix("169.254."), !ip.hasPrefix("198.18."), !ip.hasPrefix("198.19.") else { continue }
            let idx = if_nametoindex(name)
            guard idx > 0 else { continue }
            candidates.append((name, idx, ip))
        }
        if let en0 = candidates.first(where: { $0.0 == "en0" }) ?? candidates.first {
            return en0
        }
        throw LabError.message("未找到可用的物理 Wi-Fi/以太网 IPv4 接口")
    }
}
#endif
