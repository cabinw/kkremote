import AVFoundation
import VideoToolbox

final class Encoder {
    let session: VTCompressionSession
    init(_ fps: Float, bitrate: Int = 1_500_000, keyInterval: Int? = nil) throws {
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
            kVTCompressionPropertyKey_AverageBitRate: bitrate,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: keyInterval ?? Int(max(1, fps.rounded()))]
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
