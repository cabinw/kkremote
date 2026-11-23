import Foundation
import VideoToolbox
import WebRTC

/// One HEVC access unit. VT uses length-prefixed NALs; WebRTC's H.265 RTP path uses Annex B.
enum HEVCNAL {
    static let start = Data([0, 0, 0, 1])
    static func annexB(_ sample: CMSampleBuffer) -> Data? {
        guard let block = CMSampleBufferGetDataBuffer(sample), let format = CMSampleBufferGetFormatDescription(sample) else { return nil }
        var lengthSize: Int32 = 0, count = 0
        guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
            parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &lengthSize) == noErr,
            (1...4).contains(lengthSize) else { return nil }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let key = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true
        var result = Data()
        if key {
            for index in 0..<count {
                var bytes: UnsafePointer<UInt8>?, size = 0
                guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index,
                    parameterSetPointerOut: &bytes, parameterSetSizeOut: &size, parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil) == noErr, let bytes else { return nil }
                result.append(start); result.append(bytes, count: size)
            }
        }
        let size = CMBlockBufferGetDataLength(block)
        var data = Data(count: size)
        guard data.withUnsafeMutableBytes({ CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: $0.baseAddress!) }) == noErr else { return nil }
        var offset = 0
        while offset < size {
            guard offset + Int(lengthSize) <= size else { return nil }
            var length = 0
            for byte in data[offset..<offset + Int(lengthSize)] { length = (length << 8) | Int(byte) }
            offset += Int(lengthSize)
            guard length >= 2, length <= size - offset else { return nil }
            result.append(start); result.append(data[offset..<offset + length]); offset += length
        }
        return result
    }

    static func split(_ data: Data) -> [Data]? {
        let bytes = [UInt8](data)
        guard bytes.count >= 5, bytes.count <= 16 * 1024 * 1024 else { return nil }
        var ranges: [(Int, Int)] = [], index = 0
        while index + 2 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0 {
                if bytes[index + 2] == 1 { ranges.append((index, index + 3)); index += 3; continue }
                if index + 3 < bytes.count, bytes[index + 2] == 0, bytes[index + 3] == 1 {
                    ranges.append((index, index + 4)); index += 4; continue
                }
            }
            index += 1
        }
        guard ranges.first?.0 == 0 else { return nil }
        var result: [Data] = []
        for i in ranges.indices {
            let end = i + 1 < ranges.count ? ranges[i + 1].0 : bytes.count
            guard end - ranges[i].1 >= 2 else { return nil }
            result.append(Data(bytes[ranges[i].1..<end]))
        }
        return result
    }

    static func format(_ sets: [Int: Data]) -> CMVideoFormatDescription? {
        guard let vps = sets[32], let sps = sets[33], let pps = sets[34] else { return nil }
        var format: CMVideoFormatDescription?
        let status = vps.withUnsafeBytes { v in sps.withUnsafeBytes { s in pps.withUnsafeBytes { p in
            let pointers = [v.bindMemory(to: UInt8.self).baseAddress!, s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
            let sizes = [vps.count, sps.count, pps.count]
            return pointers.withUnsafeBufferPointer { pointers in sizes.withUnsafeBufferPointer { sizes in
                CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: 3,
                    parameterSetPointers: pointers.baseAddress!, parameterSetSizes: sizes.baseAddress!, nalUnitHeaderLength: 4,
                    extensions: nil, formatDescriptionOut: &format)
            }}
        }}}
        return status == noErr ? format : nil
    }
}

