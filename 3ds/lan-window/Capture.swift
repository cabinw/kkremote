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
    private let logicalSize: CGSize
    private var cachedWide = false
    init(desk: Bool, logicalSize: CGSize) { self.desk = desk; self.logicalSize = logicalSize }
    private var stopped = false
    func isStopped() -> Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func current() -> Data { lock.lock(); defer { lock.unlock() }; return latest }
    // Top-screen wide pixels have half the width of a normal 3DS pixel.
    func deskJPEG(wide: Bool, zoom: Int, left: Int, top: Int) -> Data {
        lock.lock()
        let pixels = source, version = revision
        lock.unlock()
        guard let pixels else { return Data() }
        let ci = CIImage(cvPixelBuffer:pixels)
        let w = ci.extent.width, h = ci.extent.height
        let spanX = (800 + zoom/2)/zoom, spanY = 480/zoom
        let crop = CGRect(x:CGFloat(left)*w/800, y:CGFloat(480-top-spanY)*h/480,
                          width:CGFloat(spanX)*w/800, height:CGFloat(spanY)*h/480)
        if version == cachedRevision && crop == cachedCrop && wide == cachedWide { return cachedJPEG }
        let bounds = CGRect(x:0,y:0,width:logicalSize.width*(wide ? 2 : 1),height:logicalSize.height)
        let sx = bounds.width/crop.width, sy = bounds.height/crop.height
        // Translate the requested region of the original capture to the output origin.
        // Filtering the clamped source before the final crop also handles fractional edges.
        var image = ci.clampedToExtent().transformed(by:CGAffineTransform(translationX:-crop.minX,y:-crop.minY))
            .applyingFilter("CILanczosScaleTransform",parameters:[kCIInputScaleKey:sy,kCIInputAspectRatioKey:sx/sy])
            .cropped(to:bounds)
        image = image.clampedToExtent().applyingFilter("CISharpenLuminance",parameters:[kCIInputSharpnessKey:0.28]).cropped(to:bounds)
        let quality = CIImageRepresentationOption(rawValue:kCGImageDestinationLossyCompressionQuality as String)
        for q in [0.94,0.86,0.74,0.57] {
            if let data = context.jpegRepresentation(of:image,colorSpace:color,options:[quality:q]), data.count <= 150000 {
                cachedRevision=version; cachedCrop=crop; cachedWide=wide; cachedJPEG=data
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
    let logicalSize = CGSize(width:config.width,height:config.height)
    let filter = SCContentFilter(desktopIndependentWindow:window)
    if desk {
        let backing = max(1,CGFloat(filter.pointPixelScale))
        let density = min(backing, 2400/target.widthPoints, 1440/target.heightPoints)
        config.width = max(1,Int((target.widthPoints*density).rounded()))
        config.height = max(1,Int((target.heightPoints*density).rounded()))
        fputs("DESK_GEOMETRY window=\(Int(target.widthPoints))x\(Int(target.heightPoints)) capture=\(config.width)x\(config.height)\n",stderr)
    }
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
    config.queueDepth = 3; config.showsCursor = false
    config.ignoreShadowsSingleWindow = true; config.ignoreGlobalClipSingleWindow = true
    let frames = Frames(desk:desk,logicalSize:logicalSize)
    let stream = SCStream(filter: filter, configuration: config, delegate: frames)
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
