import SwiftUI
import AVFoundation
import WebRTC

/// One bounded latest-frame slot per view. enqueue is an API submission, never a display timestamp.
final class SampleBufferRenderer: NSObject, RTCVideoRenderer, PresentationObserver {
    let layer = AVSampleBufferDisplayLayer()
    private(set) var track: RTCVideoTrack?
    private let lock = NSLock()
    private let schedule: (@escaping () -> Void) -> Void
    // Updated by the owning surface during layout; conversion runs on the main queue.
    var targetPixelSize: CGSize?
    private var surfacePixelRect:CGRect?
    func recordSurface(pixelRect:CGRect?) {
        lock.lock();surfacePixelRect=pixelRect;lock.unlock()
    }
    private let imageTransform:((CVPixelBuffer,CGSize?)->CVPixelBuffer?)?
    private struct Pending {
        let frame: RTCVideoFrame
        let arrivalNs: UInt64
        let telemetry: ReceiverTelemetry?
        let observerID: String
    }
    private final class Binding: NSObject, RTCVideoRenderer {
        weak var owner: SampleBufferRenderer?
        let generation: UInt64
        let telemetry: ReceiverTelemetry?
        let observerID: String
        init(_ owner: SampleBufferRenderer, _ generation: UInt64, _ telemetry: ReceiverTelemetry?, _ observerID: String) {
            self.owner = owner; self.generation = generation; self.telemetry = telemetry; self.observerID = observerID
        }
        func setSize(_ size: CGSize) {}
        func renderFrame(_ frame: RTCVideoFrame?) {
            owner?.receive(frame, generation: generation, telemetry: telemetry, observerID: observerID)
        }
    }
    private var binding: Binding?
    private var generation: UInt64 = 0
    private var latest: Pending?
    private var scheduled = false, stopped = false
    private var telemetry: ReceiverTelemetry?
    private var state = PresentationSample(observerID: UUID().uuidString)
    private var waits: [Double] = []
    var diagnosticOwner: ReceiverTelemetry? { lock.lock(); defer { lock.unlock() }; return telemetry }
    init(telemetry: ReceiverTelemetry? = nil, schedule: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }, imageTransform:((CVPixelBuffer,CGSize?)->CVPixelBuffer?)? = nil) {
        self.imageTransform=imageTransform
        self.telemetry = telemetry; self.schedule = schedule
        super.init(); layer.videoGravity = .resizeAspect
        telemetry?.addPresentation(self)
    }
    func bind(_ next: RTCVideoTrack) {
        guard track !== next else { return }
        if let binding { track?.remove(binding) }
        let context = PresentationDiagnostics.lookup(next)
        lock.lock()
        if let latest { record(.displayDrop, latest, reason: "rebind_pending"); state.cancelled += 1 }
        telemetry?.trace?.record(.displayStop, reason: "rebind", observerID: state.observerID)
        generation += 1; latest = nil; scheduled = false; stopped = false
        telemetry = context; state = PresentationSample(observerID: UUID().uuidString); waits.removeAll()
        let proxy = Binding(self, generation, context, state.observerID)
        context?.trace?.record(.displayBind, observerID: state.observerID)
        lock.unlock()
        layer.sampleBufferRenderer.flush()
        context?.addPresentation(self)
        binding = proxy; track = next; next.add(proxy)
    }
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) {
        lock.lock(); let token = generation, context = telemetry, id = state.observerID; lock.unlock()
        receive(frame, generation: token, telemetry: context, observerID: id)
    }
    private func receive(_ frame: RTCVideoFrame?, generation token: UInt64, telemetry context: ReceiverTelemetry?, observerID: String) {
        guard let frame else { return }
        let item = Pending(frame: frame, arrivalNs: DispatchTime.now().uptimeNanoseconds, telemetry: context, observerID: observerID)
        lock.lock()
        record(.displayInput, item, at: item.arrivalNs)
        guard !stopped, generation == token else {
            state.staleCallbacks += 1; record(.displayDrop, item, reason: "stale_binding_or_stopped"); lock.unlock(); return
        }
        state.received += 1
        if let old = latest { state.replaced += 1; record(.displayDrop, old, reason: "latest_replaced") }
        latest = item
        let needsSchedule = !scheduled; scheduled = true
        lock.unlock()
        if needsSchedule { schedule { [weak self] in self?.displayLatest(generation: token) } }
    }
    private func record(_ stage: FrameTrace.Stage, _ item: Pending, reason: String? = nil, status: Int? = nil, at: UInt64? = nil) {
        item.telemetry?.trace?.record(stage, ptsNs: item.frame.timeStampNs, rtp: UInt32(bitPattern: item.frame.timeStamp),
                                      reason: reason, status: status, observerID: item.observerID, at: at)
    }
    private func displayLatest(generation token: UInt64) {
        lock.lock()
        guard !stopped, generation == token else { lock.unlock(); return }
        let item = latest; latest = nil; scheduled = false
        if let item {
            let now = DispatchTime.now().uptimeNanoseconds
            waits.append(Double(now - item.arrivalNs) / 1e6)
            if waits.count > 600 { waits.removeFirst(waits.count - 600) }
            record(.displayMainDequeue, item, at: now)
        }
        lock.unlock()
        guard let item else { return }
        func drop(_ reason: String, _ status: Int? = nil) {
            lock.lock(); state.failures += 1; lock.unlock()
            record(.displayDrop, item, reason: reason, status: status)
        }
        guard let native = item.frame.buffer as? RTCCVPixelBuffer else { drop("unsupported_frame_buffer"); return }
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed {
            lock.lock(); state.failures += 1; lock.unlock()
            record(.displayFailure, item, reason: "display_layer_failed_flush", status: (renderer.error as NSError?)?.code)
            renderer.flush()
        }
        guard renderer.isReadyForMoreMediaData else {
            lock.lock(); state.backpressureDrops += 1; lock.unlock()
            record(.displayDrop, item, reason: "display_backpressure"); return
        }
        var format: CMVideoFormatDescription?
        let displayBuffer:CVPixelBuffer
        if let imageTransform {
            guard let converted=imageTransform(native.pixelBuffer,targetPixelSize) else { drop("display_conversion_unavailable");return }
            displayBuffer=converted
        } else { displayBuffer=native.pixelBuffer }
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: displayBuffer, formatDescriptionOut: &format)
        guard formatStatus == noErr, let format else { drop("display_format_create", Int(formatStatus)); return }
        // WebRTC owns playout scheduling; do not introduce a second timestamp-driven queue.
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: displayBuffer,
            formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
        guard sampleStatus == noErr, let sample else { drop("display_sample_create", Int(sampleStatus)); return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary] {
            attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        renderer.enqueue(sample)
        record(.displayEnqueue, item, reason: "api_submission_not_presentation")
        lock.lock(); state.enqueued += 1;state.outputWidth=CVPixelBufferGetWidth(displayBuffer);state.outputHeight=CVPixelBufferGetHeight(displayBuffer); lock.unlock()
    }
    func diagnosticSnapshot() -> PresentationSample {
        lock.lock(); defer { lock.unlock() }
        var result = state; result.active = !stopped; result.pending = latest == nil ? 0 : 1
        if let r=surfacePixelRect {
            result.surfacePixelX=r.minX;result.surfacePixelY=r.minY
            result.surfacePixelWidth=r.width;result.surfacePixelHeight=r.height
            if let w=result.outputWidth,let h=result.outputHeight {
                result.pixelOneToOne=abs(r.width-Double(w))<0.001 && abs(r.height-Double(h))<0.001 &&
                    abs(r.minX-r.minX.rounded())<0.001 && abs(r.minY-r.minY.rounded())<0.001
            }
        }
        if !waits.isEmpty {
            result.mainQueueWaitMillisecondsP95 = waits.sorted()[Int(ceil(Double(waits.count) * 0.95)) - 1]
            result.mainQueueWaitMillisecondsMax = waits.max()
        }
        return result
    }
    func snapshot() -> [String: Int] {
        let value = diagnosticSnapshot()
        return ["received": value.received, "enqueued": value.enqueued, "replaced": value.replaced,
                "backpressureDrops": value.backpressureDrops, "displayFailures": value.failures]
    }
    func endMedia() { stop() }
    func stop() {
        lock.lock()
        if stopped { lock.unlock(); return }
        stopped = true; generation += 1
        if let latest { record(.displayDrop, latest, reason: "media_stop_pending"); state.cancelled += 1 }
        latest = nil; scheduled = false
        telemetry?.trace?.record(.displayStop, reason: "media_stop", observerID: state.observerID)
        lock.unlock()
        if let binding { track?.remove(binding) }; binding = nil; track = nil
        layer.sampleBufferRenderer.flush()
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
    private let renderer:SampleBufferRenderer
    init(renderer: SampleBufferRenderer, desktopColors:Bool = false) {
        self.renderer=renderer;videoLayer = renderer.layer; super.init(frame: .zero)
        // Explicitly request the same HDR display range for native video and
        // the sampled window edge; this does not change source pixel values.
        if #available(iOS 26.0, *) {
            videoLayer.preferredDynamicRange = desktopColors ? .standard : .high
        } else {
            videoLayer.wantsExtendedDynamicRangeContent = !desktopColors
        }
        backgroundColor = .black; layer.addSublayer(videoLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func didMoveToWindow() {super.didMoveToWindow();setNeedsLayout()}
    override func layoutSubviews() {
        super.layoutSubviews()
        let scale=window?.screen.scale ?? traitCollection.displayScale
        renderer.targetPixelSize=CGSize(width:bounds.width*scale,height:bounds.height*scale)
        CATransaction.begin();CATransaction.setDisableActions(true)
        videoLayer.contentsScale=scale;videoLayer.frame=bounds;CATransaction.commit()
        if window != nil {
            let actual=convert(videoLayer.frame,to:nil)
            renderer.recordSurface(pixelRect:CGRect(x:actual.minX*scale,y:actual.minY*scale,width:actual.width*scale,height:actual.height*scale))
        } else {renderer.recordSurface(pixelRect:nil)}
    }
}
struct ColorManagedVideo: UIViewRepresentable {
    let track: RTCVideoTrack
    var desktopColors=false
    func makeCoordinator() -> SampleBufferRenderer {
        SampleBufferRenderer(imageTransform:desktopColors ? DesktopVideoColor().convert : nil)
    }
    func makeUIView(context: Context) -> VideoSurface { context.coordinator.bind(track); return VideoSurface(renderer: context.coordinator,desktopColors:desktopColors) }
    func updateUIView(_ view: VideoSurface, context: Context) { context.coordinator.bind(track) }
    static func dismantleUIView(_ view: VideoSurface, coordinator: SampleBufferRenderer) { coordinator.stop() }
}
#endif
