import Foundation

@main struct FrameTraceTests {
    static func main() throws {
        let trace = FrameTrace(capacity: 256)
        DispatchQueue.concurrentPerform(iterations: 10_000) { i in
            trace.record(.encodeSubmit, ptsNs: Int64(i), rtp: UInt32(truncatingIfNeeded: UInt64(UInt32.max) + UInt64(i)))
            if i % 17 == 0 {
                let snapshot = trace.snapshot()
                precondition(snapshot.events.count <= 256)
                precondition(snapshot.summary.recorded == snapshot.summary.overwritten + UInt64(snapshot.summary.retained))
            }
        }
        let snapshot = trace.snapshot()
        precondition(snapshot.summary.recorded == 10_000 && snapshot.summary.overwritten == 9_744)
        precondition(snapshot.events.map(\.sequence) == Array(UInt64(9_744)..<10_000))
        precondition(zip(snapshot.events, snapshot.events.dropFirst()).allSatisfy { $0.uptimeNs <= $1.uptimeNs })
        precondition(FrameTrace().summary().epoch != snapshot.summary.epoch, "Generations must not share identity")
        let identityTrace = FrameTrace()
        trace.beginShutdown(); identityTrace.beginShutdown()
        precondition(FrameTrace.awaitingShutdown)
        trace.endShutdown(); precondition(FrameTrace.awaitingShutdown)
        identityTrace.endShutdown(); precondition(!FrameTrace.awaitingShutdown)
        var wrapper: NSObject? = NSObject()
        weak var weakWrapper = wrapper
        identityTrace.sourceSubmitted(buffer: wrapper!, frameID: 1, ptsNs: 123_456_789)
        precondition(identityTrace.encoderSubmitted(buffer: wrapper!, ptsNs: 123_460_000, rtp: UInt32.max) == 1,
            "SDK timestamp adjustment must not break exact wrapper identity")
        precondition(identityTrace.encoderSubmitted(buffer: NSObject(), ptsNs: 123_460_000, rtp: 0) == nil,
            "Similar timestamps must never manufacture a match")
        identityTrace.sourceSubmitted(buffer: wrapper!, frameID: 2, ptsNs: 200)
        wrapper = nil
        precondition(weakWrapper == nil, "Tracing must not retain frame buffers")
        weakWrapper = nil
        let next = NSObject()
        identityTrace.sourceSubmitted(buffer: next, frameID: 3, ptsNs: 300)
        precondition(identityTrace.snapshot().events.contains { $0.stage == .sourceUnmatched && $0.frameID == 2 })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try trace.write(to: directory)
        let file = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first!
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        let events = object["events"] as! [[String: Any]]
        precondition(events.count == 256)
        precondition(events.allSatisfy { Set($0.keys).isSubset(of: ["sequence", "uptimeNs", "stage", "ptsNs", "rtpTimestamp"]) })
        let incidentTrace = FrameTrace(capacity: 4, role: "receiver")
        for i in 0..<8 { incidentTrace.record(.decodeOutput, rtp: UInt32(i)) }
        precondition(incidentTrace.captureFirstIncident(reason: "test_freeze"))
        for i in 8..<20 { incidentTrace.record(.decodeOutput, rtp: UInt32(i)) }
        precondition(!incidentTrace.captureFirstIncident(reason: "must_not_replace"))
        let incidentDirectory = directory.appendingPathComponent("incident-test")
        try incidentTrace.write(to: incidentDirectory)
        let incidentFile = try FileManager.default.contentsOfDirectory(at: incidentDirectory.appendingPathComponent("incidents"), includingPropertiesForKeys: nil).first!
        let incident = try JSONSerialization.jsonObject(with: Data(contentsOf: incidentFile)) as! [String:Any]
        precondition(incident["reason"] as? String == "test_freeze")
        let frozen = incident["trace"] as! [String:Any]
        precondition((frozen["events"] as! [[String:Any]]).map { ($0["rtpTimestamp"] as! NSNumber).intValue } == [4,5,6,7], "First freeze survives later ring overwrites")
        print("FRAME_TRACE_TESTS_PASSED: concurrent bounded ring, overflow, generation isolation, metadata export")
    }
}
