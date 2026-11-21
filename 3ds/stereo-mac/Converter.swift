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
    func warp(_ depth: CVPixelBuffer, eyeFit: Fit, depthFit: Fit, into output: CVPixelBuffer, disparity: Float = 6) throws {
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
                let shift = Int(((near - 0.5) * disparity).rounded())
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
