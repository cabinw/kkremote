import Foundation
import WebRTC

struct PresentationSample: Codable {
    let observerID: String
    var active = true
    var received = 0, enqueued = 0, replaced = 0, backpressureDrops = 0, failures = 0
    var staleCallbacks = 0, cancelled = 0, pending = 0
    var outputWidth: Int?
    var outputHeight: Int?
    /// Actual UIKit layer surface in physical window pixels, not buffer size.
    var surfacePixelX: Double?
    var surfacePixelY: Double?
    var surfacePixelWidth: Double?
    var surfacePixelHeight: Double?
    var pixelOneToOne: Bool?
    var mainQueueWaitMillisecondsP95: Double?
    var mainQueueWaitMillisecondsMax: Double?
}

struct ReceiverSample: Codable {
    var submitted = 0, decoded = 0, pending = 0
    var failures: [String: Int] = [:]
    var unmatchedOutputs = 0, unknownExpired = 0, timestampCollisions = 0, trackingOverflow = 0
    var decoderCallbackMillisecondsP95: Double?
    var presentations: [PresentationSample] = []
}

protocol PresentationObserver: AnyObject {
    var diagnosticOwner: ReceiverTelemetry? { get }
    func diagnosticSnapshot() -> PresentationSample
    func endMedia()
}

/// Per media generation. RTP correlation is exact and bounded, never based on nearest time.
final class ReceiverTelemetry {
    let trace: FrameTrace?
    private let lock = NSLock()
    private let clock: () -> UInt64
    private struct Input { let id: UInt64; let at: UInt64; var ambiguous = false }
    private var pending: [UInt32: Input] = [:]
    private var sequence: UInt64 = 0
    private var state = ReceiverSample()
    private var callbacks: [Double] = []
    private final class WeakObserver {
        weak var value: (any PresentationObserver)?
        init(_ value: any PresentationObserver) { self.value = value }
    }
    private var observers: [WeakObserver] = []
    init(trace: FrameTrace? = nil, clock: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.trace = trace; self.clock = clock
    }
    private func expire(_ now: UInt64) {
        for timestamp in pending.filter({ now >= $0.value.at && now - $0.value.at > 2_000_000_000 }).map(\.key) {
            let old = pending.removeValue(forKey: timestamp)!
            state.unknownExpired += 1
            trace?.record(.decodeUnknown, frameID: old.id, rtp: timestamp, reason: "decode_timeout_unknown")
        }
    }
    func begin(_ image: RTCEncodedImage) {
        lock.lock(); defer { lock.unlock() }
        let now = clock(); expire(now); sequence += 1; state.submitted += 1
        trace?.record(.decodeSubmit, frameID: sequence, rtp: image.timeStamp, bytes: image.buffer.count,
                      reason: image.frameType == .videoFrameKey ? "key" : "delta", at: now)
        if var old = pending[image.timeStamp] {
            state.timestampCollisions += 1; old.ambiguous = true; pending[image.timeStamp] = old
            trace?.record(.decodeUnknown, frameID: old.id, rtp: image.timeStamp, reason: "decode_timestamp_collision_unknown")
        } else if pending.count < 120 {
            pending[image.timeStamp] = Input(id: sequence, at: now)
        } else {
            state.trackingOverflow += 1
            trace?.record(.decodeUnknown, frameID: sequence, rtp: image.timeStamp, reason: "decode_tracking_capacity_unknown")
        }
    }
    func vt(_ stage: FrameTrace.Stage, timestamp: UInt32, reason: String? = nil, status: Int? = nil) {
        lock.lock(); let input = pending[timestamp]; lock.unlock()
        trace?.record(stage, frameID: input?.ambiguous == false ? input?.id : nil, rtp: timestamp, reason: reason, status: status)
    }
    func output(_ frame: RTCVideoFrame) {
        let timestamp = UInt32(bitPattern: frame.timeStamp)
        lock.lock(); defer { lock.unlock() }
        let now = clock(); expire(now); state.decoded += 1
        let input = pending[timestamp]
        if input?.ambiguous == false { pending.removeValue(forKey: timestamp) }
        if let input, !input.ambiguous {
            callbacks.append(Double(now - input.at) / 1e6)
            if callbacks.count > 600 { callbacks.removeFirst(callbacks.count - 600) }
        } else { state.unmatchedOutputs += 1 }
        trace?.record(.decodeOutput, frameID: input?.ambiguous == false ? input?.id : nil, ptsNs: frame.timeStampNs,
                      rtp: timestamp, reason: input?.ambiguous == false ? "exact_rtp" : "decode_input_unknown", at: now)
    }
    func failed(_ timestamp: UInt32, reason: String, status: Int? = nil, onlyIfPending: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        let input = pending[timestamp]
        if onlyIfPending && input == nil { return } // Native HEVC already supplied the concrete failure.
        if input?.ambiguous == false { pending.removeValue(forKey: timestamp) }
        state.failures[reason, default: 0] += 1
        trace?.record(.decodeFailure, frameID: input?.ambiguous == false ? input?.id : nil,
                      rtp: timestamp, reason: reason, status: status)
    }
    func reset() {
        lock.lock(); defer { lock.unlock() }
        for (timestamp, input) in pending {
            state.unknownExpired += 1
            trace?.record(.decodeUnknown, frameID: input.id, rtp: timestamp, reason: "decoder_reset_unknown")
        }
        pending.removeAll()
    }
    func addPresentation(_ observer: any PresentationObserver) {
        lock.lock(); defer { lock.unlock() }
        observers.removeAll { $0.value == nil }
        if !observers.contains(where: { $0.value === observer }) { observers.append(WeakObserver(observer)) }
    }
    func endPresentations() {
        lock.lock(); let active = observers.compactMap(\.value); lock.unlock()
        active.filter { $0.diagnosticOwner === self }.forEach { $0.endMedia() } // Lifecycle is on main.
    }
    func snapshot() -> ReceiverSample {
        lock.lock(); expire(clock()); var result = state; result.pending = pending.count
        if !callbacks.isEmpty { result.decoderCallbackMillisecondsP95 = callbacks.sorted()[Int(ceil(Double(callbacks.count) * 0.95)) - 1] }
        let active = observers.compactMap(\.value); lock.unlock()
        result.presentations = active.filter { $0.diagnosticOwner === self }.map { $0.diagnosticSnapshot() }
        return result
    }
}

