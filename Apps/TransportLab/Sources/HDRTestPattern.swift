import Foundation
import CoreVideo
import WebRTC

/// A known 10-bit PQ ramp, neutral chroma and a moving highlight; explicitly synthetic.
final class HDRTestPattern: LabVideoSource {
    private let source: RTCVideoSource
    private let capturer: RTCVideoCapturer
    private let fps: Int
    private let queue = DispatchQueue(label: "kkremote.hdr-pattern", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var buffers: [CVPixelBuffer] = []
    private var frame = 0
    private let trace: FrameTrace?
    init(source: RTCVideoSource, width: Int, height: Int, fps: Int, trace: FrameTrace? = nil) throws {
        self.trace = trace
        self.source = source; self.fps = fps; capturer = RTCVideoCapturer(delegate: source)
        source.adaptOutputFormat(toWidth: Int32(width), height: Int32(height), fps: Int32(fps))
        for phase in 0..<16 {
            var buffer: CVPixelBuffer?
            let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary
            guard CVPixelBufferCreate(nil, width, height, HDRFormat.pixelFormat, attrs, &buffer) == kCVReturnSuccess,
                  let buffer else { throw LabError.message("无法创建 HDR 测试帧") }
            HDRFormat.tag(buffer)
            CVPixelBufferLockBaseAddress(buffer, [])
            let strideY = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) / 2
            let strideUV = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) / 2
            let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt16.self)
            let uv = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt16.self)
            for row in 0..<height {
                for col in 0..<width {
                    let gradient = 64 + (col * 876 / max(1, width - 1))
                    let highlight = row > height * 2 / 3 && abs(col - phase * width / 16) < width / 32
                    y[row * strideY + col] = UInt16(highlight ? 820 : gradient) << 6
                }
            }
            for row in 0..<height / 2 { for col in 0..<width { uv[row * strideUV + col] = 512 << 6 } }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            buffers.append(buffer)
        }
    }
    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue); self.timer = timer
        timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / fps), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let buffer = self.buffers[self.frame % self.buffers.count]; self.frame += 1
            let timestamp = Int64(DispatchTime.now().uptimeNanoseconds)
            let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0, timeStampNs: timestamp)
            self.trace?.sourceSubmitted(buffer: frame.buffer, frameID: UInt64(self.frame), ptsNs: timestamp)
            self.source.capturer(self.capturer, didCapture: frame)
        }
        timer.resume()
    }
    func stop() { timer?.cancel(); timer = nil }
    deinit { stop() }
}
