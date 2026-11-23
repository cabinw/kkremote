import AppKit
import AVFoundation
import WebRTC

@main struct HDRRendererProbe {
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let trace = FrameTrace(role: "receiver")
        let telemetry = ReceiverTelemetry(trace: trace)
        let renderer = SampleBufferRenderer(telemetry: telemetry)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "KKRemote HDR renderer validation"
        window.contentView = VideoSurface(renderer: renderer)
        window.makeKeyAndOrderFront(nil)
        let decoder = MeasuredVideoDecoder(native: HEVCDecoder(telemetry: telemetry), telemetry: telemetry)
        decoder.setCallback { renderer.renderFrame($0) }
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        for index in 0..<180 {
            let image = RTCEncodedImage(); image.buffer = data; image.timeStamp = UInt32(index * 1500)
            image.frameType = .videoFrameKey; image.encodedWidth = 2560; image.encodedHeight = 1440
            precondition(decoder.decode(image, missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0) == 0)
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60))
        }
        _ = decoder.release()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let stats = renderer.snapshot()
        let ready = renderer.layer.isReadyForDisplay
        print("HDR renderer ready=\(ready), headroom=\(window.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1), stats=\(stats)")
        renderer.stop(); window.orderOut(nil)
        precondition(ready && stats["enqueued", default: 0] >= 170 && stats["displayFailures"] == 0)
        let events = trace.snapshot().events
        let summary = telemetry.snapshot()
        precondition(summary.decoded == 180 && summary.failures.isEmpty && summary.unmatchedOutputs == 0)
        precondition(summary.pending == 0 && summary.unknownExpired == 0)
        for stage in [FrameTrace.Stage.decodeSubmit, .decodeVTSubmit, .decodeVTOutput, .decodeOutput] {
            precondition(events.filter { $0.stage == stage }.count == 180, "Missing decoder trace stage")
        }
        precondition(events.filter { $0.stage == .displayEnqueue }.count == stats["enqueued"])
        print("RECEIVER_TRACE_HARDWARE_PASSED: 180 Main10 frames, exact RTP matching, VT stages, display submission")
    }
}
