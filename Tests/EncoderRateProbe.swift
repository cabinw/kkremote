import Foundation
import WebRTC

enum LabError: Error { case message(String) }

/// A real native encoder, fed by the same source as the app, without PeerConnection/BWE/pacer.
/// This diagnostic deliberately has no network destination; it may exceed the requested bitrate.
private final class EncoderProbe: NSObject, RTCVideoRenderer {
    let telemetry: EncoderTelemetry
    private let encoder: any RTCVideoEncoder
    private let lock = NSLock()
    private var accepting = true, first = true

    init(kbps: UInt32) throws {
        let telemetry = EncoderTelemetry()
        self.telemetry = telemetry
        let factory = LabH264EncoderFactory(telemetry: telemetry)
        guard let encoder = factory.createEncoder(RTCVideoCodecInfo(name: "H264", parameters: [
            "profile-level-id": "640c33", "packetization-mode": "1", "level-asymmetry-allowed": "1"])) else {
            throw LabError.message("Cannot create H.264 encoder")
        }
        self.encoder = encoder
        super.init()
        encoder.setCallback { _, _ in true }
        let settings = RTCVideoEncoderSettings()
        settings.name = "H264"; settings.width = 2560; settings.height = 1440
        settings.startBitrate = kbps; settings.maxBitrate = kbps; settings.minBitrate = 1
        settings.maxFramerate = 60; settings.qpMax = 51; settings.mode = .screensharing
        guard encoder.startEncode(with: settings, numberOfCores: Int32(ProcessInfo.processInfo.activeProcessorCount)) == 0,
              encoder.setBitrate(kbps, framerate: 60) == 0 else {
            _ = encoder.release(); throw LabError.message("Encoder initialization failed")
        }
    }
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        lock.lock(); defer { lock.unlock() }
        guard accepting else { return }
        // PeerConnection normally sets this 90 kHz timestamp before calling the encoder.
        let input = RTCVideoFrame(buffer: frame.buffer, rotation: frame.rotation, timeStampNs: frame.timeStampNs)
        input.timeStamp = Int32(bitPattern: UInt32(truncatingIfNeeded: frame.timeStampNs / 1_000_000 * 90))
        let type = first ? RTCFrameType.videoFrameKey : .videoFrameDelta
        first = false
        _ = encoder.encode(input, codecSpecificInfo: nil, frameTypes: [NSNumber(value: type.rawValue)])
    }
    func stop() {
        lock.lock(); defer { lock.unlock() }
        guard accepting else { return }; accepting = false
        _ = encoder.release()
    }
    deinit { stop() }
}

@main struct EncoderRateProbe {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 3, let mbps = UInt32(args[0]), (1...120).contains(mbps),
              let duration = Int(args[1]), (5...120).contains(duration),
              let patternKind = PatternKind(rawValue: args[2]) else {
            throw LabError.message("Usage: probe-encoder.sh Mbps durationSeconds grid|noise|desktop")
        }
        RTCInitializeSSL()
        let factory = RTCPeerConnectionFactory()
        let source = factory.videoSource(forScreenCast: true)
        let track = factory.videoTrack(with: source, trackId: "direct-encoder-probe")
        let probe = try EncoderProbe(kbps: mbps * 1000)
        let pattern = try TestPattern(source: source, preset: LabPreset(width: 2560, height: 1440,
            fps: 60, megabits: Int(mbps), pattern: patternKind))
        track.add(probe)
        defer { pattern.stop(); track.remove(probe); probe.stop() }
        let started = ProcessInfo.processInfo.systemUptime
        var previousTime = started, previousFrames = 0, previousBytes = 0
        struct Sample: Encodable {
            let seconds: Double, fps: Double, mbps: Double
            let encoder: EncoderSample
        }
        var samples: [Sample] = []
        pattern.start()
        for _ in 0..<duration {
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            let now = ProcessInfo.processInfo.systemUptime, state = probe.telemetry.snapshot(), dt = now - previousTime
            samples.append(Sample(seconds: now - started, fps: Double(state.encodedFrames - previousFrames) / dt,
                mbps: Double(state.encodedBytes - previousBytes) * 8 / dt / 1_000_000, encoder: state))
            previousTime = now; previousFrames = state.encodedFrames; previousBytes = state.encodedBytes
        }
        struct Report: Encodable {
            let scope = "single Mac native encoder only; no network, transport or decoder qualification"
            let width = 2560, height = 1440, requestedFPS = 60
            let requestedMbps: UInt32, pattern: PatternKind
            let samples: [Sample]
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let report = Report(requestedMbps: mbps, pattern: patternKind, samples: samples)
        print(String(decoding: try encoder.encode(report), as: UTF8.self))
    }
}
