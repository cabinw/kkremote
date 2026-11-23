import AppKit
import ScreenCaptureKit
import CoreMedia

/// Isolate SCStream delivery from WebRTC, encoding and network backpressure.
final class CadenceOutput: NSObject, SCStreamOutput {
    private let lock = NSLock()
    private var times: [Double] = []
    private var statuses: [Int:Int] = [:]
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo:Any]]
        let status = attachments?.first?[.status] as? Int ?? -1
        lock.lock(); defer { lock.unlock() }
        statuses[status, default:0] += 1
        if status == SCFrameStatus.complete.rawValue { times.append(ProcessInfo.processInfo.systemUptime) }
    }
    func result() -> [String:Any] {
        lock.lock(); defer { lock.unlock() }
        let gaps = zip(times,times.dropFirst()).map { ($1-$0)*1000 }.sorted()
        return ["complete":times.count, "statuses":statuses.map { ["status":$0.key,"count":$0.value] },
                "observedSeconds":times.count>1 ? times.last!-times.first! : 0,
                "fps":times.count>1 ? Double(times.count-1)/(times.last!-times.first!) : 0,
                "maxGapMs":gaps.last ?? 0, "p95GapMs":gaps.isEmpty ? 0 : gaps[Int(ceil(Double(gaps.count)*0.95))-1],
                "scope":"Raw capture delivery only; no encoder, network, frame retention or display."]
    }
}

@main enum CaptureCadenceProbe {
    @MainActor static func main() {
        let args = CommandLine.arguments
        guard (args.count == 5 || (args.count == 6 && args[5] == "--hdr")), let windowID = UInt32(args[1]), let seconds = UInt64(args[2]), (5...120).contains(seconds),
              let depth = Int(args[3]), (3...8).contains(depth), let fps = Int32(args[4]), [0,60,120].contains(fps) else {
            print("Usage: CaptureCadenceProbe WINDOW_ID SECONDS QUEUE_DEPTH INTERVAL_FPS(0/60/120) [--hdr]"); exit(2)
        }
        let hdr = args.count == 6
        _ = NSApplication.shared
        let output = CadenceOutput()
        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:false)
                guard let window = content.windows.first(where:{$0.windowID == windowID}) else { throw NSError(domain:"No capture target",code:1) }
                let config = hdr ? SCStreamConfiguration(preset: .captureHDRStreamCanonicalDisplay) : SCStreamConfiguration()
                config.width=2560;config.height=1440;config.queueDepth=depth
                config.minimumFrameInterval=fps == 0 ? .zero : CMTime(value:1,timescale:fps)
                config.pixelFormat=hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32BGRA;config.showsCursor=false
                config.capturesAudio=false;config.ignoreShadowsSingleWindow=true;config.ignoreGlobalClipSingleWindow=true
                config.preservesAspectRatio=true;config.scalesToFit=true;config.shouldBeOpaque=true
                config.colorSpaceName=hdr ? CGColorSpace.itur_2100_PQ : CGColorSpace.sRGB
                if hdr { config.colorMatrix=kCVImageBufferYCbCrMatrix_ITU_R_2020 } else { config.captureDynamicRange = .SDR }
                let stream = SCStream(filter:SCContentFilter(desktopIndependentWindow:window),configuration:config,delegate:nil)
                try stream.addStreamOutput(output,type:.screen,sampleHandlerQueue:DispatchQueue(label:"cadence-probe",qos:.userInteractive))
                try await stream.startCapture()
                try await Task.sleep(nanoseconds:seconds*1_000_000_000)
                try await stream.stopCapture()
                var result=output.result();result["durationSeconds"]=seconds;result["queueDepth"]=depth;result["intervalFPS"]=fps;result["hdrRequested"]=hdr
                let data=try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]);print(String(decoding:data,as:UTF8.self));exit(0)
            } catch { print("Capture probe failed: \(error.localizedDescription)");exit(1) }
        }
        RunLoop.main.run()
    }
}
