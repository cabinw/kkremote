import Foundation
import VideoToolbox
import WebRTC

/// SDK defaults can limit macOS to Level 3.1 and iOS peers to 4.1, below 1440p60.
/// Advertise High 5.1 on either platform only after VT accepts a hardware session at our maximum preset.
/// Negotiation still chooses the peer's supported level; no SDP profile rewriting.
enum LabH264Capabilities {
    static let codecs: [RTCVideoCodecInfo] = {
        let defaults = RTCVideoEncoderFactoryH264().supportedCodecs()
        guard VTIsHardwareDecodeSupported(kCMVideoCodecType_H264) else { return defaults }
        var session: VTCompressionSession?
        let specification = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary
        guard VTCompressionSessionCreate(allocator: nil, width: 2560, height: 1440, codecType: kCMVideoCodecType_H264,
            encoderSpecification: specification, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session) == noErr, let session else { return defaults }
        defer { VTCompressionSessionInvalidate(session) }
        let settings: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_5_1),
            (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
            (kVTCompressionPropertyKey_ExpectedFrameRate, 60 as CFNumber)
        ]
        guard settings.allSatisfy({ VTSessionSetProperty(session, key: $0.0, value: $0.1) == noErr }),
              VTCompressionSessionPrepareToEncodeFrames(session) == noErr else { return defaults }
        return [RTCVideoCodecInfo(name: "H264", parameters: ["profile-level-id": "640c33",
            "level-asymmetry-allowed": "1", "packetization-mode": "1"])] + defaults
    }()
}

final class LabH264EncoderFactory: NSObject, RTCVideoEncoderFactory {
    private let native = RTCVideoEncoderFactoryH264()
    let telemetry: EncoderTelemetry
    init(telemetry: EncoderTelemetry) { self.telemetry = telemetry }
    func supportedCodecs() -> [RTCVideoCodecInfo] { LabH264Capabilities.codecs }
    func createEncoder(_ info: RTCVideoCodecInfo) -> (any RTCVideoEncoder)? {
        guard let encoder = native.createEncoder(info) else { return nil }
        return MeasuredH264Encoder(native: encoder, telemetry: telemetry)
    }
}

final class LabH264DecoderFactory: NSObject, RTCVideoDecoderFactory {
    private let native = RTCVideoDecoderFactoryH264()
    func supportedCodecs() -> [RTCVideoCodecInfo] { LabH264Capabilities.codecs }
    func createDecoder(_ info: RTCVideoCodecInfo) -> (any RTCVideoDecoder)? { native.createDecoder(info) }
}
