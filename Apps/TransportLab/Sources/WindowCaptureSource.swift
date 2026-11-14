#if os(macOS)
import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreGraphics
import CoreImage
import WebRTC

struct CaptureWindow: Codable, Identifiable {
    let id: UInt32
    let application: String
    let title: String
    let widthPoints: Double
    let heightPoints: Double
}

/// One explicitly selected window. Closing it ends capture; we never fall back to a display.
/// Lifecycle runs on the main queue; delivery and diagnostic counters share a small lock.
final class WindowCaptureSource: NSObject, LabVideoSource, SCStreamOutput, SCStreamDelegate {
    // Explicit local CLI diagnostic only; never negotiated by the remote peer.
    static var diagnosticQueueDepth = 3
    private let source: RTCVideoSource
    private let capturer: RTCVideoCapturer
    private let preset: LabPreset
    private let windowID: UInt32
    private let expectedProcessID: Int32?
    private let hdr: Bool
    private let nativeWindowPixels: Bool
    private let viewport: WindowViewport?
    private let requiresNativeClientPixels:Bool
    private var pixelConverter: WindowTextPixelConverter?
    private let onFailure: (String) -> Void
    private let queue = DispatchQueue(label: "kkremote.window-capture", qos: .userInteractive)
    // SCStreamConfiguration.backgroundColor is unowned; retain it for the stream lifetime.
    private let backgroundColor = CGColor(gray: 0, alpha: 1)
    private let lock = NSLock()
    private var stream: SCStream?
    private var started = false
    private var stopped = false
    private var accepting = false
    private var counters = CaptureSample()
    private var lastTimestamp: Int64?
    private var lastCallback: Double?
    private var gaps: [Double] = []
    private var ages: [Double] = []
    private var conversionTimes: [Double] = []
    private let trace: FrameTrace?
    private var callbackID: UInt64 = 0

    init(source: RTCVideoSource, preset: LabPreset, windowID: UInt32, expectedProcessID: Int32? = nil, hdr: Bool = false, nativeWindowPixels: Bool = false, viewport: WindowViewport? = nil, requiresNativeClientPixels:Bool = false, trace: FrameTrace? = nil, onFailure: @escaping (String) -> Void) {
        self.nativeWindowPixels = nativeWindowPixels
        self.viewport=viewport
        self.requiresNativeClientPixels=requiresNativeClientPixels
        self.trace = trace
        self.source = source; self.preset = preset; self.windowID = windowID; self.hdr = hdr; self.onFailure = onFailure; self.expectedProcessID = expectedProcessID
        capturer = RTCVideoCapturer(delegate: source)
        super.init()
        source.adaptOutputFormat(toWidth: Int32(preset.width), height: Int32(preset.height), fps: Int32(preset.fps))
    }

    static func windows() async throws -> [CaptureWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        return content.windows.filter { $0.windowLayer == 0 && $0.frame.width > 100 && $0.frame.height > 100 }
            .map { CaptureWindow(id: $0.windowID, application: $0.owningApplication?.applicationName ?? "unknown",
                title: $0.title ?? "", widthPoints: $0.frame.width, heightPoints: $0.frame.height) }
            .sorted { $0.id < $1.id }
    }