enum HDRFormat {
    static let pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    static let codec = RTCVideoCodecInfo(name: "H265", parameters: ["profile-id": "2", "tier-flag": "0", "level-id": "150", "tx-mode": "SRST"])
    /// The first primary video payload is the negotiated codec; parameters must match exactly.
    static func prefersMain10(_ sdp: String) -> Bool {
        let lines = sdp.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let start = lines.firstIndex(where: { $0.hasPrefix("m=video ") }) else { return false }
        let end = lines[(start + 1)...].firstIndex(where: { $0.hasPrefix("m=") }) ?? lines.endIndex
        let section = Array(lines[start..<end])
        let media = lines[start].split(separator: " ")
        guard media.count >= 4, media[1] != "0" else { return false }
        for payload in media.dropFirst(3) {
            guard let map = section.first(where: { $0.hasPrefix("a=rtpmap:\(payload) ") }) else { continue }
            let codec = map.split(separator: " ").dropFirst().first?.split(separator: "/").first?.uppercased()
            if codec == "RTX" { continue }
            guard codec == "H265", let fmtp = section.first(where: { $0.hasPrefix("a=fmtp:\(payload) ") }) else { return false }
            let values = fmtp.dropFirst("a=fmtp:\(payload) ".count).split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            return values.contains("profile-id=2") && !values.contains(where: { $0.hasPrefix("profile-id=") && $0 != "profile-id=2" })
        }
        return false
    }
    static func tag(_ buffer: CVPixelBuffer) {
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
    }
    static func description(_ buffer: CVPixelBuffer) -> [String: String] {
        var result = ["pixelFormat": String(CVPixelBufferGetPixelFormatType(buffer)), "width": String(CVPixelBufferGetWidth(buffer)), "height": String(CVPixelBufferGetHeight(buffer))]
        for (name, key) in [("primaries", kCVImageBufferColorPrimariesKey), ("transfer", kCVImageBufferTransferFunctionKey), ("matrix", kCVImageBufferYCbCrMatrixKey)] {
            result[name] = CVBufferCopyAttachment(buffer, key, nil).map { String(describing: $0) } ?? "missing"
        }
        return result
    }
    static func lumaSamples(_ buffer: CVPixelBuffer) -> [String: Int]? {
        guard CVPixelBufferGetPixelFormatType(buffer) == pixelFormat,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let rowStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) / 2
        let data = base.assumingMemoryBound(to: UInt16.self)
        var minimum = 1023, maximum = 0, non8Bit = 0, count = 0
        for row in stride(from: 0, to: height, by: max(1, height / 32)) {
            for col in stride(from: 0, to: width, by: max(1, width / 64)) {
                let value = Int(data[row * rowStride + col] >> 6)
                minimum = min(minimum, value); maximum = max(maximum, value)
                if value & 3 != 0 { non8Bit += 1 }; count += 1
            }
        }
        return ["minimum": minimum, "maximum": maximum, "non8BitSamples": non8Bit, "sampleCount": count]
    }
}

/// No H.264-specific flags. M157 chooses the H.265 packetizer from the negotiated payload type.
private final class HEVCInfo: NSObject, RTCCodecSpecificInfo {}

