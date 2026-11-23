import Foundation

@main enum TransportImpairmentTests {
    static func main() {
        for profile in TransportImpairmentProfile.allCases {
            var first = TransportImpairment(profile), second = TransportImpairment(profile)
            precondition(first.decide(age: 0, nowNs: 0, bytes: 1280) == .pass)
            for i in 0..<1000 {
                let now = UInt64(i) * 200_000
                precondition(first.decide(age: 15.1, nowNs: now, bytes: 1280) == second.decide(age: 15.1, nowNs: now, bytes: 1280))
            }
            precondition(first.decide(age: 30, nowNs: 30_000_000_000, bytes: 1280) == .pass)
        }
        for (profile, expected) in [(TransportImpairmentProfile.loss1, 0.01), (.loss3, 0.03)] {
            var network = TransportImpairment(profile), lost = 0
            for i in 0..<100_000 { if network.decide(age: 10, nowNs: UInt64(i), bytes: 1280) == .drop { lost += 1 } }
            precondition(abs(Double(lost) / 100_000 - expected) < 0.002)
        }
        var outage = TransportImpairment(.outage1200)
        precondition(outage.decide(age: 15, nowNs: 0, bytes: 100) == .drop)
        precondition(outage.decide(age: 16.199, nowNs: 1, bytes: 100) == .drop)
        precondition(outage.decide(age: 16.2, nowNs: 2, bytes: 100) == .pass)
        var limited = TransportImpairment(.bandwidthDrop), dropped = 0
        for _ in 0..<1000 {
            switch limited.decide(age: 15, nowNs: 100, bytes: 1280) {
            case .delay(let ns): precondition(ns > 100 && ns <= 120_000_100)
            case .drop: dropped += 1
            case .pass: preconditionFailure("rate limit silently bypassed")
            }
        }
        precondition(dropped > 900)
        var jitter = TransportImpairment(.jitter), previous: UInt64 = 0, reordered = false
        for i in 0..<1000 {
            let now = UInt64(i) * 100_000
            let arrival: UInt64
            if case .delay(let ns) = jitter.decide(age: 10, nowNs: now, bytes: 1280) {
                precondition(ns - now <= 40_000_000); arrival = ns
            } else { arrival = now }
            reordered = reordered || arrival < previous; previous = arrival
        }
        precondition(reordered)
        let resources = ResourceTelemetry().snapshot()
        precondition((resources.residentBytes ?? 0) > 0 && (resources.physicalFootprintBytes ?? 0) > 0)
        precondition(resources.cpuPercent == nil)
        print("TRANSPORT_IMPAIRMENT_TESTS_PASSED: deterministic loss, outage edges, bounded rate/jitter, resources")
    }
}
