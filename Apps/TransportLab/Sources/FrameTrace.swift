import Foundation

/// Metadata only. Each instance belongs to exactly one PeerEngine/media generation/source.
/// No pixel buffers, packet payloads, SDP, endpoint, window identity or pairing material.
final class FrameTrace {
    private static let clockDomain = UUID().uuidString
    private static let pendingShutdowns = DispatchGroup()
    static var awaitingShutdown: Bool { pendingShutdowns.wait(timeout: .now()) != .success }
    func beginShutdown() { Self.pendingShutdowns.enter() }
    func endShutdown() { Self.pendingShutdowns.leave() }
    enum Stage: String, Codable {
        case capture, sourceSubmit, sourceSkip, encodeSubmit, encodeOutput, encodeFailure
        case encodeCallbackRejected, encodeUnmatched, sourceUnmatched, encoderReset, mediaStop, rendererCallback, sdkDrop
        case decodeSubmit, decodeOutput, decodeFailure, decodeUnknown, decodeVTSubmit, decodeVTOutput
        case displayInput, displayMainDequeue, displayEnqueue, displayDrop, displayFailure, displayBind, displayStop
    }
    struct Event: Codable {
        let sequence: UInt64
        let uptimeNs: UInt64
        let stage: Stage
        let frameID: UInt64?
        let ptsNs: Int64?
        let rtpTimestamp: UInt32?
        let bytes: Int?
        let reason: String?
        let status: Int?
        let observerID: String?
    }
    struct Summary: Codable {
        let epoch: String
        let capacity: Int
        let recorded: UInt64
        let overwritten: UInt64
        let retained: Int
    }
    struct Document: Encodable {
        let schemaVersion = 3
        let scope = "process-local monotonic clock; one media generation; enqueue/OS acceptance is not wire transmission or display"
        let role: String
        let clockDomain: String
        let probes: [String: Bool]
        let settings: [String: Int]
        let summary: Summary
        let events: [Event]
        let rtp: RTPTrace.Snapshot
    }
    private let lock = NSLock()
    private let exportQueue = DispatchQueue(label: "kkremote.frame-trace-export", qos: .utility)
    private let epoch = UUID().uuidString
    private var ring: [Event?]
    private var recorded: UInt64 = 0
    struct Incident: Encodable {
        let reason: String
        let detectedAtNs: UInt64
        let trace: Document
    }
    private var incidentCaptured = false
    private var firstIncident: Incident?
    let rtp = RTPTrace()
    private let role: String
    private let probes: [String: Bool]
    private let settings: [String: Int]
    private final class SourceIdentity {
        weak var buffer: AnyObject?
        let frameID: UInt64
        let ptsNs: Int64
        init(_ buffer: AnyObject, _ frameID: UInt64, _ ptsNs: Int64) {
            self.buffer = buffer; self.frameID = frameID; self.ptsNs = ptsNs
        }
    }
    // Weak wrapper identity: diagnostics must not retain scarce CVPixelBuffers or change pool pressure.
    private var sourceIdentities: [ObjectIdentifier: SourceIdentity] = [:]

    init(capacity: Int = 32_768, role: String = "sender", probes: [String: Bool] = [:], settings: [String: Int] = [:]) {
        precondition(capacity > 0)
        self.role = role
        self.probes = probes
        self.settings = settings
        ring = Array(repeating: nil, count: capacity)
    }