    func start() {
        guard !started, !stopped else { return }
        started = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                guard !self.stopped else { return }
                guard let window = content.windows.first(where: { $0.windowID == self.windowID && (self.expectedProcessID == nil || $0.owningApplication?.processID == self.expectedProcessID) }) else {
                    throw LabError.message("选定窗口已关闭或不可捕获，请重新选择窗口")
                }
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let config = self.hdr ? SCStreamConfiguration(preset: .captureHDRStreamCanonicalDisplay) : SCStreamConfiguration()
                config.width = self.preset.width; config.height = self.preset.height
                if self.nativeWindowPixels,let pixels=MobileWindowSizing.capturePixels(for:filter.contentRect.size,
                    pointPixelScale:CGFloat(filter.pointPixelScale),maximumPixels:CGFloat(self.preset.width*self.preset.height)) {
                    config.captureResolution = .best
                    config.width=Int(pixels.width);config.height=Int(pixels.height)
                    self.source.adaptOutputFormat(toWidth:Int32(config.width),height:Int32(config.height),fps:Int32(self.preset.fps))
                    print("WINDOW_NATIVE_PIXELS source=\(filter.contentRect.size) scale=\(filter.pointPixelScale) canvas=\(config.width)x\(config.height)")
                }
                // Let WindowServer deliver at display cadence; RTCVideoSource caps output fps.
                // Throttling twice at exactly 1/60 can discard near-boundary display updates.
                config.minimumFrameInterval = .zero
                config.pixelFormat = self.hdr ? HDRFormat.pixelFormat : kCVPixelFormatType_32BGRA
                config.queueDepth = Self.diagnosticQueueDepth
                config.showsCursor = false; config.showMouseClicks = false
                config.capturesAudio = false; config.captureMicrophone = false
                config.ignoreShadowsSingleWindow = true
                config.ignoreGlobalClipSingleWindow = true
                config.preservesAspectRatio = true; config.scalesToFit = true
                if self.requiresNativeClientPixels {
                    guard let viewport=self.viewport,viewport.isValid,let scale=viewport.displayScale else {throw LabError.message("原生像素捕获缺少客户端像素密度")}
                    let native=CGSize(width:filter.contentRect.width*CGFloat(filter.pointPixelScale),height:filter.contentRect.height*CGFloat(filter.pointPixelScale))
                    guard let target=MobileWindowSizing.nativeClientPixels(viewport:CGSize(width:viewport.width,height:viewport.height),displayScale:scale) else {throw LabError.message("原生像素目标无效")}
                    // Native mode requires the actual canvas, not merely enough
                    // pixels before a later aspect-fit. Reject app minimum sizes
                    // and capture rounding that would reintroduce resampling.
                    guard abs(native.width-target.width)<0.01,abs(native.height-target.height)<0.01,
                          config.width==Int(target.width),config.height==Int(target.height),
                          config.width*config.height<=self.preset.width*self.preset.height else {
                        throw LabError.message("应用实际窗口未满足原生像素目标；未放大低分辨率采集帧")
                    }
                    config.scalesToFit=false
                    print("NATIVE_CLIENT_PIXELS source=\(config.width)x\(config.height) target=\(Int(target.width))x\(Int(target.height)) scalesToFit=false")
                }
                config.shouldBeOpaque = true
                config.backgroundColor = self.backgroundColor
                config.colorSpaceName = self.hdr ? CGColorSpace.itur_2100_PQ : CGColorSpace.sRGB
                if self.hdr { config.colorMatrix = kCVImageBufferYCbCrMatrix_ITU_R_2020 }
                else { config.captureDynamicRange = .SDR }
                if self.hdr,self.nativeWindowPixels,WebRTCRuntime.windowTextQuality,
                   let viewport=self.viewport,viewport.isValid,let scale=viewport.displayScale,
                   let pixels=MobileWindowSizing.encodingPixels(for:filter.contentRect.size,nativeScale:CGFloat(filter.pointPixelScale),
                    viewport:CGSize(width:viewport.width,height:viewport.height),displayScale:CGFloat(scale),maximumPixels:CGFloat(self.preset.width*self.preset.height)) {
                    // Retain RGB precision through the single resize; 4:2:0 happens
                    // only at the final encoding canvas. Native density stays explicit.
                    self.pixelConverter=try WindowTextPixelConverter(size:pixels)
                    config.pixelFormat=kCVPixelFormatType_64RGBAHalf
                    config.colorSpaceName=CGColorSpace.extendedLinearSRGB
                    self.source.adaptOutputFormat(toWidth:Int32(pixels.width),height:Int32(pixels.height),fps:Int32(self.preset.fps))
                    print("WINDOW_TEXT_PIXELS native=\(config.width)x\(config.height) nativeScale=\(filter.pointPixelScale) canvas=\(Int(pixels.width))x\(Int(pixels.height)) clientScale=\(scale)");fflush(stdout)
                }
                self.configureMetrics(filter)
                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                self.stream = stream
                self.setAccepting(true)
                try await stream.startCapture()
                // stop() may have run while the asynchronous start was pending.
                if self.stopped { try? await stream.stopCapture() }
            } catch {
                self.setAccepting(false)
                if !self.stopped { self.onFailure("窗口捕获失败：\(error.localizedDescription)") }
            }
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true; setAccepting(false)
        if let stream {
            self.stream = nil
            Task { try? await stream.stopCapture() }
        }
    }

    private func setAccepting(_ value: Bool) { lock.lock(); accepting = value; lock.unlock() }
    private func configureMetrics(_ filter: SCContentFilter) {
        lock.lock(); defer { lock.unlock() }
        counters.sourceWidthPoints = filter.contentRect.width
        counters.sourceHeightPoints = filter.contentRect.height
        counters.pointPixelScale = Double(filter.pointPixelScale)
        counters.queueDepth = Self.diagnosticQueueDepth
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.setAccepting(false); self.onFailure("窗口捕获已结束：\(error.localizedDescription)")
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        let callbackAt = DispatchTime.now().uptimeNanoseconds
        lock.lock(); defer { lock.unlock() }
        guard accepting else { return }
        callbackID += 1
        guard sampleBuffer.isValid,
              let attachment = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let rawStatus = attachment[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else { counters.invalidFrames += 1; skip("invalid_sample_or_status"); return }
        guard status == .complete else {
            if status == .idle { counters.idleFrames += 1 } else { counters.otherFrames += 1 }
            skip(status == .idle ? "idle" : "non_complete", status: rawStatus)
            return
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid, pts.isNumeric, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            counters.invalidFrames += 1; skip("invalid_pts_or_buffer"); return
        }
        let timestamp = CMTimeConvertScale(pts, timescale: 1_000_000_000, method: .default).value
        guard timestamp >= 0, lastTimestamp.map({ timestamp > $0 }) ?? true else {
            counters.invalidFrames += 1; skip("non_increasing_pts"); return
        }
        lastTimestamp = timestamp
        trace?.record(.capture, frameID: callbackID, ptsNs: timestamp, at: callbackAt)
        let now = ProcessInfo.processInfo.systemUptime
        if let lastCallback { append((now - lastCallback) * 1000, to: &gaps) }
        lastCallback = now
        // displayTime is mach absolute ticks, never wall time or a remote clock.
        if let displayTicks = attachment[.displayTime] as? UInt64 {
            var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
            let displaySeconds = Double(displayTicks) * Double(timebase.numer) / Double(timebase.denom) / 1e9
            let age = (now - displaySeconds) * 1000
            if age >= 0, age < 10_000 { append(age, to: &ages) }
        }
        let output:CVPixelBuffer
        counters.nativePixelWidth=CVPixelBufferGetWidth(buffer);counters.nativePixelHeight=CVPixelBufferGetHeight(buffer)
        counters.textQualityConversion=pixelConverter != nil
        if let pixelConverter {
            let start=ProcessInfo.processInfo.systemUptime
            guard let converted=pixelConverter.convert(buffer) else {skip("text_pixel_conversion_failed");return}
            append((ProcessInfo.processInfo.systemUptime-start)*1000,to:&conversionTimes)
            output=converted
        } else {output=buffer}
        counters.width = CVPixelBufferGetWidth(output); counters.height = CVPixelBufferGetHeight(output)
        counters.pixelFormat = HDRFormat.description(output)
        if hdr && counters.completeFrames % 60 == 0 { counters.luma10BitSamples = HDRFormat.lumaSamples(output) }
        if hdr && (CVPixelBufferGetPixelFormatType(output) != HDRFormat.pixelFormat ||
            counters.pixelFormat?["primaries"] != "ITU_R_2020" || counters.pixelFormat?["transfer"] != "SMPTE_ST_2084_PQ" ||
            counters.pixelFormat?["matrix"] != "ITU_R_2020") {
            accepting = false
            skip("hdr_format_mismatch")
            DispatchQueue.main.async { [weak self] in self?.onFailure("系统没有输出要求的 10 位 BT.2020/PQ 窗口帧；未发送错误色彩的视频") }
            return
        }
        counters.completeFrames += 1
        let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: output), rotation: ._0, timeStampNs: timestamp)
        trace?.sourceSubmitted(buffer: frame.buffer, frameID: callbackID, ptsNs: timestamp)
        source.capturer(capturer, didCapture: frame)
    }

    /// Called under the capture lock; idle/damage cadence is not an encoder drop.
    private func skip(_ reason: String, status: Int? = nil) {
        counters.skippedReasons[reason, default: 0] += 1
        trace?.record(.sourceSkip, frameID: callbackID, reason: reason, status: status)
    }

    private func append(_ value: Double, to values: inout [Double]) {
        values.append(value)
        if values.count > 600 { values.removeFirst(values.count - 600) }
    }
    func captureSnapshot() -> CaptureSample? {
        lock.lock(); defer { lock.unlock() }
        var result = counters
        func p95(_ values: [Double]) -> Double? {
            values.isEmpty ? nil : values.sorted()[Int(ceil(Double(values.count) * 0.95)) - 1]
        }
        result.callbackGapMillisecondsP95 = p95(gaps); result.callbackGapMillisecondsMax = gaps.max()
        result.windowServerAgeMillisecondsP95 = p95(ages); result.windowServerAgeMillisecondsMax = ages.max()
        result.conversionMillisecondsP95=p95(conversionTimes)
        conversionTimes.removeAll(keepingCapacity:true)
        gaps.removeAll(keepingCapacity: true); ages.removeAll(keepingCapacity: true)
        return result
    }
}
#endif