/// Allows the shared media view to discover diagnostics without changing the client UI API.
/// Keys are exact track objects, weakly held; track IDs or titles are not used or exported.
enum PresentationDiagnostics {
    private final class Entry {
        weak var track: RTCVideoTrack?
        weak var telemetry: ReceiverTelemetry?
        init(_ track: RTCVideoTrack, _ telemetry: ReceiverTelemetry) { self.track = track; self.telemetry = telemetry }
    }
    private static let lock = NSLock()
    private static var entries: [ObjectIdentifier: Entry] = [:]
    static func register(_ track: RTCVideoTrack, telemetry: ReceiverTelemetry) {
        lock.lock(); defer { lock.unlock() }
        entries = entries.filter { $0.value.track != nil && $0.value.telemetry != nil }
        entries[ObjectIdentifier(track)] = Entry(track, telemetry)
    }
    static func lookup(_ track: RTCVideoTrack) -> ReceiverTelemetry? {
        lock.lock(); defer { lock.unlock() }
        let entry = entries[ObjectIdentifier(track)]
        return entry?.track === track ? entry?.telemetry : nil
    }
    static func remove(_ track: RTCVideoTrack) {
        lock.lock(); entries.removeValue(forKey: ObjectIdentifier(track)); lock.unlock()
    }
}

final class MeasuredVideoDecoder: NSObject, RTCVideoDecoder {
    private let native: any RTCVideoDecoder
    private let telemetry: ReceiverTelemetry
    init(native: any RTCVideoDecoder, telemetry: ReceiverTelemetry) { self.native = native; self.telemetry = telemetry }
    func setCallback(_ callback: @escaping RTCVideoDecoderCallback) {
        native.setCallback { [telemetry] frame in telemetry.output(frame); callback(frame) }
    }
    func startDecode(withNumberOfCores numberOfCores: Int32) -> Int { native.startDecode(withNumberOfCores: numberOfCores) }
    func decode(_ image: RTCEncodedImage, missingFrames: Bool, codecSpecificInfo info: (any RTCCodecSpecificInfo)?, renderTimeMs: Int64) -> Int {
        telemetry.begin(image)
        let result = native.decode(image, missingFrames: missingFrames, codecSpecificInfo: info, renderTimeMs: renderTimeMs)
        if result != 0 { telemetry.failed(image.timeStamp, reason: "decoder_submission_rejected", status: result, onlyIfPending: true) }
        return result
    }
    func release() -> Int { let result = native.release(); telemetry.reset(); return result }
    func implementationName() -> String { native.implementationName() }
}