    func record(_ stage: Stage, frameID: UInt64? = nil, ptsNs: Int64? = nil,
                rtp: UInt32? = nil, bytes: Int? = nil, reason: String? = nil, status: Int? = nil,
                observerID: String? = nil,
                at uptimeNs: UInt64? = nil) {
        lock.lock(); defer { lock.unlock() }
        recordLocked(stage, frameID: frameID, ptsNs: ptsNs, rtp: rtp, bytes: bytes, reason: reason, status: status, observerID: observerID, at: uptimeNs)
    }
    private func recordLocked(_ stage: Stage, frameID: UInt64? = nil, ptsNs: Int64? = nil,
                             rtp: UInt32? = nil, bytes: Int? = nil, reason: String? = nil, status: Int? = nil,
                             observerID: String? = nil,
                             at uptimeNs: UInt64? = nil) {
        let event = Event(sequence: recorded, uptimeNs: uptimeNs ?? DispatchTime.now().uptimeNanoseconds,
            stage: stage, frameID: frameID, ptsNs: ptsNs, rtpTimestamp: rtp,
            bytes: bytes, reason: reason, status: status, observerID: observerID)
        ring[Int(recorded % UInt64(ring.count))] = event
        recorded += 1
    }
    func sourceSubmitted(buffer: AnyObject, frameID: UInt64, ptsNs: Int64) {
        lock.lock(); defer { lock.unlock() }
        let expired = sourceIdentities.filter { $0.value.buffer == nil }.map(\.key)
        for key in expired {
            if let old = sourceIdentities.removeValue(forKey: key) {
                recordLocked(.sourceUnmatched, frameID: old.frameID, ptsNs: old.ptsNs, reason: "released_before_encoder_unknown")
            }
        }
        let key = ObjectIdentifier(buffer)
        if let old = sourceIdentities.removeValue(forKey: key) {
            // Callers use a fresh RTC wrapper for each source frame. Reusing one cannot be correlated safely.
            recordLocked(.sourceUnmatched, frameID: old.frameID, ptsNs: old.ptsNs, reason: "wrapper_reused_unknown")
            recordLocked(.sourceUnmatched, frameID: frameID, ptsNs: ptsNs, reason: "wrapper_reused_unknown")
        } else if sourceIdentities.count < 120 {
            sourceIdentities[key] = SourceIdentity(buffer, frameID, ptsNs)
        } else {
            recordLocked(.sourceUnmatched, frameID: frameID, ptsNs: ptsNs, reason: "source_tracking_capacity_unknown")
        }
        recordLocked(.sourceSubmit, frameID: frameID, ptsNs: ptsNs)
    }
    func encoderSubmitted(buffer: AnyObject, ptsNs: Int64, rtp: UInt32) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        let input = sourceIdentities.removeValue(forKey: ObjectIdentifier(buffer))
        let matched = input?.buffer === buffer ? input : nil
        recordLocked(.encodeSubmit, frameID: matched?.frameID, ptsNs: ptsNs, rtp: rtp,
            reason: matched == nil ? "source_identity_unknown" : "exact_wrapper_identity")
        return matched?.frameID
    }
    private func summaryLocked() -> Summary {
        Summary(epoch: epoch, capacity: ring.count, recorded: recorded,
            overwritten: recorded > UInt64(ring.count) ? recorded - UInt64(ring.count) : 0,
            retained: Int(min(recorded, UInt64(ring.count))))
    }
    func summary() -> Summary { lock.lock(); defer { lock.unlock() }; return summaryLocked() }
    func snapshot() -> Document {
        lock.lock(); defer { lock.unlock() }
        let summary = summaryLocked()
        let first = recorded - UInt64(summary.retained)
        let events = (first..<recorded).compactMap { ring[Int($0 % UInt64(ring.count))] }
        return Document(role: role, clockDomain: Self.clockDomain, probes: probes, settings: settings, summary: summary, events: events, rtp: rtp.snapshot())
    }
    /// One bounded incident per media generation. Called by the stats observer,
    /// not a packet callback; no disk I/O while media is running.
    @discardableResult
    func captureFirstIncident(reason: String) -> Bool {
        lock.lock()
        guard !incidentCaptured else { lock.unlock(); return false }
        incidentCaptured = true
        lock.unlock()
        let incident = Incident(reason: reason, detectedAtNs: DispatchTime.now().uptimeNanoseconds, trace: snapshot())
        lock.lock(); firstIncident = incident; lock.unlock()
        return true
    }
    /// Explicit CLI export, after media stop. Encoding and I/O never run on a media callback.
    func write(to directory: URL) throws {
        let document = snapshot()
        lock.lock(); let incident = firstIncident; lock.unlock()
        // Drain this diagnostic write before CLI exit. An async item ensures I/O leaves the caller's thread.
        var result: Result<Void, Error>?
        let work = DispatchWorkItem {
            result = Result {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try encoder.encode(document).write(to: directory.appendingPathComponent("\(self.role)-\(self.epoch).json"), options: .atomic)
                if let incident {
                    let folder = directory.appendingPathComponent("incidents", isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try encoder.encode(incident).write(to: folder.appendingPathComponent("\(self.role)-\(self.epoch)-first-freeze.json"), options: .atomic)
                }
            }
        }
        exportQueue.async(execute: work)
        work.wait()
        try result!.get()
    }
}
