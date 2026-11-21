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
    func current() -> Data { lock.lock(); defer { lock.unlock() }; return latest }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fputs("Capture stopped: \(error.localizedDescription)\n", stderr); exit(1)
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let pixels = sample.imageBuffer else { return }
        let ci = CIImage(cvPixelBuffer: pixels)
        guard let data = context.jpegRepresentation(of: ci, colorSpace: color, options: [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.68
        ]), data.count <= 150000 else { return }
        lock.lock(); latest = data; lock.unlock()
    }
}
@main struct Capture {
    @MainActor static func main() async {
        do { try await run() } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    }
    @MainActor static func run() async throws {
        _ = NSApplication.shared
        let catalog = HostWindowCatalog()
        let entries = try await catalog.refresh()
        if CommandLine.arguments.dropFirst().first == "--list" {
            for entry in entries { print("\(entry.number)\t\(entry.label)") }
            return
        }
        guard let arg = CommandLine.arguments.dropFirst().first, let id = UInt32(arg),
              let target = entries.first(where: { $0.number == id }) else { throw LabError.message("Window unavailable") }
        let input = try HostWindowControl(target: target)
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == id && $0.owningApplication?.processID == target.processID })
        else { throw LabError.message("Window closed") }
        let config = SCStreamConfiguration()
        let scale = min(400 / target.widthPoints, 240 / target.heightPoints)
        config.width = max(1, Int((target.widthPoints * scale).rounded()))
        config.height = max(1, Int((target.heightPoints * scale).rounded()))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        config.queueDepth = 3; config.showsCursor = false
        config.ignoreShadowsSingleWindow = true; config.ignoreGlobalClipSingleWindow = true
        let frames = Frames()
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: config, delegate: frames)
        try stream.addStreamOutput(frames, type: .screen, sampleHandlerQueue: DispatchQueue(label: "kkremote.3ds.capture"))
        try await stream.startCapture()
        defer { input.invalidate() }
        var sequence = 0
        // The TLS bridge sends one bounded request, reads one response, then repeats.
        while let line = await Task.detached(operation: { readLine() }).value {
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
