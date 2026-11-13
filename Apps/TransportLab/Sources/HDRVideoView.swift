import SwiftUI
import AVFoundation
import WebRTC

/// Delivers only the latest decoded buffer to the system's color-managed video layer.
/// PQ/primaries/range are taken from the decoder's pixel-buffer attachments, never invented here.
final class SampleBufferRenderer: NSObject, RTCVideoRenderer {
    let layer = AVSampleBufferDisplayLayer()
    var track: RTCVideoTrack?
    private let lock = NSLock()
    private var latest: RTCVideoFrame?
    private var scheduled = false
    private var stopped = false
    private var received = 0, enqueued = 0, replaced = 0, backpressureDrops = 0, failures = 0
    override init() {
        super.init()
        layer.videoGravity = .resizeAspect
    }
    func bind(_ next: RTCVideoTrack) {
        guard track !== next else { return }
        lock.lock(); latest = nil; lock.unlock()
        layer.sampleBufferRenderer.flush()
        track?.remove(self); track = next; next.add(self)
    }
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        received += 1
        if latest != nil { replaced += 1 }
        latest = frame
        let enqueue = !scheduled; scheduled = true
        lock.unlock()
        if enqueue { DispatchQueue.main.async { [weak self] in self?.displayLatest() } }
    }
    private func displayLatest() {
        lock.lock(); let frame = stopped ? nil : latest; latest = nil; scheduled = false; lock.unlock()
        guard let frame, let native = frame.buffer as? RTCCVPixelBuffer else { return }
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed { lock.lock(); failures += 1; lock.unlock(); renderer.flush() }
        guard renderer.isReadyForMoreMediaData else { lock.lock(); backpressureDrops += 1; lock.unlock(); return }
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: native.pixelBuffer,
            formatDescriptionOut: &format) == noErr, let format else { return }
        // WebRTC already applies its playout jitter buffer. Avoid a second timestamp-driven queue.
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: native.pixelBuffer,
            formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary] {
            attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        renderer.enqueue(sample)
        lock.lock(); enqueued += 1; lock.unlock()
    }
    func snapshot() -> [String: Int] {
        lock.lock(); defer { lock.unlock() }
        return ["received": received, "enqueued": enqueued, "replaced": replaced, "backpressureDrops": backpressureDrops, "displayFailures": failures]
    }
    func stop() {
        lock.lock(); stopped = true; latest = nil; lock.unlock()
        track?.remove(self); track = nil; layer.sampleBufferRenderer.flush()
    }
}

#if os(macOS)
final class VideoSurface: NSView {
    let videoLayer: AVSampleBufferDisplayLayer
    init(renderer: SampleBufferRenderer) {
        videoLayer = renderer.layer; super.init(frame: .zero)
        wantsLayer = true; layer?.backgroundColor = NSColor.black.cgColor; layer?.addSublayer(videoLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func layout() { super.layout(); CATransaction.begin(); CATransaction.setDisableActions(true); videoLayer.frame = bounds; CATransaction.commit() }
}
struct ColorManagedVideo: NSViewRepresentable {
    let track: RTCVideoTrack
    func makeCoordinator() -> SampleBufferRenderer { SampleBufferRenderer() }
    func makeNSView(context: Context) -> VideoSurface { context.coordinator.bind(track); return VideoSurface(renderer: context.coordinator) }
    func updateNSView(_ view: VideoSurface, context: Context) { context.coordinator.bind(track) }
    static func dismantleNSView(_ view: VideoSurface, coordinator: SampleBufferRenderer) { coordinator.stop() }
}
#else
final class VideoSurface: UIView {
    let videoLayer: AVSampleBufferDisplayLayer
    init(renderer: SampleBufferRenderer) {
        videoLayer = renderer.layer; super.init(frame: .zero)
        backgroundColor = .black; layer.addSublayer(videoLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func layoutSubviews() { super.layoutSubviews(); CATransaction.begin(); CATransaction.setDisableActions(true); videoLayer.frame = bounds; CATransaction.commit() }
}
struct ColorManagedVideo: UIViewRepresentable {
    let track: RTCVideoTrack
    func makeCoordinator() -> SampleBufferRenderer { SampleBufferRenderer() }
    func makeUIView(context: Context) -> VideoSurface { context.coordinator.bind(track); return VideoSurface(renderer: context.coordinator) }
    func updateUIView(_ view: VideoSurface, context: Context) { context.coordinator.bind(track) }
    static func dismantleUIView(_ view: VideoSurface, coordinator: SampleBufferRenderer) { coordinator.stop() }
}
#endif
