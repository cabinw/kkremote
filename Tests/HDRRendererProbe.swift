import AppKit
import AVFoundation
import WebRTC

@main struct HDRRendererProbe {
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let renderer = SampleBufferRenderer()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "KKRemote HDR renderer validation"
        window.contentView = VideoSurface(renderer: renderer)
        window.makeKeyAndOrderFront(nil)
        let decoder = HEVCDecoder()
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
    }
}
