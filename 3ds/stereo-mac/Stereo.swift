import AVFoundation
import CoreImage
import CoreML
import Foundation
import VideoToolbox

final class Movie {
    let writer: AVAssetWriter
    var track: AVAssetWriterInput?
    init(_ url: URL) throws { writer = try AVAssetWriter(outputURL: url, fileType: .mp4) }
    func append(_ sample: CMSampleBuffer) throws {
        if track == nil {
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: sample.formatDescription)
            guard writer.canAdd(input) else { throw Failure("unsupported encoded stream") }
            writer.add(input)
            guard writer.startWriting() else { throw writer.error ?? Failure("start writing") }
            writer.startSession(atSourceTime: sample.presentationTimeStamp)
            track = input
        }
        let timeout = now() + 5
        while !track!.isReadyForMoreMediaData && writer.status == .writing && now() < timeout {
            Thread.sleep(forTimeInterval: 0.001)
        }
        guard track!.isReadyForMoreMediaData, track!.append(sample) else { throw writer.error ?? Failure("muxing failed") }
    }
    func finish() async throws {
        track?.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? Failure("finalize movie") }
    }
}

struct Frame {
    let read, prep, inference, warp, encode, total, scheduled: Double
}

func distribution(_ durations: [Double]) -> [String: Double] {
    let ms = durations.map { $0 * 1000 }.sorted()
    func percentile(_ p: Double) -> Double { ms[max(0, Int(ceil(p * Double(ms.count))) - 1)] }
    return ["p50": percentile(0.5), "p95": percentile(0.95), "p99": percentile(0.99), "max": ms.last!]
}

func run() async throws {
    let args = CommandLine.arguments
    guard args.count == 5, ["fast", "paced"].contains(args[4]) else {
        throw Failure("usage: stereo MODEL.mlmodelc INPUT_VIDEO NEW_OUTPUT.mp4 fast|paced")
    }
    let paced = args[4] == "paced"
    let setup = now()
    let asset = AVURLAsset(url: URL(fileURLWithPath: args[2]))
    guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure("no video track") }
    let fps = try await track.load(.nominalFrameRate)
    let transform = try await track.load(.preferredTransform)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    output.alwaysCopiesSampleData = false
    reader.add(output)
    let converter = try Converter(URL(fileURLWithPath: args[1]))
    let encoder = try Encoder(fps)
    let stereo = try buffer(800, 240)
    let destination = URL(fileURLWithPath: args[3])
    let files = FileManager.default
    guard !files.fileExists(atPath: destination.path) else { throw Failure("output already exists") }
    let temporary = destination.deletingLastPathComponent().appendingPathComponent(".stereo-\(UUID()).mp4")
    defer { try? files.removeItem(at: temporary) }
    let movie = try Movie(temporary)
    guard reader.startReading() else { throw reader.error ?? Failure("reader start failed") }
    let setupSeconds = now() - setup
    var frames = [Frame](), warmup = [Frame]()
    var anchor = 0.0, firstPTS = 0.0, lastMux = 0.0, late = 0
    let warmCount = 12
    // Peek one sample to learn its PTS before pacing. Charge its measured read time
    // separately to service latency; scheduled latency starts at its release time.
    while true {
        let readStart = now()
        guard let sample = output.copyNextSampleBuffer() else { break }
        let read = now() - readStart
        guard let source = sample.imageBuffer else { throw Failure("input frame has no image") }
        let pts = sample.presentationTimeStamp
        let measured = warmup.count == warmCount
        if measured && frames.isEmpty { firstPTS = pts.seconds; anchor = readStart }
        let due = anchor + pts.seconds - firstPTS
        if paced && measured && due > now() { try await Task.sleep(for: .seconds(max(0, due - now()))) }
        let start = now()
        let frame: Frame = try autoreleasepool {
            let image = CIImage(cvPixelBuffer: source).transformed(by: transform)
            let eyeFit = converter.fit(image, to: converter.eye)
            let depthFit = converter.fit(image, to: converter.input)
            let normalized = now()
            let depth = try converter.predict()
            let inferred = now()
            try converter.warp(depth, eyeFit: eyeFit, depthFit: depthFit, into: stereo)
            let warped = now()
            let (packet, ready) = try encoder.encode(stereo, pts: pts, duration: sample.duration)
            try movie.append(packet)
            return Frame(read: read, prep: normalized - start, inference: inferred - normalized,
                         warp: warped - inferred, encode: ready - warped,
                         total: read + ready - start, scheduled: ready - due)
        }
        if measured {
            frames.append(frame)
            let budget = sample.duration.seconds
            if paced && frame.scheduled > (budget.isFinite && budget > 0 ? budget : 1 / Double(fps)) { late += 1 }
            lastMux = now()
        } else { warmup.append(frame) }
    }
    guard reader.status == .completed else { throw reader.error ?? Failure("read failure") }
    guard !frames.isEmpty else { throw Failure("need more than 12 frames for a warmed measurement") }
    try await movie.finish()
    try files.moveItem(at: temporary, to: destination)
    var stats: [String: Any] = ["mode": args[4], "input_nominal_fps": fps, "warmup_frames": warmup.count,
        "measured_frames": frames.count, "setup_ms": setupSeconds * 1000, "first_frame_ms": warmup[0].total * 1000,
        "wall_fps": Double(frames.count) / (lastMux - anchor),
        "read_ms": distribution(frames.map(\.read)), "prepare_ms": distribution(frames.map(\.prep)),
        "depth_ms": distribution(frames.map(\.inference)), "warp_ms": distribution(frames.map(\.warp)),
        "h264_ms": distribution(frames.map(\.encode)), "service_ms": distribution(frames.map(\.total))]
    if paced {
        stats["release_to_packet_ms"] = distribution(frames.map(\.scheduled))
        stats["missed_deadlines"] = late
    }
    let data = try JSONSerialization.data(withJSONObject: stats, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

@main struct Benchmark {
    static func main() async {
        do { try await run() } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
}
