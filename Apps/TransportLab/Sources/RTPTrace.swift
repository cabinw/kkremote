import Foundation

/// Negotiated video metadata only. Never retain SDP or inspect SRTP's encrypted payload/RTX OSN.
struct RTPTraceConfiguration: Codable {
    static let captureURI = "http://www.webrtc.org/experiments/rtp-hdrext/abs-capture-time"
    var primary: [UInt8: String] = [:]
    var rtx: [UInt8: UInt8] = [:]
    var captureExtensionID: UInt8?
    static func parse(_ sdp: String) -> Self {
        guard sdp.utf8.count <= 262_144 else { return Self() }
        var result = Self(), video = false, activeSections = 0, apt: [UInt8: UInt8] = [:], rtxPT = Set<UInt8>()
        for raw in sdp.split(whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("m=") {
                let fields = line.split(separator: " ")
                video = fields.count >= 4 && fields[0] == "m=video" && fields[1] != "0"
                if video { activeSections += 1 }
                continue
            }
            guard video else { continue }
            if line.hasPrefix("a=rtpmap:") {
                let f = line.dropFirst(9).split(separator: " ")
                guard f.count == 2, let pt = UInt8(f[0]), pt <= 127 else { continue }
                let encoding = f[1].uppercased()
                if encoding == "H264/90000" { result.primary[pt] = "H264" }
                if encoding == "H265/90000" { result.primary[pt] = "H265" }
                if encoding == "RTX/90000" { rtxPT.insert(pt) }
            } else if line.hasPrefix("a=fmtp:") {
                let f = line.dropFirst(7).split(separator: " ", maxSplits: 1)
                guard f.count == 2, let pt = UInt8(f[0]) else { continue }
                for pair in f[1].split(separator: ";") {
                    let p = pair.trimmingCharacters(in: .whitespaces).split(separator: "=")
                    if p.count == 2, p[0] == "apt", let primary = UInt8(p[1]) { apt[pt] = primary }
                }
            } else if line.hasPrefix("a=extmap:") {
                let f = line.dropFirst(9).split(separator: " ")
                // An encrypted extension has an extra encrypt URI; don't interpret it as plaintext.
                if f.count >= 2, f[1] == Substring(captureURI), let idPart = f[0].split(separator: "/").first,
                   let id = UInt8(idPart), id > 0 {
                    result.captureExtensionID = id
                }
            }
        }
        guard activeSections == 1 else { return Self() }
        for (pt, target) in apt where rtxPT.contains(pt) && result.primary[target] != nil { result.rtx[pt] = target }
        return result
    }
}

struct RTPTraceHeader {
    let ssrc: UInt32
    let timestamp: UInt32
    let sequence: UInt16
    let payloadType: UInt8
    let marker: Bool
    let kind: String
    let absoluteCaptureNtp: UInt64?
    static func parse(_ data: Data, configuration: RTPTraceConfiguration) -> Self? {
        data.withUnsafeBytes { raw -> Self? in
            let b = raw.bindMemory(to: UInt8.self)
            guard b.count >= 12, b[0] >> 6 == 2, !(192...223).contains(b[1]) else { return nil }
            let pt = b[1] & 127
            guard configuration.primary[pt] != nil || configuration.rtx[pt] != nil else { return nil }
            func u16(_ i: Int) -> UInt16 { UInt16(b[i]) << 8 | UInt16(b[i + 1]) }
            func u32(_ i: Int) -> UInt32 { UInt32(u16(i)) << 16 | UInt32(u16(i + 2)) }
            var offset = 12 + Int(b[0] & 15) * 4
            guard offset <= b.count else { return nil }
            var capture: UInt64?
            if b[0] & 16 != 0 {
                guard offset + 4 <= b.count else { return nil }
                let profile = u16(offset), size = Int(u16(offset + 2)) * 4
                offset += 4
                guard size <= b.count - offset else { return nil }
                let end = offset + size
                while offset < end {
                    if b[offset] == 0 { offset += 1; continue }
                    let id: UInt8, count: Int
                    if profile == 0xbede {
                        id = b[offset] >> 4; count = Int(b[offset] & 15) + 1; offset += 1
                        if id == 15 { break }
                    } else if profile & 0xfff0 == 0x1000 {
                        guard offset + 2 <= end else { return nil }
                        id = b[offset]; count = Int(b[offset + 1]); offset += 2
                    } else { break }
                    guard count <= end - offset else { return nil }
                    if id == configuration.captureExtensionID, count == 8 || count == 16 {
                        capture = UInt64(u32(offset)) << 32 | UInt64(u32(offset + 4))
                    }
                    offset += count
                }
            }
            let kind = (configuration.rtx[pt] == nil ? "primary" : "rtx") + (b[0] & 32 != 0 ? "-padding-flag" : "")
            return Self(ssrc: u32(8), timestamp: u32(4), sequence: u16(2), payloadType: pt,
                marker: b[1] & 128 != 0, kind: kind, absoluteCaptureNtp: capture)
        }
    }
}

