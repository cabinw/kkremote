#if os(macOS)
import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreGraphics
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
    private let source: RTCVideoSource
    private let capturer: RTCVideoCapturer
    private let preset: LabPreset
    private let windowID: UInt32
    private let hdr: Bool
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

    init(source: RTCVideoSource, preset: LabPreset, windowID: UInt32, hdr: Bool = false, onFailure: @escaping (String) -> Void) {
        self.source = source; self.preset = preset; self.windowID = windowID; self.hdr = hdr; self.onFailure = onFailure
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
                guard let window = content.windows.first(where: { $0.windowID == self.windowID }) else {
                    throw LabError.message("选定窗口已关闭或不可捕获，请重新选择窗口")
                }
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let config = self.hdr ? SCStreamConfiguration(preset: .captureHDRStreamCanonicalDisplay) : SCStreamConfiguration()
                config.width = self.preset.width; config.height = self.preset.height
                // Let WindowServer deliver at display cadence; RTCVideoSource caps output fps.
                // Throttling twice at exactly 1/60 can discard near-boundary display updates.
                config.minimumFrameInterval = .zero
                config.pixelFormat = self.hdr ? HDRFormat.pixelFormat : kCVPixelFormatType_32BGRA
                config.queueDepth = 3
                config.showsCursor = false; config.showMouseClicks = false
                config.capturesAudio = false; config.captureMicrophone = false
                config.ignoreShadowsSingleWindow = true
                config.ignoreGlobalClipSingleWindow = true
                config.preservesAspectRatio = true; config.scalesToFit = true
                config.shouldBeOpaque = true
                config.backgroundColor = self.backgroundColor
                config.colorSpaceName = self.hdr ? CGColorSpace.itur_2100_PQ : CGColorSpace.sRGB
                if self.hdr { config.colorMatrix = kCVImageBufferYCbCrMatrix_ITU_R_2020 }
                else { config.captureDynamicRange = .SDR }
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
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.setAccepting(false); self.onFailure("窗口捕获已结束：\(error.localizedDescription)")
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        lock.lock(); defer { lock.unlock() }
        guard accepting else { return }
        guard sampleBuffer.isValid,
              let attachment = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let rawStatus = attachment[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else { counters.invalidFrames += 1; return }
        guard status == .complete else {
            if status == .idle { counters.idleFrames += 1 } else { counters.otherFrames += 1 }
            return
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid, pts.isNumeric, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            counters.invalidFrames += 1; return
        }
        let timestamp = CMTimeConvertScale(pts, timescale: 1_000_000_000, method: .default).value
        guard timestamp >= 0, lastTimestamp.map({ timestamp > $0 }) ?? true else {
            counters.invalidFrames += 1; return
        }
        lastTimestamp = timestamp
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
        counters.width = CVPixelBufferGetWidth(buffer); counters.height = CVPixelBufferGetHeight(buffer)
        counters.pixelFormat = HDRFormat.description(buffer)
        if hdr && counters.completeFrames % 60 == 0 { counters.luma10BitSamples = HDRFormat.lumaSamples(buffer) }
        if hdr && (CVPixelBufferGetPixelFormatType(buffer) != HDRFormat.pixelFormat ||
            counters.pixelFormat?["primaries"] != "ITU_R_2020" || counters.pixelFormat?["transfer"] != "SMPTE_ST_2084_PQ" ||
            counters.pixelFormat?["matrix"] != "ITU_R_2020") {
            accepting = false
            DispatchQueue.main.async { [weak self] in self?.onFailure("系统没有输出要求的 10 位 BT.2020/PQ 窗口帧；未发送错误色彩的视频") }
            return
        }
        counters.completeFrames += 1
        source.capturer(capturer, didCapture: RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0, timeStampNs: timestamp))
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
        gaps.removeAll(keepingCapacity: true); ages.removeAll(keepingCapacity: true)
        return result
    }
}
#endif