final class HEVCEncoder: NSObject, RTCVideoEncoder {
    private let telemetry: EncoderTelemetry?
    private let maximumFrameQP: Int?
    init(telemetry: EncoderTelemetry? = nil, maximumFrameQP: Int? = nil) {
        self.telemetry = telemetry; self.maximumFrameQP = maximumFrameQP; super.init()
    }
    private var session: VTCompressionSession?
    private var callback: RTCVideoEncoderCallback?
    private var fps: Int32 = 60
    func setCallback(_ callback: RTCVideoEncoderCallback?) { self.callback = callback }
    func startEncode(with settings: RTCVideoEncoderSettings, numberOfCores: Int32) -> Int {
        _ = release()
        fps = Int32(settings.maxFramerate)
        let spec = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary
        let attrs = [kCVPixelBufferPixelFormatTypeKey: HDRFormat.pixelFormat, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(settings.width), height: Int32(settings.height),
            codecType: kCMVideoCodecType_HEVC, encoderSpecification: spec, imageBufferAttributes: attrs,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else { return Int(status == 0 ? -1 : status) }
        let properties: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main10_AutoLevel),
            (kVTCompressionPropertyKey_OutputBitDepth, 10 as CFNumber),
            (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
            (kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, (fps * WebRTCRuntime.hevcKeyframeSeconds) as CFNumber),
            (kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_2020),
            (kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ),
            (kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_2020)
        ]
        for (key, value) in properties {
            let result = VTSessionSetProperty(session, key: key, value: value)
            if result != noErr { _ = release(); return Int(result) }
        }
        telemetry?.keyframeInterval(Int(fps * WebRTCRuntime.hevcKeyframeSeconds))
        if let maximumFrameQP {
            guard (0...51).contains(maximumFrameQP),
                  VTSessionSetProperty(session,key:kVTCompressionPropertyKey_MaxAllowedFrameQP,value:maximumFrameQP as CFNumber)==noErr else {
                _ = release(); return -1
            }
        }
        telemetry?.qualityLimit(maximumFrameQP)
        guard setBitrate(settings.startBitrate, framerate: settings.maxFramerate) == 0 else { _ = release(); return -1 }
        return Int(VTCompressionSessionPrepareToEncodeFrames(session))
    }
    func setBitrate(_ bitrateKbit: UInt32, framerate: UInt32) -> Int32 {
        guard let session, bitrateKbit > 0, framerate > 0 else { return -1 }
        fps = Int32(framerate)
        let bits = Int(bitrateKbit) * 1000
        let status = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bits as CFNumber)
        guard status == noErr else { return status }
        // A one-second bound limits burst accumulation without forcing filler traffic.
        return VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: [bits / 8, 1] as CFArray)
    }
    func encode(_ frame: RTCVideoFrame, codecSpecificInfo info: (any RTCCodecSpecificInfo)?, frameTypes: [NSNumber]) -> Int {
        guard let session, let native = frame.buffer as? RTCCVPixelBuffer,
              CVPixelBufferGetPixelFormatType(native.pixelBuffer) == HDRFormat.pixelFormat,
              CVPixelBufferGetWidth(native.pixelBuffer) == Int(frame.width),
              CVPixelBufferGetHeight(native.pixelBuffer) == Int(frame.height) else { return -1 }
        let key = frameTypes.contains { $0.intValue == RTCFrameType.videoFrameKey.rawValue }
        let options = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let timestamp = UInt32(bitPattern: frame.timeStamp), width = frame.width, height = frame.height, ns = frame.timeStampNs
        return Int(VTCompressionSessionEncodeFrame(session, imageBuffer: native.pixelBuffer,
            presentationTimeStamp: CMTime(value: ns, timescale: 1_000_000_000), duration: CMTime(value: 1, timescale: fps),
            frameProperties: options, infoFlagsOut: nil) { [weak self] status, flags, sample in
            guard status == noErr else { self?.telemetry?.failedOutput(timestamp: timestamp, reason: "vt_async_status", status: Int(status)); return }
            guard !flags.contains(.frameDropped) else { self?.telemetry?.failedOutput(timestamp: timestamp, reason: "vt_frame_dropped"); return }
            guard let sample else { self?.telemetry?.failedOutput(timestamp: timestamp, reason: "vt_empty_sample"); return }
            guard let bytes = HEVCNAL.annexB(sample) else { self?.telemetry?.failedOutput(timestamp: timestamp, reason: "annex_b_conversion"); return }
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
            let image = RTCEncodedImage()
            image.buffer = bytes; image.encodedWidth = width; image.encodedHeight = height
            image.timeStamp = timestamp; image.captureTimeMs = ns / 1_000_000
            image.frameType = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool == true ? .videoFrameDelta : .videoFrameKey
            image.qp = -1; image.contentType = .screenshare
            _ = self?.callback?(image, HEVCInfo())
        })
    }
    func release() -> Int {
        if let session { VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid); VTCompressionSessionInvalidate(session) }
        session = nil; return 0
    }
    deinit { _ = release() }
    func implementationName() -> String { "KKRemote-VT-HEVC-Main10" }
    func scalingSettings() -> RTCVideoEncoderQpThresholds? { nil }
    var resolutionAlignment: Int { 2 }
    var applyAlignmentToAllSimulcastLayers: Bool { false }
    var supportsNativeHandle: Bool { true }
}

