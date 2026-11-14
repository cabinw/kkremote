import Foundation
import CryptoKit

enum MediaWireVersion: Int, Codable { case v1 = 1, v2 = 2 }

/// Endpoint envelope beneath ICE. WebRTC encryption/packetization is unchanged.
/// v2 fits a 1248-byte SRTP packet in one 1280-byte UDP payload. A full-size
/// authenticated path probe is required; this is not an IP MTU guarantee.
struct MediaDatagramCodec {
    static let maximumWireBytes = 1280
    var wireBytes: Int { version == .v2 ? 1280 : 1232 }
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
    private let version: MediaWireVersion
    private var headerBytes: Int { version == .v2 ? 16 : 32 }
    private var tagBytes: Int { version == .v2 ? 16 : 32 }
    private var fragmentBytes: Int { wireBytes - headerBytes - tagBytes }
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private let direction: UInt8
    private var sendSequence: UInt64 = 0
    private var packetID: UInt64 = 0
    private var replay = ReplayWindow()
    private var assemblies: [UInt64: Assembly] = [:]
    private(set) var rejectedPackets = 0
    private(set) var expiredAssemblies = 0
    private(set) var acceptedPackets: UInt64 = 0
    private(set) var highestSequence: UInt64 = 0
    private(set) var reorderedPackets = 0
    private(set) var largestSequenceGap: UInt64 = 0
    var sequenceHoles: UInt64 { highestSequence - acceptedPackets }
    var pendingAssemblies: Int { assemblies.count }
    var probeBytes: Int { version == .v2 ? fragmentBytes : 8 }

    init(secret: Data, session: String, isHost: Bool, version: MediaWireVersion = .v2) throws {
        guard secret.count == 32, !session.isEmpty else { throw LabError.message("无效 UDP 会话密钥") }
        self.version = version
        func key(_ label: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: Data(session.utf8),
                info: Data(("kkremote-udp-v\(version.rawValue)/" + label).utf8), outputByteCount: 32)
        }
        direction = isHost ? 0 : 1
        sendKey = key(isHost ? "host-to-viewer" : "viewer-to-host")
        receiveKey = key(isHost ? "viewer-to-host" : "host-to-viewer")
    }
    private func nonce(_ sequence: UInt64) throws -> AES.GCM.Nonce {
        // Separate keys per direction and per fresh session. Sequence never wraps.
        var bytes = Data(repeating: 0, count: 4); bytes.appendInteger(sequence)
        return try AES.GCM.Nonce(data: bytes)
    }
    mutating func seal(_ payload: Data, kind: Kind = .media) -> [Data] {
        guard !payload.isEmpty, payload.count <= Self.maximumInnerBytes,
              kind == .media || payload.count == 8 || (version == .v2 && payload.count == fragmentBytes) else { return [] }
        let count = (payload.count + fragmentBytes - 1) / fragmentBytes
        guard sendSequence < UInt64.max - UInt64(count), packetID < UInt64.max else { return [] }
        packetID += 1
        var packets: [Data] = []
        for index in 0..<count {
            sendSequence += 1
            let offset = index * fragmentBytes
            let content = payload.subdata(in: offset..<min(payload.count, offset + fragmentBytes))
            var frame: Data
            if version == .v2 {
                // magic(4), direction/kind(1), fragment index(1), total length(2), sequence(8).
                // The first sequence (sequence - index) identifies the fragmented inner packet.
                frame = Data([0x4b, 0x4b, 0x55, 0x32, direction << 7 | kind.rawValue, UInt8(index)])
                frame.appendInteger(UInt16(payload.count)); frame.appendInteger(sendSequence)
                guard let sealed = try? AES.GCM.seal(content, using: sendKey, nonce: nonce(sendSequence), authenticating: frame) else { return [] }
                frame.append(sealed.ciphertext); frame.append(sealed.tag)
            } else {
                frame = Data([0x4b, 0x4b, 0x55, 0x31, direction, kind.rawValue, 0, 0])
                frame.appendInteger(sendSequence); frame.appendInteger(packetID)
                frame.appendInteger(UInt16(index)); frame.appendInteger(UInt16(count)); frame.appendInteger(UInt32(payload.count))
                frame.append(content); frame.append(contentsOf: HMAC<SHA256>.authenticationCode(for: frame, using: sendKey))
            }
            packets.append(frame)
        }
        return packets
    }
    mutating func open(_ frame: Data, now: TimeInterval) -> Packet? {
        prune(now: now)
        guard frame.startIndex == 0, frame.count > headerBytes + tagBytes, frame.count <= wireBytes,
              frame.prefix(4) == Data([0x4b, 0x4b, 0x55, version == .v2 ? 0x32 : 0x31]) else { reject(); return nil }
        let kind: Kind, sequence: UInt64, id: UInt64, index: Int, count: Int, total: Int, payload: Data
        sequence = frame.integer(at: 8, as: UInt64.self)
        if version == .v2 {
            guard frame[4] >> 7 == (direction ^ 1), frame[4] & 0x7c == 0,
                  let parsed = Kind(rawValue: frame[4] & 3) else { reject(); return nil }
            kind = parsed; index = Int(frame[5]); total = Int(frame.integer(at: 6, as: UInt16.self))
            count = (total + fragmentBytes - 1) / fragmentBytes
            guard sequence > UInt64(index) else { reject(); return nil }
            id = sequence - UInt64(index)
            do {
                let sealed = try AES.GCM.SealedBox(nonce: nonce(sequence), ciphertext: frame.subdata(in: headerBytes..<(frame.count - tagBytes)), tag: frame.suffix(tagBytes))
                payload = try AES.GCM.open(sealed, using: receiveKey, authenticating: frame.prefix(headerBytes))
            } catch { reject(); return nil }
        } else {
            guard frame[4] == (direction ^ 1), frame[6] == 0, frame[7] == 0,
                  let parsed = Kind(rawValue: frame[5]),
                  HMAC<SHA256>.isValidAuthenticationCode(frame.suffix(tagBytes), authenticating: frame.dropLast(tagBytes), using: receiveKey) else { reject(); return nil }
            kind = parsed; id = frame.integer(at: 16, as: UInt64.self)
            index = Int(frame.integer(at: 24, as: UInt16.self)); count = Int(frame.integer(at: 26, as: UInt16.self))
            total = Int(frame.integer(at: 28, as: UInt32.self)); payload = frame.subdata(in: headerBytes..<(frame.count - tagBytes))
        }
        guard sequence > 0, id > 0, total > 0, total <= Self.maximumInnerBytes,
              count == (total + fragmentBytes - 1) / fragmentBytes,
              index < count, kind == .media || ((total == 8 || (version == .v2 && total == fragmentBytes)) && count == 1),
              payload.count == min(fragmentBytes, total - index * fragmentBytes), replay.accept(sequence) else { reject(); return nil }
        acceptedPackets += 1
        if sequence < highestSequence { reorderedPackets += 1 }
        if sequence > highestSequence {
            largestSequenceGap = max(largestSequenceGap, sequence - highestSequence - 1)
            highestSequence = sequence
        }
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