struct RTPFrameObservation: Codable {
    let direction: String
    let ssrc: UInt32
    let timestamp: UInt32
    let payloadType: UInt8
    let kind: String
    var firstPacketNs: UInt64
    var lastPacketNs: UInt64
    var packets = 0
    var innerBytes = 0
    var sequences: [UInt16] = []
    var markers: [UInt16] = []
    var acceptedSequences: [UInt16] = []
    var droppedSequences: [UInt16] = []
    var sequenceMetadataOmitted = 0
    var absoluteCaptureNtp: UInt64?
    var firstKernelArrivalNs: UInt64?
    var lastKernelArrivalNs: UInt64?
    var kernelTimestampPackets: Int?
    var kernelToBridgeNsMax: UInt64?
    var invalidKernelTimestampPackets: Int?
    var firstQueueOutNs: UInt64?
    var lastQueueOutNs: UInt64?
    var firstAcceptedNs: UInt64?
    var lastAcceptedNs: UInt64?
    var firstDropNs: UInt64?
    var lastDropNs: UInt64?
    var adapterResidenceNsMax: UInt64 = 0
    var queueWaitNsMax: UInt64 = 0
    var queueWaitNsTotal: UInt64 = 0
    var queueSamples = 0
    var maxQueueDepth = 0
    var drops: [String: Int] = [:]
}

