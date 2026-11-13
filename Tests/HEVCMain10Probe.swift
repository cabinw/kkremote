import Foundation
import VideoToolbox
import WebRTC

enum LabError: Error { case message(String) }

private final class Probe: NSObject, RTCVideoRenderer {
    let encoder = HEVCEncoder(), decoder = HEVCDecoder()
    let lock = NSLock()
    var submitted = 0, encoded = 0, decoded = 0, bytes = 0, failures = 0, lowBits = 0
    var format: [String: String] = [:]
    var output = Data()
    init(mbps: Int) throws {
        super.init()
        decoder.setCallback { [weak self] frame in
            guard let self, let buffer = frame.buffer as? RTCCVPixelBuffer else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            self.decoded += 1; self.format = HDRFormat.description(buffer.pixelBuffer)
            if self.decoded == 1 {
                CVPixelBufferLockBaseAddress(buffer.pixelBuffer, .readOnly)
                let p = CVPixelBufferGetBaseAddressOfPlane(buffer.pixelBuffer, 0)!.assumingMemoryBound(to: UInt16.self)
                self.lowBits = (0..<CVPixelBufferGetWidth(buffer.pixelBuffer)).filter { ((p[$0] >> 6) & 3) != 0 }.count
                CVPixelBufferUnlockBaseAddress(buffer.pixelBuffer, .readOnly)
            }
        }
        _ = decoder.startDecode(withNumberOfCores: 4)
        encoder.setCallback { [weak self] image, _ in
            guard let self else { return false }
            self.lock.lock(); self.encoded += 1; self.bytes += image.buffer.count
            if self.encoded <= 120 { self.output.append(image.buffer) }
            self.lock.unlock()
            let result = self.decoder.decode(image, missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0)
            if result != 0 { self.lock.lock(); self.failures += 1; self.lock.unlock() }
            return result == 0
        }
        let settings = RTCVideoEncoderSettings()
        settings.name = "H265"; settings.width = 2560; settings.height = 1440
        settings.startBitrate = UInt32(mbps * 1000); settings.maxBitrate = UInt32(mbps * 1000)
        settings.minBitrate = 1; settings.maxFramerate = 60; settings.mode = .screensharing; settings.qpMax = 51
        let result = encoder.startEncode(with: settings, numberOfCores: 4)
        guard result == 0 else { throw LabError.message("VT Main10 start failed: \(result)") }
    }
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        let next = RTCVideoFrame(buffer: frame.buffer, rotation: ._0, timeStampNs: frame.timeStampNs)
        next.timeStamp = Int32(bitPattern: UInt32(truncatingIfNeeded: frame.timeStampNs / 1_000_000 * 90))
        lock.lock(); submitted += 1; let first = submitted == 1; lock.unlock()
        let result = encoder.encode(next, codecSpecificInfo: nil, frameTypes: [NSNumber(value: (first ? RTCFrameType.videoFrameKey : .videoFrameDelta).rawValue)])
        if result != 0 { lock.lock(); failures += 1; lock.unlock() }
    }
    func snapshot() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["submitted": submitted, "encoded": encoded, "decoded": decoded, "bytes": bytes,
                "failures": failures, "decodedFormat": format, "firstFrameNon8BitSamples": lowBits]
    }
}

@main struct Main10Probe {
    static func main() throws {
        RTCInitializeSSL()
        let factory = RTCPeerConnectionFactory(), probe = try Probe(mbps: 20)
        let source = factory.videoSource(forScreenCast: true), duration = 12
        let track = factory.videoTrack(with: source, trackId: "main10-probe")
        let pattern = try HDRTestPattern(source: source, width: 2560, height: 1440, fps: 60)
        track.add(probe); pattern.start()
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<duration { RunLoop.current.run(until: Date().addingTimeInterval(1)) }
        pattern.stop(); track.remove(probe); _ = probe.encoder.release(); _ = probe.decoder.release()
        var report = probe.snapshot(); report["seconds"] = ProcessInfo.processInfo.systemUptime - start
        report["scope"] = "native Main10 encode/decode through RTCVideoSource; no RTP yet"
        print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
        if let path = CommandLine.arguments.dropFirst().first { try probe.output.write(to: URL(fileURLWithPath: path)) }
        guard probe.decoded >= 600, probe.failures == 0, probe.lowBits > 100,
              probe.format["transfer"] == "SMPTE_ST_2084_PQ" else { throw LabError.message("Main10 verification failed") }
    }
}
