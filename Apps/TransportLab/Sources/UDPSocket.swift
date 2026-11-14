import Foundation
import Darwin

// Socket transport is an IPv4 experiment. The Network.framework baseline retains
// IPv6 support. Both carry the same authenticated media envelope and use system DNS.
enum BridgeTransportKind: String, Codable, CaseIterable, Identifiable {
    case network, socket
    var id: String { rawValue }
    var title: String {
        switch self {
        case .network: return "Network.framework（兼容基线）"
        case .socket: return "UDP socket（IPv4 高码率实验）"
        }
    }
}

struct UDPPeer {
    var address: sockaddr_in
    var key: UInt64 { UInt64(address.sin_addr.s_addr) << 16 | UInt64(address.sin_port) }
    var scope: String {
        let host = UInt32(bigEndian: address.sin_addr.s_addr)
        if host >> 24 == 127 { return "loopback socket endpoint (remote topology unknown)" }
        if host >> 17 == 0x6309 { return "overlay virtual address (outer path unknown)" }
        return "non-loopback endpoint (outer path unknown)"
    }
}

/// One nonblocking UDP descriptor; datagrams are drained in bounded batches.
/// A host pins the peer only after the bridge authenticates its full-size probe.
final class UDPSocket {
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue: DispatchQueue
    private var peer: UDPPeer?
    private var buffer = [UInt8](repeating: 0, count: MediaDatagramCodec.maximumWireBytes + 1)
    private(set) var rejectedPeers = 0
    private(set) var truncatedPackets = 0
    private(set) var receiveBufferBytes: Int32 = 0
    var hasPeer: Bool { peer != nil }
    var onPacket: ((Data, UDPPeer, UInt64?) -> Void)?
    private(set) var kernelTimestampEnabled = false
    private(set) var kernelTimestampPackets = 0
    private(set) var kernelTimestampMissing = 0
    private var controlBuffer = [UInt8](repeating: 0, count: 128)
    var onFailure: ((String) -> Void)?

    init(queue: DispatchQueue, host: String?, port: UInt16, traceKernelArrival: Bool = false) throws {
        self.queue = queue
        guard port > 0 else { throw LabError.message("UDP 端口不能为 0") }
        if let host {
            var hints = addrinfo()
            hints.ai_family = AF_INET; hints.ai_socktype = SOCK_DGRAM; hints.ai_protocol = IPPROTO_UDP
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, String(port), &hints, &result) == 0, let result else {
                throw LabError.message("无法解析 IPv4 UDP 端点；IPv6 请使用 network 传输")
            }
            defer { freeaddrinfo(result) }
            guard let address = result.pointee.ai_addr, result.pointee.ai_addrlen >= MemoryLayout<sockaddr_in>.size else {
                throw LabError.message("无效 IPv4 UDP 端点")
            }
            peer = UDPPeer(address: address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee })
        }
        let descriptor = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { throw LabError.message("无法创建 UDP socket") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = host == nil ? port.bigEndian : 0
        address.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0,
              fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            Darwin.close(descriptor); throw LabError.message("无法绑定非阻塞 UDP socket")
        }
        fd = descriptor
        if traceKernelArrival {
            var enabled: Int32 = 1
            kernelTimestampEnabled = setsockopt(fd, SOL_SOCKET, SO_TIMESTAMP_MONOTONIC, &enabled,
                socklen_t(MemoryLayout<Int32>.size)) == 0
        }
        var capacity: Int32 = 256 * 1024
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &capacity, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &capacity, socklen_t(MemoryLayout<Int32>.size))
        var length = socklen_t(MemoryLayout<Int32>.size)
        _ = getsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receiveBufferBytes, &length)
    }
    func start() {
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue), descriptor = fd
        reader.setEventHandler { [weak self] in self?.drain() }
        reader.setCancelHandler { Darwin.close(descriptor) }
        source = reader; reader.resume()
    }
    func pin(_ candidate: UDPPeer) -> Bool {
        if let peer { return peer.key == candidate.key }
        peer = candidate; return true
    }
    func send(_ data: Data) -> Bool {
        guard fd >= 0, var address = peer?.address else { return false }
        let count = data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return count == data.count
    }
    func stop(completion: @escaping () -> Void = {}) {
        guard fd >= 0 else { completion(); return }
        let descriptor = fd
        if let source {
            source.setCancelHandler { Darwin.close(descriptor); completion() }
            source.cancel(); self.source = nil
        } else { Darwin.close(fd); completion() }
        fd = -1; peer = nil; onPacket = nil; onFailure = nil
    }
    deinit { stop() }
    private func drain() {
        for _ in 0..<32 {
            guard fd >= 0 else { return }
            var address = sockaddr_in(), length = socklen_t(MemoryLayout<sockaddr_in>.size)
            var kernelArrivalNs: UInt64?
            let count: Int
            if kernelTimestampEnabled {
                var controlLength = 0, flags: Int32 = 0
                count = buffer.withUnsafeMutableBytes { payload in
                    controlBuffer.withUnsafeMutableBytes { control in
                        withUnsafeMutablePointer(to: &address) { sender in
                            var vector = iovec(iov_base: payload.baseAddress, iov_len: payload.count)
                            return withUnsafeMutablePointer(to: &vector) { vector in
                                var message = msghdr(msg_name: UnsafeMutableRawPointer(sender), msg_namelen: length,
                                    msg_iov: vector, msg_iovlen: 1, msg_control: control.baseAddress,
                                    msg_controllen: socklen_t(control.count), msg_flags: 0)
                                let received = Darwin.recvmsg(fd, &message, 0)
                                length = message.msg_namelen; controlLength = Int(message.msg_controllen)
                                flags = message.msg_flags
                                return received
                            }
                        }
                    }
                }
                if count >= 0 && flags & MSG_CTRUNC == 0 {
                    kernelArrivalNs = controlBuffer.withUnsafeBytes {
                        KernelDatagramTimestamp.parse(UnsafeRawBufferPointer(rebasing: $0.prefix(controlLength)))
                    }
                }
                if flags & MSG_TRUNC != 0 { truncatedPackets += 1; continue }
            } else {
                count = withUnsafeMutablePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.recvfrom(fd, &buffer, buffer.count, 0, $0, &length)
                    }
                }
            }
            if count < 0 {
                if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { onFailure?("UDP socket 接收失败") }
                return
            }
            guard count > 0, count <= MediaDatagramCodec.maximumWireBytes else { truncatedPackets += 1; continue }
            guard address.sin_family == AF_INET, length >= MemoryLayout<sockaddr_in>.size else { continue }
            let sender = UDPPeer(address: address)
            if let peer, sender.key != peer.key { rejectedPeers += 1; continue }
            if kernelTimestampEnabled {
                if kernelArrivalNs != nil { kernelTimestampPackets += 1 } else { kernelTimestampMissing += 1 }
            }
            onPacket?(Data(buffer.prefix(count)), sender, kernelArrivalNs)
        }
    }
}

