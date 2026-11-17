import Foundation

/// Local test harness, never selected by a peer or persisted in user preferences.
/// Applies only to host outbound RTP; control/DTLS/probes continue normally.
enum TransportImpairmentProfile: String, Codable, CaseIterable {
    case none, loss1, loss3, outage200, outage1200, jitter, bandwidthDrop = "bandwidth-drop"
    var interval: ClosedRange<Double>? {
        switch self {
        case .none: return nil
        case .loss1, .loss3, .jitter: return 5...20
        case .outage200: return 15...15.2
        case .outage1200: return 15...16.2
        case .bandwidthDrop: return 10...25
        }
    }
}

struct ImpairmentSample: Codable {
    var profile: TransportImpairmentProfile = .none
    var startSeconds: Double?, endSeconds: Double?
    var considered = 0, dropped = 0, delayed = 0, capacityDrops = 0, cancelled = 0
    var pending = 0, highWater = 0
    var maximumDelayMilliseconds: Double = 0
}

/// Deterministic decisions with an injected clock; delayed packets are separately bounded
/// by the bridge. Artificial residence is not reported as production bridge queue time.
struct TransportImpairment {
    enum Decision: Equatable { case pass, drop, delay(UInt64) }
    let profile: TransportImpairmentProfile
    private var random: UInt64 = 0x4b4b_7265_6d6f_7465
    private var nextSerializedNs: UInt64 = 0
    init(_ profile: TransportImpairmentProfile) { self.profile = profile }
    mutating func decide(age: Double, nowNs: UInt64, bytes: Int) -> Decision {
        guard let interval = profile.interval, age >= interval.lowerBound, age < interval.upperBound else {
            nextSerializedNs = 0; return .pass
        }
        random ^= random << 13; random ^= random >> 7; random ^= random << 17
        switch profile {
        case .none: return .pass
        case .loss1, .loss3: return random % 10_000 < (profile == .loss1 ? 100 : 300) ? .drop : .pass
        case .outage200, .outage1200: return .drop
        case .jitter:
            // Deterministic 0...40 ms one-way variation, naturally including reordering.
            let delay = (random % 41) * 1_000_000
            return delay == 0 ? .pass : .delay(nowNs + delay)
        case .bandwidthDrop:
            // 6 Mbps link, 120 ms maximum simulated residence; full datagram bytes counted.
            let next = max(nowNs, nextSerializedNs) + UInt64(max(1, bytes)) * 8_000 / 6
            guard next - nowNs <= 120_000_000 else { return .drop }
            nextSerializedNs = next
            return .delay(next)
        }
    }
}