final class HEVCDecoder: NSObject, RTCVideoDecoder {
    private let telemetry: ReceiverTelemetry?
    init(telemetry: ReceiverTelemetry? = nil) { self.telemetry = telemetry; super.init() }
    private var session: VTDecompressionSession?
    private var callback: RTCVideoDecoderCallback?
    private var sets: [Int: Data] = [:]
    private var format: CMVideoFormatDescription?
    func setCallback(_ callback: @escaping RTCVideoDecoderCallback) { self.callback = callback }
    func startDecode(withNumberOfCores numberOfCores: Int32) -> Int { 0 }
    func decode(_ image: RTCEncodedImage, missingFrames: Bool, codecSpecificInfo info: (any RTCCodecSpecificInfo)?, renderTimeMs: Int64) -> Int {
        func fail(_ reason: String, _ status: Int = -1) -> Int {
            telemetry?.failed(image.timeStamp, reason: reason, status: status); return status
        }
        guard let nals = HEVCNAL.split(image.buffer) else { return fail("hevc_annex_b_invalid") }
        var changed = false, payload = Data(), isKey = false
        for nal in nals {
            let type = Int((nal[0] >> 1) & 0x3f)
            if (32...34).contains(type) {
                if sets[type] != nal { sets[type] = nal; changed = true }
            } else {
                if (16...23).contains(type) { isKey = true }
                var count = UInt32(nal.count).bigEndian
                withUnsafeBytes(of: &count) { payload.append(contentsOf: $0) }; payload.append(nal)
            }
        }
        if changed || session == nil {
            guard isKey else { return fail("hevc_keyframe_required") }
            guard let next = HEVCNAL.format(sets) else { return fail("hevc_parameter_sets_invalid") }
            invalidate(); format = next
            let spec = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true] as CFDictionary
            let attrs = [kCVPixelBufferPixelFormatTypeKey: HDRFormat.pixelFormat,
                         kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
            let result = VTDecompressionSessionCreate(allocator: nil, formatDescription: next, decoderSpecification: spec,
                imageBufferAttributes: attrs, outputCallback: nil, decompressionSessionOut: &session)
            guard result == noErr else { return fail("vt_decoder_session_create", Int(result)) }
            if let session { _ = VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue) }
        }
        guard let session, let format, !payload.isEmpty else { return fail("hevc_empty_payload_or_session") }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: payload.count,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: payload.count, flags: 0,
            blockBufferOut: &block) == noErr, let block else { return fail("decode_block_create") }
        guard payload.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: payload.count) }) == noErr else { return fail("decode_block_copy") }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: Int64(image.timeStamp), timescale: 90_000), decodeTimeStamp: .invalid)
        var size = payload.count, sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sample) == noErr, let sample else { return fail("decode_sample_create") }
        let timestamp = image.timeStamp
        telemetry?.vt(.decodeVTSubmit, timestamp: timestamp)
        let result = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil) { [weak self] status, flags, buffer, pts, duration in
            guard let self else { return }
            self.telemetry?.vt(.decodeVTOutput, timestamp: timestamp, status: Int(status))
            guard status == noErr else { self.telemetry?.failed(timestamp, reason: "vt_decode_async_status", status: Int(status)); return }
            guard !flags.contains(.frameDropped) else { self.telemetry?.failed(timestamp, reason: "vt_decode_frame_dropped"); return }
            guard let buffer else { self.telemetry?.failed(timestamp, reason: "vt_decode_empty_buffer"); return }
            guard CVPixelBufferGetPixelFormatType(buffer) == HDRFormat.pixelFormat else { self.telemetry?.failed(timestamp, reason: "vt_decode_pixel_format_mismatch"); return }
            let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0,
                timeStampNs: Int64(timestamp) * 1_000_000_000 / 90_000)
            frame.timeStamp = Int32(bitPattern: timestamp)
            self.callback?(frame)
        }
        if result != noErr { return fail("vt_decode_submission", Int(result)) }
        return Int(result)
    }
    private func invalidate() {
        if let session { VTDecompressionSessionWaitForAsynchronousFrames(session); VTDecompressionSessionInvalidate(session) }
        session = nil; format = nil
    }
    func release() -> Int { invalidate(); sets.removeAll(); return 0 }
    deinit { invalidate() }
    func implementationName() -> String { "KKRemote-VT-HEVC-Main10" }
}

