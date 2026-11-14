import Foundation
import Darwin

/// A single nonblocking socket. Only the exact, locally gathered ICE endpoint is accepted.
/// It cannot relay to arbitrary addresses or learn a destination from untrusted packets.
final class LoopbackDatagramPort {
    let port: UInt16
    private var fd: Int32
    private let queue: DispatchQueue
    private var source: DispatchSourceRead?
    private var destination: sockaddr_in?
    var onPacket: ((Data) -> Void)?
    private(set) var dropped = 0
    private(set) var rejectedSources = 0
    private(set) var sendErrors = 0
    private(set) var unboundSends = 0
    private(set) var invalidSizes = 0

    init(queue: DispatchQueue) throws {
        self.queue = queue
        let socketFD = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketFD >= 0 else { throw LabError.message("无法创建本机 UDP 适配端口") }
        var address = Self.address(port: 0)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0, fcntl(socketFD, F_SETFL, O_NONBLOCK) == 0 else {
            Darwin.close(socketFD); throw LabError.message("无法绑定本机 UDP 适配端口")
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) }
        }
        guard named == 0 else { Darwin.close(socketFD); throw LabError.message("无法读取本机 UDP 端口") }
        fd = socketFD; port = UInt16(bigEndian: address.sin_port)
        var capacity: Int32 = 256 * 1024
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &capacity, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &capacity, socklen_t(MemoryLayout<Int32>.size))
    }

    func start() {
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let descriptor = fd
        reader.setEventHandler { [weak self] in self?.drain() }
        reader.setCancelHandler { Darwin.close(descriptor) }
        source = reader; reader.resume()
    }
    func setPeer(port: UInt16) { destination = Self.address(port: port) }
    @discardableResult func send(_ data: Data) -> Bool {
        guard fd >= 0, var destination else { dropped += 1; unboundSends += 1; return false }
        let sent = data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &destination) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sent != data.count { dropped += 1; sendErrors += 1 }
        return sent == data.count
    }
    func stop(completion: @escaping () -> Void = {}) {
        guard fd >= 0 else { completion(); return }
        let descriptor = fd
        if let source {
            source.setCancelHandler { Darwin.close(descriptor); completion() }
            source.cancel(); self.source = nil
        } else { Darwin.close(fd); completion() }
        fd = -1; destination = nil; onPacket = nil
    }
    deinit { stop() }

    private func drain() {
        var bytes = [UInt8](repeating: 0, count: MediaDatagramCodec.maximumInnerBytes + 1)
        // Bound work per dispatch turn so probe timers and stop are not starved at high bitrate.
        // Yield before filling the bridge's 32 in-flight datagrams. A 1200-byte RTP packet
        // uses two outer fragments in legacy v1; draining 128 at once starved completions.
        for _ in 0..<16 {
            guard fd >= 0 else { return }
            var sender = sockaddr_in(), length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &sender) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.recvfrom(fd, &bytes, bytes.count, 0, $0, &length) }
            }
            if count < 0 { return }
            guard count > 0, count <= MediaDatagramCodec.maximumInnerBytes else { dropped += 1; invalidSizes += 1; continue }
            guard let destination, sender.sin_addr.s_addr == destination.sin_addr.s_addr,
                  sender.sin_port == destination.sin_port else { dropped += 1; rejectedSources += 1; continue }
            onPacket?(Data(bytes.prefix(count)))
        }
    }
    private static func address(port: UInt16) -> sockaddr_in {
        var value = sockaddr_in()
        value.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); value.sin_family = sa_family_t(AF_INET)
        value.sin_port = port.bigEndian; value.sin_addr.s_addr = inet_addr("127.0.0.1")
        return value
    }
}
