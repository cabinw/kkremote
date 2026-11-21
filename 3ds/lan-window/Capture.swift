import AppKit
import ScreenCaptureKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

enum LabError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let s): return s } }
}

// Producer retains only a single most recent JPEG. Slow Wi-Fi never builds a media queue.
final class Frames: NSObject, SCStreamOutput, SCStreamDelegate {
    private let lock = NSLock()
    private var latest = Data()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let color = CGColorSpace(name: CGColorSpace.sRGB)!
    private let desk: Bool
    private var source: CVPixelBuffer?
    private var revision = 0
    private var cachedRevision = -1
    private var cachedCrop = CGRect.null
    private var cachedJPEG = Data()
    init(desk: Bool) { self.desk = desk }
    private var stopped = false
    func isStopped() -> Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func current() -> Data { lock.lock(); defer { lock.unlock() }; return latest }
    // Called serially by the desktop relay. Keep the captured 2x surface for detail mode.
    func deskJPEG(detail: Bool, x: Int, y: Int) -> Data {
        lock.lock()
        let pixels = source, version = revision
        lock.unlock()
        guard let pixels else { return Data() }
        let ci = CIImage(cvPixelBuffer:pixels)
        let w = Int(ci.extent.width), h = Int(ci.extent.height)
        let left = min(400,max(0,x-200)), top = min(240,max(0,y-120))
        let crop = detail ? CGRect(x:(left*w+400)/800, y:h/2-(top*h+240)/480, width:w/2,height:h/2) : ci.extent
        if version == cachedRevision && crop == cachedCrop { return cachedJPEG }
        var image = ci.cropped(to:crop).transformed(by:CGAffineTransform(translationX:-crop.minX,y:-crop.minY))
        let bounds = CGRect(x:0,y:0,width:w/2,height:h/2)
        if !detail {
            image = image.applyingFilter("CILanczosScaleTransform",parameters:[kCIInputScaleKey:0.5,kCIInputAspectRatioKey:1])
        }
        image = image.clampedToExtent().applyingFilter("CISharpenLuminance",parameters:[kCIInputSharpnessKey:0.28]).cropped(to:bounds)
        let quality = CIImageRepresentationOption(rawValue:kCGImageDestinationLossyCompressionQuality as String)
        for q in [0.93,0.82,0.68] {
            if let data = context.jpegRepresentation(of:image,colorSpace:color,options:[quality:q]), data.count <= 150000 {
                cachedRevision=version; cachedCrop=crop; cachedJPEG=data
                return data
            }
        }
        return Data()
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock(); stopped = true; latest.removeAll(); lock.unlock()
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let pixels = sample.imageBuffer else { return }
        if desk {
            lock.lock(); source=pixels; revision += 1; lock.unlock()
            return
        }
        let ci = CIImage(cvPixelBuffer: pixels)
        guard let data = context.jpegRepresentation(of: ci, colorSpace: color, options: [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.68
        ]), data.count <= 150000 else { return }
        lock.lock(); latest = data; lock.unlock()
    }
}
@MainActor func startWindowFeed(_ target: RemoteWindow, desk: Bool = false) async throws -> (SCStream, Frames) {
    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    guard let window = content.windows.first(where: { $0.windowID == target.number && $0.owningApplication?.processID == target.processID })
    else { throw LabError.message("Window closed") }
    let config = SCStreamConfiguration()
    let scale = min(400 / target.widthPoints, 240 / target.heightPoints)
    config.width = max(1, Int((target.widthPoints * scale).rounded()))
    config.height = max(1, Int((target.heightPoints * scale).rounded()))
    if desk {
        fputs("DESK_GEOMETRY source=\(Int(target.widthPoints))x\(Int(target.heightPoints)) output=\(config.width)x\(config.height)\n",stderr)
        config.width *= 2; config.height *= 2
    }
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
    config.queueDepth = 3; config.showsCursor = false
    config.ignoreShadowsSingleWindow = true; config.ignoreGlobalClipSingleWindow = true
    let frames = Frames(desk:desk)
    let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: config, delegate: frames)
    try stream.addStreamOutput(frames, type: .screen, sampleHandlerQueue: DispatchQueue(label: "kkremote.3ds.capture"))
    try await stream.startCapture()
    return (stream,frames)
}

@main struct Capture {
    @MainActor static func main() async {
        do { try await run() } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    }
    @MainActor static func run() async throws {
        _ = NSApplication.shared
        let catalog = HostWindowCatalog()
        if CommandLine.arguments.dropFirst().first == "--desk" { try await WindowDesk().run(); return }
        let entries = try await catalog.refresh()
        if CommandLine.arguments.dropFirst().first == "--list" {
            for entry in entries { print("\(entry.number)\t\(entry.label)") }
            return
        }
        guard let arg = CommandLine.arguments.dropFirst().first, let id = UInt32(arg),
              let target = entries.first(where: { $0.number == id }) else { throw LabError.message("Window unavailable") }
        let input = try HostWindowControl(target: target)
        let (stream, frames) = try await startWindowFeed(target)
        defer { input.invalidate() }
        var sequence = 0
        // The TLS bridge sends one bounded request, reads one response, then repeats.
        while let line = await Task.detached(operation: { readLine() }).value {
            if frames.isStopped() { throw LabError.message("Window capture stopped") }
            let fields = line.split(separator: " ").compactMap { Int($0) }
            guard fields.count == 3, (0...4).contains(fields[0]), (0..<400).contains(fields[1]),
                  (0..<240).contains(fields[2]) else { throw LabError.message("Invalid input") }
            var status: UInt8 = 0
            if fields[0] != 0 {
                sequence += 1
                let kind = ["", "click", "secondary", "scroll", "scroll"][fields[0]]
                let action = WindowInput(lease: input.lease, sequence: sequence, kind: kind,
                    x: (Double(fields[1])+0.5)*target.widthPoints/400, y: (Double(fields[2])+0.5)*target.heightPoints/240,
                    dx: 0, dy: fields[0] == 3 ? 48 : -48)
                let error: String? = await withCheckedContinuation { reply in
                    input.enqueue(id: String(sequence), input: action) { _, error in reply.resume(returning: error) }
                }
                if let error { fputs("Input refused: \(error)\n", stderr); status = 1 }
                else { fputs("INPUT \(kind) OK\n", stderr) }
            }
            let data = frames.current()
            var length = UInt32(data.count).bigEndian
            var packet = Data([status])
            withUnsafeBytes(of: &length) { packet.append(contentsOf: $0) }
            packet.append(data)
            try FileHandle.standardOutput.write(contentsOf: packet)
        }
        try await stream.stopCapture()
    }
}
