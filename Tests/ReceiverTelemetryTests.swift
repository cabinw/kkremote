import AppKit
import WebRTC

@main struct ReceiverTelemetryTests {
    static func main() {
        _ = NSApplication.shared
        var now: UInt64 = 1_000_000_000
        let trace = FrameTrace(role: "receiver")
        let telemetry = ReceiverTelemetry(trace: trace, clock: { now })
        func input(_ timestamp: UInt32) -> RTCEncodedImage {
            let image = RTCEncodedImage(); image.timeStamp = timestamp; image.buffer = Data([1, 2, 3])
            return image
        }
        func frame(_ timestamp: UInt32) -> RTCVideoFrame {
            let value = RTCVideoFrame(buffer: RTCI420Buffer(width: 16, height: 16), rotation: ._0, timeStampNs: 0)
            value.timeStamp = Int32(bitPattern: timestamp); return value
        }
        telemetry.begin(input(UInt32.max)); now += 5_000_000; telemetry.output(frame(UInt32.max))
        precondition(telemetry.snapshot().decoderCallbackMillisecondsP95 == 5)
        telemetry.begin(input(1)); telemetry.begin(input(1)); telemetry.output(frame(1))
        precondition(telemetry.snapshot().timestampCollisions == 1 && telemetry.snapshot().unmatchedOutputs == 1)
        precondition(trace.snapshot().events.last?.frameID == nil, "Ambiguous RTP must not correlate")
        now += 2_000_000_001
        precondition(telemetry.snapshot().unknownExpired == 1 && telemetry.snapshot().pending == 0)
        for timestamp in 100..<221 { telemetry.begin(input(UInt32(timestamp))) }
        precondition(telemetry.snapshot().pending == 120 && telemetry.snapshot().trackingOverflow == 1)
        telemetry.reset()
        let invalidDecoder = MeasuredVideoDecoder(native: HEVCDecoder(telemetry: telemetry), telemetry: telemetry)
        precondition(invalidDecoder.decode(input(400), missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0) != 0)
        precondition(telemetry.snapshot().failures == ["hevc_annex_b_invalid": 1], "Do not double count native errors")

        var scheduled: [() -> Void] = []
        let renderer = SampleBufferRenderer(telemetry: telemetry, schedule: { scheduled.append($0) })
        renderer.renderFrame(frame(500)); renderer.renderFrame(frame(501))
        precondition(scheduled.count == 1 && renderer.diagnosticSnapshot().replaced == 1)
        scheduled.removeFirst()()
        precondition(renderer.diagnosticSnapshot().failures == 1, "Only newest I420 frame reaches unsupported-buffer check")
        renderer.renderFrame(frame(502)); renderer.stop(); scheduled.removeFirst()()
        renderer.renderFrame(frame(503))
        let result = renderer.diagnosticSnapshot()
        precondition(result.cancelled == 1 && result.staleCallbacks == 1 && result.pending == 0)
        precondition(!trace.snapshot().events.contains { $0.stage == .displayEnqueue })
        precondition(trace.snapshot().events.filter { $0.stage == .displayMainDequeue }.map(\.rtpTimestamp) == [501])

        let factory = RTCPeerConnectionFactory()
        let first = factory.videoTrack(with: factory.videoSource(), trackId: "first")
        let second = factory.videoTrack(with: factory.videoSource(), trackId: "second")
        let oldContext = ReceiverTelemetry(), newContext = ReceiverTelemetry()
        PresentationDiagnostics.register(first, telemetry: oldContext)
        PresentationDiagnostics.register(second, telemetry: newContext)
        renderer.bind(first); renderer.renderFrame(frame(600))
        renderer.bind(second); renderer.renderFrame(frame(601))
        oldContext.endPresentations()
        precondition(renderer.diagnosticSnapshot().active, "Old media generation must not stop rebound view")
        scheduled.removeFirst()() // Old generation closure must not drain new generation.
        precondition(renderer.diagnosticSnapshot().pending == 1)
        scheduled.removeFirst()()
        precondition(renderer.diagnosticSnapshot().pending == 0 && renderer.diagnosticSnapshot().failures == 1)
        newContext.endPresentations()
        precondition(!renderer.diagnosticSnapshot().active)
        PresentationDiagnostics.remove(first); PresentationDiagnostics.remove(second)
        print("RECEIVER_TRACE_TESTS_PASSED: RTP wrap/collision/timeout/bounds, native error, latest slot, stop/rebind isolation")
    }
}
