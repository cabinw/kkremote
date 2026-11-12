import Foundation
import CryptoKit

/// Versioned packet adapter below ICE. It never decrypts or re-encodes WebRTC media.
/// Keys are fresh for each TLS-authenticated session, with separate directions.
struct MediaDatagramCodec {
    static let maximumWireBytes = 1232 // IPv6 minimum MTU minus IPv6/UDP headers.
    static let headerBytes = 32
    static let tagBytes = 32
    static let fragmentBytes = maximumWireBytes - headerBytes - tagBytes
    static let maximumInnerBytes = 16_384
    static let maximumAssemblies = 64
    static let assemblyLifetime = 0.25
    enum Kind: UInt8 { case media = 0, probe = 1, acknowledgement = 2 }
    struct Packet { let kind: Kind; let payload: Data }
    private struct Assembly {
        let created: TimeInterval
        let total: Int
        let count: Int
        var parts: [Int: Data] = [:]
    }
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private let direction: UInt8
    private var sendSequence: UInt64 = 0
    private var packetID: UInt64 = 0
    private var replay = ReplayWindow()
    private var assemblies: [UInt64: Assembly] = [:]
    private(set) var rejectedPackets = 0
    private(set) var expiredAssemblies = 0
    var pendingAssemblies: Int { assemblies.count }

    init(secret: Data, session: String, isHost: Bool) throws {
        guard secret.count == 32, !session.isEmpty else { throw LabError.message("无效 UDP 会话密钥") }
        func key(_ label: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret),
                salt: Data(session.utf8), info: Data(("kkremote-udp-v1/" + label).utf8), outputByteCount: 32)
        }
        direction = isHost ? 0 : 1
        sendKey = key(isHost ? "host-to-viewer" : "viewer-to-host")
        receiveKey = key(isHost ? "viewer-to-host" : "host-to-viewer")
    }

    mutating func seal(_ payload: Data, kind: Kind = .media) -> [Data] {
        guard !payload.isEmpty, payload.count <= Self.maximumInnerBytes,
              kind == .media || payload.count == 8 else { return [] }
        let count = (payload.count + Self.fragmentBytes - 1) / Self.fragmentBytes
        guard sendSequence < UInt64.max - UInt64(count), packetID < UInt64.max else { return [] }
        packetID += 1
        return (0..<count).map { index in
            sendSequence += 1
            var frame = Data([0x4b, 0x4b, 0x55, 0x31, direction, kind.rawValue, 0, 0])
            frame.appendInteger(sendSequence); frame.appendInteger(packetID)
            frame.appendInteger(UInt16(index)); frame.appendInteger(UInt16(count))
            frame.appendInteger(UInt32(payload.count))
            let offset = index * Self.fragmentBytes
            frame.append(payload.subdata(in: offset..<min(payload.count, offset + Self.fragmentBytes)))
            frame.append(contentsOf: HMAC<SHA256>.authenticationCode(for: frame, using: sendKey))
            return frame
        }
    }

    mutating func open(_ frame: Data, now: TimeInterval) -> Packet? {
        prune(now: now)
        guard frame.startIndex == 0, frame.count > Self.headerBytes + Self.tagBytes, frame.count <= Self.maximumWireBytes,
              frame.prefix(4) == Data([0x4b, 0x4b, 0x55, 0x31]), frame[4] == (direction ^ 1),
              frame[6] == 0, frame[7] == 0, let kind = Kind(rawValue: frame[5]) else { reject(); return nil }
        let body = frame.dropLast(Self.tagBytes)
        guard HMAC<SHA256>.isValidAuthenticationCode(frame.suffix(Self.tagBytes), authenticating: body, using: receiveKey) else {
            reject(); return nil
        }
        let sequence = frame.integer(at: 8, as: UInt64.self)
        let id = frame.integer(at: 16, as: UInt64.self)
        let index = Int(frame.integer(at: 24, as: UInt16.self))
        let count = Int(frame.integer(at: 26, as: UInt16.self))
        let total = Int(frame.integer(at: 28, as: UInt32.self))
        guard sequence > 0, id > 0, total > 0, total <= Self.maximumInnerBytes,
              count == (total + Self.fragmentBytes - 1) / Self.fragmentBytes,
              index < count, kind == .media || (total == 8 && count == 1),
              frame.count - Self.headerBytes - Self.tagBytes == min(Self.fragmentBytes, total - index * Self.fragmentBytes),
              replay.accept(sequence) else { reject(); return nil }
        let payload = frame.subdata(in: Self.headerBytes..<(frame.count - Self.tagBytes))
        if count == 1 { return Packet(kind: kind, payload: payload) }
        if assemblies[id] == nil {
            guard assemblies.count < Self.maximumAssemblies else { reject(); return nil }
            assemblies[id] = Assembly(created: now, total: total, count: count)
        }
        guard var assembly = assemblies[id], assembly.total == total, assembly.count == count,
              assembly.parts[index] == nil else { reject(); return nil }
        assembly.parts[index] = payload
        if assembly.parts.count == count {
            assemblies.removeValue(forKey: id)
            var data = Data(capacity: total)
            for i in 0..<count { data.append(assembly.parts[i]!) }
            return Packet(kind: kind, payload: data)
        }
        assemblies[id] = assembly
        return nil
    }

    mutating func prune(now: TimeInterval) {
        let expired = assemblies.filter { now - $0.value.created > Self.assemblyLifetime }.map(\.key)
        expiredAssemblies += expired.count
        expired.forEach { assemblies.removeValue(forKey: $0) }
    }
    private mutating func reject() { rejectedPackets += 1 }
}

/// Accept bounded reordering, but never duplicate or stale authenticated packets.
struct ReplayWindow {
    // 8192 sequence slots cover roughly 250 ms at 120 Mbps, including small tail fragments.
    // Sequence tags avoid shifting a bitmap for every packet; total storage is bounded at 64 KiB.
    static let capacity: UInt64 = 8192
    private var highest: UInt64 = 0
    private var slots = [UInt64](repeating: 0, count: Int(capacity))
    mutating func accept(_ sequence: UInt64) -> Bool {
        guard sequence > 0 else { return false }
        if sequence <= highest && highest - sequence >= Self.capacity { return false }
        let index = Int(sequence % Self.capacity)
        guard slots[index] != sequence else { return false }
        slots[index] = sequence; highest = max(highest, sequence)
        return true
    }
}

extension Data {
    mutating func appendInteger<T: FixedWidthInteger>(_ value: T) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }
    func integer<T: FixedWidthInteger>(at offset: Int, as: T.Type) -> T {
        self[offset..<(offset + MemoryLayout<T>.size)].reduce(T.zero) { ($0 << 8) | T($1) }
    }
}
