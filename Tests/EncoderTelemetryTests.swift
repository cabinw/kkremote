import Foundation
import CoreVideo
import WebRTC

@main struct EncoderTelemetryTests {
    static func main() {
        var now = 0.0
        let trace = FrameTrace(), telemetry = EncoderTelemetry(trace: trace, clock: { now })
        telemetry.keyframeInterval(600)
        precondition(telemetry.snapshot().maximumKeyframeIntervalFrames == 600)
        var pixelBuffer: CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &pixelBuffer) == 0)
        func frame(_ stamp: UInt32) -> RTCVideoFrame {
            let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixelBuffer!), rotation: ._0, timeStampNs: Int64(stamp) * 1000)
            frame.timeStamp = Int32(bitPattern: stamp)
            return frame
        }
        let first = frame(UInt32.max)
        trace.sourceSubmitted(buffer: first.buffer, frameID: 1, ptsNs: first.timeStampNs)
        telemetry.begin(first)
        now = 0.006
        let output = RTCEncodedImage(); output.timeStamp = UInt32.max; output.buffer = Data(count: 100); output.qp = 20
        telemetry.output(output)
        precondition(telemetry.snapshot().callbackMillisecondsP95 == 6)
        telemetry.begin(frame(0)) // 32-bit wrap must not be interpreted as an older frame.
        telemetry.failedOutput(timestamp: 0, reason: "vt_frame_dropped")
        telemetry.begin(frame(1500))
        telemetry.failedOutput(timestamp: 1500, reason: "vt_async_status", status: -12902)
        telemetry.begin(frame(3000)); telemetry.failedSubmission(frame(3000), status: -1)
        telemetry.begin(frame(4500))
        now = 3
        let sample = telemetry.snapshot()
        precondition(sample.unmatchedInputs == 0 && sample.unmatchedExpired == 1)
        precondition(sample.asyncFailures == ["vt_frame_dropped": 1, "vt_async_status": 1])
        precondition(sample.submissionErrors == 1 && sample.lastAsyncStatus == -12902)
        precondition(sample.encodedFrames == 1 && sample.outputWithoutInput == 0)
        precondition(trace.snapshot().events.contains { $0.stage == .encodeUnmatched && $0.reason == "timeout_unknown" })
        precondition(trace.snapshot().events.contains { $0.stage == .encodeOutput && $0.frameID == 1 })
        for n in 0..<121 { telemetry.begin(frame(UInt32(10_000 + n))) }
        precondition(telemetry.snapshot().unmatchedInputs == 120 && telemetry.snapshot().trackingOverflow == 1)
        telemetry.reset()
        precondition(telemetry.snapshot().resetPendingUnknown == 120 && telemetry.snapshot().unmatchedInputs == 0)
        let collision = EncoderTelemetry(clock: { now })
        collision.begin(frame(10)); collision.begin(frame(10))
        output.timeStamp = 10; collision.output(output)
        collision.begin(frame(10)); collision.output(output); collision.output(output)
        precondition(collision.snapshot().timestampCollisions == 2)
        precondition(collision.snapshot().outputWithoutInput == 3 && collision.snapshot().callbackMillisecondsP95 == nil,
            "In-flight timestamp reuse must never assign a callback to the wrong source frame")
        print("ENCODER_TELEMETRY_TESTS_PASSED: wrap, explicit async/sync failures, unknown timeout, pending bounds, reset")
    }
}