final class HEVCEncoderFactory: NSObject, RTCVideoEncoderFactory {
    let telemetry: EncoderTelemetry
    init(telemetry: EncoderTelemetry) { self.telemetry = telemetry }
    func supportedCodecs() -> [RTCVideoCodecInfo] { [HDRFormat.codec] + LabH264Capabilities.codecs }
    func createEncoder(_ info: RTCVideoCodecInfo) -> (any RTCVideoEncoder)? {
        if info.name == "H264" { return LabH264EncoderFactory(telemetry: telemetry).createEncoder(info) }
        guard info.name == "H265", info.parameters["profile-id"] == "2" else { return nil }
        return MeasuredH264Encoder(native: HEVCEncoder(telemetry: telemetry, maximumFrameQP: WebRTCRuntime.hevcMaximumFrameQP), telemetry: telemetry)
    }
}
final class HEVCDecoderFactory: NSObject, RTCVideoDecoderFactory {
    private let telemetry: ReceiverTelemetry?
    init(telemetry: ReceiverTelemetry? = nil) { self.telemetry = telemetry }
    func supportedCodecs() -> [RTCVideoCodecInfo] {
        (Main10Capability.canDecode ? [HDRFormat.codec] : []) + LabH264Capabilities.codecs
    }
    func createDecoder(_ info: RTCVideoCodecInfo) -> (any RTCVideoDecoder)? {
        if info.name == "H265" {
            guard info.parameters["profile-id"] == "2" else { return nil }
            let native = HEVCDecoder(telemetry: telemetry)
            if let telemetry { return MeasuredVideoDecoder(native: native, telemetry: telemetry) }
            return native
        }
        return LabH264DecoderFactory(telemetry: telemetry).createDecoder(info)
    }
}

enum Main10Capability {
    /// Test an actual 1440p Main10 access unit, not just the generic HEVC hardware flag.
    static let canDecode: Bool = {
        guard VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC),
              let url = Bundle.main.url(forResource: "Main10Probe", withExtension: "hevc"),
              let data = try? Data(contentsOf: url) else { return false }
        let decoder = HEVCDecoder(), done = DispatchSemaphore(value: 0), lock = NSLock()
        var valid = false
        decoder.setCallback { frame in
            let format = (frame.buffer as? RTCCVPixelBuffer).map { HDRFormat.description($0.pixelBuffer) }
            lock.lock(); valid = format?["pixelFormat"] == String(HDRFormat.pixelFormat)
                && format?["transfer"] == "SMPTE_ST_2084_PQ" && format?["primaries"] == "ITU_R_2020"; lock.unlock()
            done.signal()
        }
        _ = decoder.startDecode(withNumberOfCores: 1)
        let image = RTCEncodedImage(); image.buffer = data; image.timeStamp = 0; image.frameType = .videoFrameKey
        image.encodedWidth = 2560; image.encodedHeight = 1440
        guard decoder.decode(image, missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0) == 0 else { _ = decoder.release(); return false }
        let completed = done.wait(timeout: .now() + 2) == .success
        _ = decoder.release()
        lock.lock(); defer { lock.unlock() }; return completed && valid
    }()
}