/// Bounded per-frame packet summaries. Called on the bridge queue; snapshots may run on main.
final class RTPTrace {
    struct Key: Hashable { let direction: String; let ssrc: UInt32; let timestamp: UInt32; let payloadType: UInt8; let kind: String }
    struct Snapshot: Codable {
        let configuration: RTPTraceConfiguration
        let capacity: Int
        let overwrittenFrames: Int
        let rejectedOrNonVideoPackets: Int
        let lateUpdatesAfterEviction: Int
        let frames: [RTPFrameObservation]
    }
    final class Packet {
        let key: Key
        let sequence: UInt16
        let enteredNs: UInt64
        fileprivate var expected = 1, finished = 0, failed = false
        init(key: Key, sequence: UInt16, enteredNs: UInt64) { self.key = key; self.sequence = sequence; self.enteredNs = enteredNs }
    }
    private let lock = NSLock()
    private var config = RTPTraceConfiguration()
    private var frames: [Key: RTPFrameObservation] = [:]
    private var order: [Key?]
    private var cursor = 0, evicted = 0, unrecognized = 0, lateUpdates = 0
    init(capacity: Int = 4096) { precondition(capacity > 0); order = Array(repeating: nil, count: capacity) }
    func configure(_ config: RTPTraceConfiguration) { lock.lock(); self.config = config; lock.unlock() }
    func observe(_ data: Data, direction: String, at now: UInt64 = DispatchTime.now().uptimeNanoseconds, kernelArrivalNs: UInt64? = nil) -> Packet? {
        lock.lock(); defer { lock.unlock() }
        guard let h = RTPTraceHeader.parse(data, configuration: config) else { unrecognized += 1; return nil }
        let key = Key(direction: direction, ssrc: h.ssrc, timestamp: h.timestamp, payloadType: h.payloadType, kind: h.kind)
        if frames[key] == nil {
            if let old = order[cursor] { frames.removeValue(forKey: old); evicted += 1 }
            order[cursor] = key; cursor = (cursor + 1) % order.count
            frames[key] = RTPFrameObservation(direction: direction, ssrc: h.ssrc, timestamp: h.timestamp,
                payloadType: h.payloadType, kind: h.kind, firstPacketNs: now, lastPacketNs: now)
        }
        if let kernelArrivalNs {
            if kernelArrivalNs <= now {
                frames[key]!.firstKernelArrivalNs = min(frames[key]!.firstKernelArrivalNs ?? kernelArrivalNs, kernelArrivalNs)
                frames[key]!.lastKernelArrivalNs = max(frames[key]!.lastKernelArrivalNs ?? kernelArrivalNs, kernelArrivalNs)
                frames[key]!.kernelTimestampPackets = (frames[key]!.kernelTimestampPackets ?? 0) + 1
                frames[key]!.kernelToBridgeNsMax = max(frames[key]!.kernelToBridgeNsMax ?? 0, now - kernelArrivalNs)
            } else { frames[key]!.invalidKernelTimestampPackets = (frames[key]!.invalidKernelTimestampPackets ?? 0) + 1 }
        }
        frames[key]!.lastPacketNs = now; frames[key]!.packets += 1; frames[key]!.innerBytes += data.count
        if frames[key]!.sequences.count < 4096 { frames[key]!.sequences.append(h.sequence) }
        else { frames[key]!.sequenceMetadataOmitted += 1 }
        if h.marker, frames[key]!.markers.count < 4096 { frames[key]!.markers.append(h.sequence) }
        if let capture = h.absoluteCaptureNtp { frames[key]!.absoluteCaptureNtp = capture }
        return Packet(key: key, sequence: h.sequence, enteredNs: now)
    }
    func prepare(_ packet: Packet?, fragments: Int) { packet?.expected = fragments }
    func dequeued(_ packet: Packet?, queuedNs: UInt64, depth: Int, at now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        guard let packet else { return }; lock.lock(); defer { lock.unlock() }
        guard frames[packet.key] != nil else { lateUpdates += 1; return }
        let age = now >= queuedNs ? now - queuedNs : 0
        frames[packet.key]!.firstQueueOutNs = frames[packet.key]!.firstQueueOutNs ?? now
        frames[packet.key]!.lastQueueOutNs = now
        frames[packet.key]!.queueWaitNsMax = max(frames[packet.key]!.queueWaitNsMax, age)
        frames[packet.key]!.queueWaitNsTotal += age; frames[packet.key]!.queueSamples += 1
        frames[packet.key]!.maxQueueDepth = max(frames[packet.key]!.maxQueueDepth, depth)
    }
    func completed(_ packet: Packet?, reason: String? = nil, at now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        guard let packet else { return }; lock.lock(); defer { lock.unlock() }
        guard frames[packet.key] != nil else { lateUpdates += 1; return }
        packet.finished += 1
        if let reason {
            packet.failed = true; frames[packet.key]!.drops[reason, default: 0] += 1
            frames[packet.key]!.firstDropNs = frames[packet.key]!.firstDropNs ?? now
            frames[packet.key]!.lastDropNs = now
        }
        else {
            frames[packet.key]!.firstAcceptedNs = frames[packet.key]!.firstAcceptedNs ?? now
            frames[packet.key]!.lastAcceptedNs = now
        }
        if packet.finished == packet.expected {
            frames[packet.key]!.adapterResidenceNsMax = max(frames[packet.key]!.adapterResidenceNsMax, now >= packet.enteredNs ? now - packet.enteredNs : 0)
            if packet.failed {
                if frames[packet.key]!.droppedSequences.count < 4096 { frames[packet.key]!.droppedSequences.append(packet.sequence) }
            } else if frames[packet.key]!.acceptedSequences.count < 4096 { frames[packet.key]!.acceptedSequences.append(packet.sequence) }
        }
    }
    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(configuration: config, capacity: order.count, overwrittenFrames: evicted,
            rejectedOrNonVideoPackets: unrecognized, lateUpdatesAfterEviction: lateUpdates,
            frames: frames.values.sorted { $0.firstPacketNs < $1.firstPacketNs })
    }
}
