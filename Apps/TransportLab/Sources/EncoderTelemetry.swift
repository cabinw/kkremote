import Foundation
import WebRTC

struct EncoderSample: Codable {
    var submittedFrames = 0
    var encodedFrames = 0
    var submissionErrors = 0
    var requestedFPS: UInt32 = 0
    var encodedBytes = 0
    var keyframes = 0
    var maximumKeyframeIntervalFrames: Int?
    var configuredMaximumFrameQP: Int?
    var targetMbps: Double = 0
    var frameBytesP95: Int?
    var frameBytesMax: Int?
    var qpMaximum: Int?
    var qpLatest: Int?
    var callbackRejected = 0
    var callbackMillisecondsP95: Double?
    var unmatchedInputs = 0
    var unmatchedExpired = 0
    var trackingOverflow = 0
    var timestampCollisions = 0
    var resetPendingUnknown = 0
    var outputWithoutInput = 0
    var asyncFailures: [String: Int] = [:]
    var lastAsyncStatus: Int?
    var trace: FrameTrace.Summary?
}

/// Bounded per-frame observations, independently measured around the encoder callback.
final class EncoderTelemetry {
    private let lock = NSLock()
    private var state = EncoderSample()
    private struct Input { let time: Double; let ptsNs: Int64; let frameID: UInt64?; var ambiguous = false }
    private var submitted: [UInt32: Input] = [:]
    private var sizes: [Int] = [], times: [Double] = []
    private let clock: () -> Double
    let trace: FrameTrace?
    init(trace: FrameTrace? = nil, clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.trace = trace; self.clock = clock
    }
    private func expire(_ now: Double) {
        let expired = submitted.filter { now - $0.value.time >= 2 }.map(\.key)
        state.unmatchedExpired += expired.count
        for timestamp in expired {
            let input = submitted.removeValue(forKey: timestamp)
            trace?.record(.encodeUnmatched, frameID: input?.frameID, ptsNs: input?.ptsNs, rtp: timestamp, reason: "timeout_unknown")
        }
    }
    func begin(_ frame: RTCVideoFrame) {
        lock.lock(); defer { lock.unlock() }
        state.submittedFrames += 1
        let now = clock()
        expire(now)
        let timestamp = UInt32(bitPattern: frame.timeStamp)
        let frameID = trace?.encoderSubmitted(buffer: frame.buffer, ptsNs: frame.timeStampNs, rtp: timestamp)
        if var old = submitted[timestamp] {
            state.timestampCollisions += 1
            trace?.record(.encodeUnmatched, frameID: old.frameID, ptsNs: old.ptsNs, rtp: timestamp, reason: "timestamp_collision_unknown")
            // Keep a bounded tombstone until expiry; even a third reuse must not claim an older callback.
            old.ambiguous = true; submitted[timestamp] = old
            return
        }
        if submitted.count < 120 { submitted[timestamp] = Input(time: now, ptsNs: frame.timeStampNs, frameID: frameID) }
        else {
            state.trackingOverflow += 1
            trace?.record(.encodeUnmatched, ptsNs: frame.timeStampNs, rtp: timestamp, reason: "tracking_capacity_unknown")
        }
    }
    func output(_ frame: RTCEncodedImage) {
        lock.lock(); defer { lock.unlock() }
        state.encodedFrames += 1; state.encodedBytes += frame.buffer.count
        if frame.frameType == .videoFrameKey { state.keyframes += 1 }
        let input = takeInput(frame.timeStamp)
        if let input { times.append((clock() - input.time) * 1000) }
        else { state.outputWithoutInput += 1 }
        trace?.record(.encodeOutput, frameID: input?.frameID, ptsNs: input?.ptsNs, rtp: frame.timeStamp, bytes: frame.buffer.count,
            reason: frame.frameType == .videoFrameKey ? "key" : "delta")
        let qp = frame.qp.intValue
        if qp >= 0 { state.qpMaximum = max(state.qpMaximum ?? qp, qp); state.qpLatest = qp }
        sizes.append(frame.buffer.count)
        if sizes.count > 240 { sizes.removeFirst(sizes.count - 240) }
        if times.count > 240 { times.removeFirst(times.count - 240) }
    }
    func rejectedCallback(_ frame: RTCEncodedImage) {
        lock.lock(); state.callbackRejected += 1; lock.unlock()
        trace?.record(.encodeCallbackRejected, rtp: frame.timeStamp)
    }
    func rate(_ kbps: UInt32) { lock.lock(); state.targetMbps = Double(kbps) / 1000; lock.unlock() }
    func keyframeInterval(_ frames: Int) { lock.lock(); state.maximumKeyframeIntervalFrames = frames; lock.unlock() }
    func qualityLimit(_ qp: Int?) { lock.lock(); state.configuredMaximumFrameQP=qp; lock.unlock() }
    func fps(_ fps: UInt32) { lock.lock(); state.requestedFPS = fps; lock.unlock() }
    func failedSubmission(_ frame: RTCVideoFrame, status: Int) {
        lock.lock(); state.submissionErrors += 1
        let input = takeInput(UInt32(bitPattern: frame.timeStamp)); lock.unlock()
        trace?.record(.encodeFailure, frameID: input?.frameID, ptsNs: frame.timeStampNs, rtp: UInt32(bitPattern: frame.timeStamp), reason: "submission", status: status)
    }
    func failedOutput(timestamp: UInt32, reason: String, status: Int? = nil) {
        lock.lock(); defer { lock.unlock() }
        state.asyncFailures[reason, default: 0] += 1
        if let status { state.lastAsyncStatus = status }
        let input = takeInput(timestamp)
        trace?.record(.encodeFailure, frameID: input?.frameID, ptsNs: input?.ptsNs, rtp: timestamp, reason: reason, status: status)
    }
    private func takeInput(_ timestamp: UInt32) -> Input? {
        guard submitted[timestamp]?.ambiguous != true else { return nil }
        return submitted.removeValue(forKey: timestamp)
    }
    func reset() {
        lock.lock(); defer { lock.unlock() }
        state.resetPendingUnknown += submitted.count
        for (timestamp, input) in submitted {
            trace?.record(.encodeUnmatched, frameID: input.frameID, ptsNs: input.ptsNs, rtp: timestamp, reason: "reset_unknown")
        }
        submitted.removeAll(keepingCapacity: true)
        trace?.record(.encoderReset)
    }
    func snapshot() -> EncoderSample {
        lock.lock(); defer { lock.unlock() }
        expire(clock())
        var result = state
        result.trace = trace?.summary()
        result.unmatchedInputs = submitted.count
        if !sizes.isEmpty { result.frameBytesP95 = sizes.sorted()[Int(ceil(Double(sizes.count) * 0.95)) - 1]; result.frameBytesMax = sizes.max() }
        if !times.isEmpty { result.callbackMillisecondsP95 = times.sorted()[Int(ceil(Double(times.count) * 0.95)) - 1] }
        sizes.removeAll(keepingCapacity: true); times.removeAll(keepingCapacity: true)
        return result
    }
}

