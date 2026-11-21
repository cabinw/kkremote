import AVFoundation
import CoreImage
import CoreML
import Foundation
import ImageIO
import Darwin

// Both this process and the relay use the macOS CLOCK_MONOTONIC_RAW clock.
func rawTime() -> UInt64 { clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) }

func emit<T: FixedWidthInteger>(_ value: T, to packet: inout Data) {
    var network = value.bigEndian
    withUnsafeBytes(of: &network) { packet.append(contentsOf: $0) }
}

// Keep length-prefixed NALs; attach SPS/PPS to every independently decodable frame.
func avcPayload(_ sample: CMSampleBuffer) throws -> (Data,Bool) {
    guard let block = sample.dataBuffer, let format = sample.formatDescription else { throw Failure("missing AVC sample") }
    let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String:Any]]
    let independent = attachments?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool != true
    var payload = Data()
    if independent {
        var count = 0, header: Int32 = 0
        try check(CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0,
            parameterSetPointerOut:nil, parameterSetSizeOut:nil, parameterSetCountOut:&count, nalUnitHeaderLengthOut:&header), "AVC format")
        guard header == 4 else { throw Failure("expected four-byte NAL lengths") }
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?, size = 0
            try check(CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex:i,
                parameterSetPointerOut:&ptr,parameterSetSizeOut:&size,parameterSetCountOut:nil,nalUnitHeaderLengthOut:nil), "AVC parameter set")
            guard let ptr, size>0 else { throw Failure("empty parameter set") }
            emit(UInt32(size),to:&payload); payload.append(ptr,count:size)
        }
    }
    var body = Data(count:CMBlockBufferGetDataLength(block))
    let length = body.count
    guard length>0 else { throw Failure("empty AVC frame") }
    try body.withUnsafeMutableBytes { bytes in
        try check(CMBlockBufferCopyDataBytes(block, atOffset:0,dataLength:length,destination:bytes.baseAddress!), "AVC bytes")
    }
    payload.append(body)
    return (payload,independent)
}

@main struct Live {
    static func main() async {
        do { try await stream() }
        catch { fputs("Live conversion: \(error)\n", stderr); exit(1) }
    }
    static func stream() async throws {
        guard CommandLine.arguments.count == 4 else { throw Failure("usage: live MODEL INPUT jpeg|h264") }
        let modelURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let asset = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[2]))
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure("no video") }
        let transform = try await track.load(.preferredTransform)
        let converter = try Converter(modelURL)
        let stereo = try buffer(800, 240)
        let useAVC = CommandLine.arguments[3] == "h264"
        let nominalFPS = try await track.load(.nominalFrameRate)
        let encoder = useAVC ? try Encoder(nominalFPS, bitrate: 420_000, keyInterval: 12) : nil
        var timeline: UInt64 = 0
        var seq: UInt32 = 0
        var slider: UInt8 = 200
        // The relay coalesces slider changes into single bytes on stdin.
        _ = fcntl(STDIN_FILENO, F_SETFL, O_NONBLOCK)
        while true {
            let reader = try AVAssetReader(asset: asset)
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            out.alwaysCopiesSampleData = false
            reader.add(out)
            guard reader.startReading() else { throw reader.error ?? Failure("start reader") }
            var anchor: UInt64?, firstPTS = 0.0, lastEnd: UInt64 = 0
            while let sample = out.copyNextSampleBuffer() {
                guard let source = sample.imageBuffer else { throw Failure("no image") }
                let pts = sample.presentationTimeStamp.seconds
                if anchor == nil { firstPTS = pts; anchor = rawTime() }
                let due = anchor! + UInt64(max(0,pts-firstPTS) * 1e9)
                let t = rawTime()
                if due > t { try await Task.sleep(nanoseconds: due-t) }
                var v: UInt8 = 0
                while Darwin.read(STDIN_FILENO,&v,1) == 1 { slider = v }
                seq += 1
                let duration = sample.duration.seconds
                lastEnd = due + UInt64((duration.isFinite && duration>0 ? duration : 1/24)*1e9)
                try autoreleasepool {
                    let start = rawTime()
                    let ci = CIImage(cvPixelBuffer: source).transformed(by: transform)
                    let eyeFit = converter.fit(ci, to: converter.eye)
                    let depthFit = converter.fit(ci, to: converter.input)
                    let depth = try converter.predict()
                    try converter.warp(depth, eyeFit: eyeFit, depthFit: depthFit, into: stereo, disparity: Float(slider)*10/255)
                    let data: Data
                    let independent: Bool
                    if let encoder {
                        let pts = CMTime(value: Int64(seq), timescale: max(1,Int32(nominalFPS.rounded())))
                        let (compressed, _) = try encoder.encode(stereo, pts: pts, duration: sample.duration)
                        (data, independent) = try avcPayload(compressed)
                    } else {
                        // Rotated JPEG scanlines match libctru's sideways framebuffer.
                        let rotated = CIImage(cvPixelBuffer: stereo).oriented(.right)
                        guard let jpeg = converter.context.jpegRepresentation(of: rotated, colorSpace: converter.srgb, options: [
                            CIImageRepresentationOption(rawValue:kCGImageDestinationLossyCompressionQuality as String): 0.64
                        ]) else { throw Failure("JPEG encode") }
                        data = jpeg; independent = true
                    }
                    var packet = Data()
                    emit(seq,to:&packet); emit(timeline + (due - anchor!) / 1000, to:&packet); emit(start,to:&packet); emit(rawTime(),to:&packet)
                    emit(UInt32(data.count) | (independent ? 0x80000000 : 0),to:&packet)
                    packet.append(data)
                    try FileHandle.standardOutput.write(contentsOf: packet)
                }
            }
            guard reader.status == .completed, anchor != nil else { throw reader.error ?? Failure("empty or incomplete video") }
            timeline += (lastEnd - anchor!) / 1000
            let end = rawTime()
            if lastEnd > end { try await Task.sleep(nanoseconds:lastEnd-end) }
        }
    }
}
