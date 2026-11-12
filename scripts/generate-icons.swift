import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let directory = root.appendingPathComponent("Apps/TransportLab/Resources/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
var images: [[String: String]] = []
func writeIcon(pixels: Int, filename: String) throws {
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    context.setFillColor(CGColor(red: 0.025, green: 0.065, blue: 0.12, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    context.setStrokeColor(CGColor(red: 0.12, green: 0.87, blue: 0.72, alpha: 1))
    context.setLineWidth(34)
    context.addPath(CGPath(roundedRect: CGRect(x: 155, y: 285, width: 610, height: 475), cornerWidth: 46, cornerHeight: 46, transform: nil))
    context.strokePath()
    context.setStrokeColor(CGColor(red: 0.35, green: 0.63, blue: 1, alpha: 1))
    context.addPath(CGPath(roundedRect: CGRect(x: 375, y: 145, width: 480, height: 350), cornerWidth: 40, cornerHeight: 40, transform: nil))
    context.strokePath()
    context.setFillColor(CGColor(red: 0.12, green: 0.87, blue: 0.72, alpha: 1))
    for x in [220, 270, 320] { context.fillEllipse(in: CGRect(x: x, y: 675, width: 20, height: 20)) }
    context.setLineWidth(16)
    context.setStrokeColor(CGColor(gray: 0.9, alpha: 1))
    context.move(to: CGPoint(x: 470, y: 320)); context.addLine(to: CGPoint(x: 735, y: 320)); context.strokePath()
    let url = directory.appendingPathComponent(filename)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "Icon", code: 1) }
}
try writeIcon(pixels: 1024, filename: "ios-1024.png")
images.append(["idiom": "universal", "platform": "ios", "size": "1024x1024", "filename": "ios-1024.png"])
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let filename = "mac-\(size)-\(scale)x.png"
        try writeIcon(pixels: size * scale, filename: filename)
        images.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": filename])
    }
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("Contents.json"))
try Data("{\"info\":{\"author\":\"xcode\",\"version\":1}}\n".utf8).write(to: directory.deletingLastPathComponent().appendingPathComponent("Contents.json"))
print("Generated Transport Lab app icons")