/// Transparent native-encoder observations; never discard encoded reference frames.
final class MeasuredH264Encoder: NSObject, RTCVideoEncoder {
    private let native: any RTCVideoEncoder
    private let telemetry: EncoderTelemetry
    init(native: any RTCVideoEncoder, telemetry: EncoderTelemetry) {
        self.native = native; self.telemetry = telemetry
    }
    func setCallback(_ callback: RTCVideoEncoderCallback?) {
        native.setCallback { [weak self] frame, info in
            guard let self else { return false }
            self.telemetry.output(frame)
            let accepted = callback?(frame, info) ?? false
            if !accepted { self.telemetry.rejectedCallback(frame) }
            return accepted
        }
    }
    func startEncode(with settings: RTCVideoEncoderSettings, numberOfCores: Int32) -> Int {
        telemetry.rate(settings.startBitrate)
        telemetry.fps(settings.maxFramerate)
        return native.startEncode(with: settings, numberOfCores: numberOfCores)
    }
    func release() -> Int { let result = native.release(); telemetry.reset(); return result }
    func encode(_ frame: RTCVideoFrame, codecSpecificInfo info: (any RTCCodecSpecificInfo)?, frameTypes: [NSNumber]) -> Int {
        telemetry.begin(frame)
        let result = native.encode(frame, codecSpecificInfo: info, frameTypes: frameTypes)
        if result != 0 { telemetry.failedSubmission(frame, status: result) }
        return result
    }
    func setBitrate(_ bitrateKbit: UInt32, framerate: UInt32) -> Int32 {
        telemetry.rate(bitrateKbit)
        telemetry.fps(framerate)
        return native.setBitrate(bitrateKbit, framerate: framerate)
    }
    func implementationName() -> String { native.implementationName() }
    func scalingSettings() -> RTCVideoEncoderQpThresholds? { native.scalingSettings() }
    var resolutionAlignment: Int { native.resolutionAlignment }
    var applyAlignmentToAllSimulcastLayers: Bool { native.applyAlignmentToAllSimulcastLayers }
    var supportsNativeHandle: Bool { native.supportsNativeHandle }
}
