import AVFoundation
import CoreImage
import CoreML
import Foundation
import VideoToolbox

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

func check(_ status: OSStatus, _ operation: String) throws {
    if status != noErr { throw Failure("\(operation) failed (\(status))") }
}

func now() -> Double { ProcessInfo.processInfo.systemUptime }

func buffer(_ width: Int, _ height: Int) throws -> CVPixelBuffer {
    var result: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary] as CFDictionary
    try check(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                  attributes, &result), "pixel buffer allocation")
    return result!
}

struct Fit {
    let scale: CGFloat
    let x, y: CGFloat
    init(_ extent: CGRect, _ width: Int, _ height: Int) {
        scale = min(CGFloat(width) / extent.width, CGFloat(height) / extent.height)
        x = (CGFloat(width) - extent.width * scale) / 2
        y = (CGFloat(height) - extent.height * scale) / 2
    }
}

final class Converter {
    static let width = 400, height = 240
    let model: MLModel
    let context = CIContext(options: [.cacheIntermediates: false])
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    let eye: CVPixelBuffer
    let input: CVPixelBuffer
    let black = CIImage(color: .black)

    init(_ url: URL) throws {
        eye = try buffer(Self.width, Self.height)
        input = try buffer(518, 392)
        let config = MLModelConfiguration()
        config.computeUnits = .all
        model = try MLModel(contentsOf: url, configuration: config)
    }

    func fit(_ image: CIImage, to output: CVPixelBuffer) -> Fit {
        let w = CVPixelBufferGetWidth(output), h = CVPixelBufferGetHeight(output)
        let placement = Fit(image.extent, w, h)
        let matrix = CGAffineTransform(a: placement.scale, b: 0, c: 0, d: placement.scale,
                                       tx: placement.x - image.extent.minX * placement.scale,
                                       ty: placement.y - image.extent.minY * placement.scale)
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        let fitted = image.transformed(by: matrix).composited(over: black).cropped(to: bounds)
        context.render(fitted, to: output, bounds: bounds, colorSpace: srgb)
        return placement
    }

    func predict() throws -> CVPixelBuffer {
        let features = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: input)])
        guard let depth = try model.prediction(from: features).featureValue(for: "depth")?.imageBufferValue,
              CVPixelBufferGetPixelFormatType(depth) == kCVPixelFormatType_OneComponent16Half,
              CVPixelBufferGetWidth(depth) == 518, CVPixelBufferGetHeight(depth) == 392 else {
            throw Failure("expected normalized Float16 inverse depth at 518 × 392")
        }
        return depth
    }

    // Forward-project each source pixel. Near samples win collisions; exposed gaps
    // borrow the farther of their neighbours instead of stretching a foreground edge.
    func warp(_ depth: CVPixelBuffer, eyeFit: Fit, depthFit: Fit, into output: CVPixelBuffer) throws {
        try check(CVPixelBufferLockBaseAddress(eye, .readOnly), "lock source")
        defer { CVPixelBufferUnlockBaseAddress(eye, .readOnly) }
        try check(CVPixelBufferLockBaseAddress(depth, .readOnly), "lock depth")
        defer { CVPixelBufferUnlockBaseAddress(depth, .readOnly) }
        try check(CVPixelBufferLockBaseAddress(output, []), "lock destination")
        defer { CVPixelBufferUnlockBaseAddress(output, []) }
        let w = Self.width, h = Self.height
        let colors = CVPixelBufferGetBaseAddress(eye)!.assumingMemoryBound(to: UInt32.self)
        let depths = CVPixelBufferGetBaseAddress(depth)!.assumingMemoryBound(to: Float16.self)
        let pixels = CVPixelBufferGetBaseAddress(output)!.assumingMemoryBound(to: UInt32.self)
        let colorStride = CVPixelBufferGetBytesPerRow(eye) / 4
        let depthStride = CVPixelBufferGetBytesPerRow(depth) / 2
        let outputStride = CVPixelBufferGetBytesPerRow(output) / 4
        let ratio = depthFit.scale / eyeFit.scale
        let depthX = (0..<w).map { min(517, max(0, Int((CGFloat($0) + 0.5 - eyeFit.x) * ratio + depthFit.x))) }
        let xStart = min(w - 1, max(0, Int(ceil(eyeFit.x - 0.5))))
        let xEnd = max(xStart + 1, min(w, Int(ceil(CGFloat(w) - eyeFit.x - 0.5))))
        let empty = [Float](repeating: -1, count: 2 * w)
        for y in 0..<h {
            let dst = pixels.advanced(by: y * outputStride)
            dst.update(repeating: 0xff000000, count: 2 * w)
            guard CGFloat(y) + 0.5 >= eyeFit.y, CGFloat(y) + 0.5 < CGFloat(h) - eyeFit.y else { continue }
            let dy = min(391, max(0, Int((CGFloat(y) + 0.5 - eyeFit.y) * ratio + depthFit.y)))
            let row = depths.advanced(by: dy * depthStride)
            let src = colors.advanced(by: y * colorStride)
            var z = empty
            for x in xStart..<xEnd {
                let raw = Float(row[depthX[x]])
                let near = raw.isFinite ? max(0, min(1, raw)) : 0.5
                let shift = Int(((near - 0.5) * 6).rounded())
                for side in 0..<2 {
                    let projected = x + (side == 0 ? shift : -shift)
                    if projected < xStart || projected >= xEnd { continue }
                    let target = side * w + projected
                    if near >= z[target] {
                        z[target] = near
                        dst[target] = src[x]
                    }
                }
            }
            for side in 0..<2 {
                let start = side * w + xStart, end = side * w + xEnd
                var x = start
                while x < end {
                    if z[x] >= 0 { x += 1; continue }
                    let hole = x
                    while x < end && z[x] < 0 { x += 1 }
                    let left = hole > start ? hole - 1 : nil
                    let right = x < end ? x : nil
                    let donor: Int?
                    if let left, let right { donor = z[left] < z[right] ? left : right }
                    else { donor = left ?? right }
                    if let donor { dst.advanced(by: hole).update(repeating: dst[donor], count: x - hole) }
                }
            }
        }
    }
}

