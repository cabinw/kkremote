import Foundation
import CoreVideo
import CoreGraphics
import CoreText
import WebRTC

enum PatternKind: String, Codable, CaseIterable, Identifiable {
    case grid, noise, desktop
    var id: String { rawValue }
    var title: String {
        switch self {
        case .grid: return "移动网格 / 文字"
        case .noise: return "高复杂度噪声（压力测试）"
        case .desktop: return "桌面 / 滚动内容（合成对照）"
        }
    }
}

struct LabPreset: Codable, Equatable {
    var width = 1920
    var height = 1080
    var fps = 60
    var megabits = 25
    var pattern = PatternKind.grid
}

final class TestPattern: LabVideoSource {
    private let source: RTCVideoSource
    private let capturer: RTCVideoCapturer
    private let preset: LabPreset
    private let queue = DispatchQueue(label: "kkremote.test-pattern", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var pool: CVPixelBufferPool?
    private var frameNumber = 0
    private var noiseImages: [CGImage] = []
    private var desktop: DesktopPattern?
    private let trace: FrameTrace?

    init(source: RTCVideoSource, preset: LabPreset, trace: FrameTrace? = nil) throws {
        self.trace = trace
        self.source = source
        self.preset = preset
        capturer = RTCVideoCapturer(delegate: source)
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: preset.width,
            kCVPixelBufferHeightKey as String: preset.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess else {
            throw LabError.message("无法创建测试画面缓冲池")
        }
        source.adaptOutputFormat(toWidth: Int32(preset.width), height: Int32(preset.height), fps: Int32(preset.fps))
        if preset.pattern == .desktop { desktop = try DesktopPattern(width: preset.width, height: preset.height) }
        if preset.pattern == .noise {
            // Precompute deterministic detail; no per-frame random-number loop or unbounded allocation.
            var seed: UInt32 = 0x4b4b524d
            for _ in 0..<3 {
                var pixels = [UInt32](repeating: 0, count: preset.width * preset.height)
                for i in pixels.indices {
                    seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
                    pixels[i] = (seed & 0x00ffffff) | 0xff000000
                }
                let data = pixels.withUnsafeBytes { Data($0) }
                guard let provider = CGDataProvider(data: data as CFData),
                      let image = CGImage(width: preset.width, height: preset.height, bitsPerComponent: 8,
                        bitsPerPixel: 32, bytesPerRow: preset.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
                    throw LabError.message("无法创建高复杂度测试源")
                }
                noiseImages.append(image)
            }
        }
    }

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        self.timer = timer
        timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / preset.fps), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.draw() }
        timer.resume()
    }

    func stop() { timer?.cancel(); timer = nil }
    deinit { stop() }

    private func draw() {
        guard let pool else { return }
        var pixelBuffer: CVPixelBuffer?
        let aux = [kCVPixelBufferPoolAllocationThresholdKey as String: 4] as CFDictionary
        // Drop new work instead of accumulating buffers when the encoder cannot keep up.
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, aux, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else { trace?.record(.sourceSkip, reason: "pattern_pool_pressure"); return }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer), width: preset.width, height: preset.height,
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, []); trace?.record(.sourceSkip, reason: "pattern_context_failure"); return
        }
        let width = CGFloat(preset.width), height = CGFloat(preset.height)
        if let desktop {
            desktop.draw(in: context, frame: frameNumber, fps: preset.fps, megabits: preset.megabits)
        } else if preset.pattern == .noise {
            context.draw(noiseImages[frameNumber % noiseImages.count], in: CGRect(x: 0, y: 0, width: width, height: height))
        } else {
            context.setFillColor(CGColor(gray: 0.055, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let shift = frameNumber % 64
            for y in stride(from: 0, to: preset.height, by: 64) {
                for x in stride(from: -64, to: preset.width, by: 64) {
                    let value = CGFloat(((x / 64 + y / 64 + frameNumber / 120) % 7 + 7) % 7) / 9
                    context.setFillColor(CGColor(red: value, green: 0.18, blue: 0.7 - value / 2, alpha: 1))
                    context.fill(CGRect(x: x + shift, y: y, width: 61, height: 61))
                }
            }
        }
        if desktop == nil {
            context.setFillColor(CGColor(gray: 0.03, alpha: 1))
            context.fill(CGRect(x: 24, y: 24, width: width - 48, height: 180))
            let font = CTFontCreateWithName("Menlo" as CFString, 24, nil)
            let lines = ["KKRemote Lab | H.264 SDR | synthetic source",
                         "Frame \(frameNumber) | \(preset.width)x\(preset.height) @ \(preset.fps) fps",
                         "Bitrate ceiling \(preset.megabits) Mbps | actual rate depends on content",
                         "0123456789 ABC abc | thin lines / moving grid / text"]
            for (index, line) in lines.enumerated() {
                let text = NSAttributedString(string: line, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)
                ])
                context.textPosition = CGPoint(x: 40, y: 160 - index * 36)
                CTLineDraw(CTLineCreateWithAttributedString(text), context)
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        let timestamp = Int64(DispatchTime.now().uptimeNanoseconds)
        let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixelBuffer), rotation: ._0, timeStampNs: timestamp)
        trace?.sourceSubmitted(buffer: frame.buffer, frameID: UInt64(frameNumber + 1), ptsNs: timestamp)
        source.capturer(capturer, didCapture: frame)
        frameNumber += 1
    }
}