/// Darwin SCM_TIMESTAMP_MONOTONIC contains mach_absolute_time ticks (not nanoseconds).
/// XNU bsd/netinet/ip_input.c ip_savecontrol; CMSG records use Darwin's 32-bit alignment.
/// Only diagnostic sockets request this metadata. It timestamps IP-stack delivery,
/// not the physical NIC or the outer Ponte tunnel.
enum KernelDatagramTimestamp {
    private static let timebase: mach_timebase_info_data_t = {
        var value = mach_timebase_info_data_t()
        mach_timebase_info(&value)
        return value
    }()
    static func nanoseconds(ticks: UInt64, numerator: UInt64, denominator: UInt64) -> UInt64? {
        guard denominator > 0 else { return nil }
        let (whole, overflow1) = (ticks / denominator).multipliedReportingOverflow(by: numerator)
        let (fraction, overflow2) = (ticks % denominator).multipliedReportingOverflow(by: numerator)
        let (result, overflow3) = whole.addingReportingOverflow(fraction / denominator)
        return overflow1 || overflow2 || overflow3 ? nil : result
    }
    static func parse(_ bytes: UnsafeRawBufferPointer) -> UInt64? {
        let headerBytes = (MemoryLayout<cmsghdr>.size + 3) & ~3
        var offset = 0
        while bytes.count - offset >= headerBytes {
            let header = bytes.loadUnaligned(fromByteOffset: offset, as: cmsghdr.self)
            let length = Int(header.cmsg_len)
            guard length >= headerBytes, length <= bytes.count - offset else { return nil }
            if header.cmsg_level == SOL_SOCKET && header.cmsg_type == SCM_TIMESTAMP_MONOTONIC {
                guard length >= headerBytes + MemoryLayout<UInt64>.size else { return nil }
                let ticks = bytes.loadUnaligned(fromByteOffset: offset + headerBytes, as: UInt64.self)
                return nanoseconds(ticks: ticks, numerator: UInt64(timebase.numer), denominator: UInt64(timebase.denom))
            }
            offset += (length + 3) & ~3
        }
        return nil
    }
}