final class Encoder {
    let session: VTCompressionSession
    init(_ fps: Float) throws {
        var candidate: VTCompressionSession?
        let spec = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary
        try check(VTCompressionSessionCreate(allocator: nil, width: 800, height: 240,
                  codecType: kCMVideoCodecType_H264, encoderSpecification: spec,
                  imageBufferAttributes: nil, compressedDataAllocator: nil,
                  outputCallback: nil, refcon: nil, compressionSessionOut: &candidate), "H.264 session")
        session = candidate!
        let options: [CFString: Any] = [kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_Baseline_AutoLevel,
            kVTCompressionPropertyKey_ExpectedFrameRate: fps,
            kVTCompressionPropertyKey_AverageBitRate: 1_500_000,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: Int(max(1, fps.rounded()))]
        try check(VTSessionSetProperties(session, propertyDictionary: options as CFDictionary), "encoder configuration")
        try check(VTCompressionSessionPrepareToEncodeFrames(session), "encoder preparation")
    }
    deinit { VTCompressionSessionInvalidate(session) }

    func encode(_ pixels: CVPixelBuffer, pts: CMTime, duration: CMTime) throws -> (CMSampleBuffer, Double) {
        let ready = DispatchSemaphore(value: 0)
        var packet: CMSampleBuffer?, status: OSStatus = 0, callbackTime = 0.0
        try check(VTCompressionSessionEncodeFrame(session, imageBuffer: pixels, presentationTimeStamp: pts,
                    duration: duration, frameProperties: nil, infoFlagsOut: nil) { result, _, sample in
            callbackTime = now()
            status = result
            packet = sample
            ready.signal()
        }, "encode")
        // One frame in flight. Flush even if the selected encoder would otherwise batch frames.
        try check(VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: pts), "drain frame")
        guard ready.wait(timeout: .now() + 5) == .success else { throw Failure("encoder callback timeout") }
        try check(status, "encoder callback")
        guard let packet else { throw Failure("encoder dropped a frame") }
        return (packet, callbackTime)
    }
}

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

do { try await run() } catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
