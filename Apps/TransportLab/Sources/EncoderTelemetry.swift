import Foundation
import WebRTC

struct EncoderSample: Codable {
    var submittedFrames = 0
    var encodedFrames = 0
    var submissionErrors = 0
    var requestedFPS: UInt32 = 0
    var encodedBytes = 0
    var keyframes = 0
    var targetMbps: Double = 0
    var frameBytesP95: Int?
    var frameBytesMax: Int?
    var qpMaximum: Int?
    var qpLatest: Int?
    var callbackRejected = 0
    var callbackMillisecondsP95: Double?
    var unmatchedInputs = 0
    var unmatchedExpired = 0
}

/// Bounded per-frame observations, independently measured around the encoder callback.
final class EncoderTelemetry {
    private let lock = NSLock()
    private var state = EncoderSample()
    private var submitted: [UInt32: Double] = [:]
    private var sizes: [Int] = [], times: [Double] = []
    func begin(_ frame: RTCVideoFrame) {
        lock.lock(); defer { lock.unlock() }
        state.submittedFrames += 1
        let now = ProcessInfo.processInfo.systemUptime
        let expired = submitted.filter { now - $0.value >= 2 }.map(\.key)
        state.unmatchedExpired += expired.count
        expired.forEach { submitted.removeValue(forKey: $0) }
        if submitted.count < 120 { submitted[UInt32(bitPattern: frame.timeStamp)] = now }
    }
    func output(_ frame: RTCEncodedImage) {
        lock.lock(); defer { lock.unlock() }
        state.encodedFrames += 1; state.encodedBytes += frame.buffer.count
        if frame.frameType == .videoFrameKey { state.keyframes += 1 }
        if let time = submitted.removeValue(forKey: frame.timeStamp) {
            times.append((ProcessInfo.processInfo.systemUptime - time) * 1000)
        }
        let qp = frame.qp.intValue
        if qp >= 0 { state.qpMaximum = max(state.qpMaximum ?? qp, qp); state.qpLatest = qp }
        sizes.append(frame.buffer.count)
        if sizes.count > 240 { sizes.removeFirst(sizes.count - 240) }
        if times.count > 240 { times.removeFirst(times.count - 240) }
    }
    func rejectedCallback() { lock.lock(); state.callbackRejected += 1; lock.unlock() }
    func rate(_ kbps: UInt32) { lock.lock(); state.targetMbps = Double(kbps) / 1000; lock.unlock() }
    func fps(_ fps: UInt32) { lock.lock(); state.requestedFPS = fps; lock.unlock() }
    func failedSubmission(_ frame: RTCVideoFrame) {
        lock.lock(); state.submissionErrors += 1
        submitted.removeValue(forKey: UInt32(bitPattern: frame.timeStamp)); lock.unlock()
    }
    func snapshot() -> EncoderSample {
        lock.lock(); defer { lock.unlock() }
        var result = state
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
            if !accepted { self.telemetry.rejectedCallback() }
            return accepted
        }
    }
    func startEncode(with settings: RTCVideoEncoderSettings, numberOfCores: Int32) -> Int {
        telemetry.rate(settings.startBitrate)
        telemetry.fps(settings.maxFramerate)
        return native.startEncode(with: settings, numberOfCores: numberOfCores)
    }
    func release() -> Int { native.release() }
    func encode(_ frame: RTCVideoFrame, codecSpecificInfo info: (any RTCCodecSpecificInfo)?, frameTypes: [NSNumber]) -> Int {
        telemetry.begin(frame)
        let result = native.encode(frame, codecSpecificInfo: info, frameTypes: frameTypes)
        if result != 0 { telemetry.failedSubmission(frame) }
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
