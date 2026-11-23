import Foundation
import CoreGraphics
import CoreText

/// Deterministic desktop-like workload, explicitly distinct from real capture and noise.
/// Cache text and document rasters once; each frame only scrolls clipped images and a small chart.
final class DesktopPattern {
    private let width: Int, height: Int
    private let background: CGImage, document: CGImage, code: CGImage
    private let documentRect: CGRect, codeRect: CGRect, chartRect: CGRect
    private let statusFont = CTFontCreateWithName("Menlo" as CFString, 18, nil)

    init(width: Int, height: Int) throws {
        self.width = width; self.height = height
        let w = CGFloat(width), h = CGFloat(height)
        let sidebar = max(180, w * 0.105), gap: CGFloat = 24
        let content = w - sidebar - 3 * gap
        documentRect = CGRect(x: sidebar + gap, y: 64, width: floor(content * 0.56), height: h - 160)
        let rightX = documentRect.maxX + gap, rightW = w - rightX - gap
        codeRect = CGRect(x: rightX, y: h * 0.37, width: rightW, height: h * 0.63 - 96)
        chartRect = CGRect(x: rightX, y: 64, width: rightW, height: h * 0.37 - 88)
        guard let bg = Self.context(width, height),
              let doc = Self.context(Int(documentRect.width), height * 2),
              let editor = Self.context(Int(codeRect.width), height * 2) else {
            throw LabError.message("无法创建桌面滚动测试图")
        }
        Self.fill(bg, CGRect(x: 0, y: 0, width: w, height: h), gray: 0.095)
        Self.fill(bg, CGRect(x: 0, y: 48, width: sidebar, height: h - 48), gray: 0.13)
        Self.text(bg, "KKRemote Lab  /  Desktop + scroll  /  SYNTHETIC", x: 26, y: h - 42, size: 22, gray: 0.94)
        for (i, label) in ["WORKSPACE", "Overview", "Documents", "Source code", "Media", "Activity", "Settings"].enumerated() {
            Self.text(bg, label, x: 24, y: h - 126 - CGFloat(i) * 52, size: i == 0 ? 16 : 21, gray: i == 0 ? 0.5 : 0.84)
        }
        Self.fill(bg, documentRect, gray: 0.98); Self.fill(bg, codeRect, gray: 0.055)
        Self.fill(bg, chartRect, gray: 0.15)
        Self.fill(doc, CGRect(x: 0, y: 0, width: documentRect.width, height: CGFloat(height * 2)), gray: 0.98)
        Self.fill(editor, CGRect(x: 0, y: 0, width: codeRect.width, height: CGFloat(height * 2)), gray: 0.055)
        let paragraphs = [
            "Native pixels, readable text, and continuous motion.",
            "A document scrolls while the sidebar remains still.",
            "Small updates should arrive without a growing queue.",
            "ABCDEFGHIJKLMNOPQRSTUVWXYZ  abcdefghijklmnopqrstuvwxyz",
            "0123456789  [] {} () <>  /  + - =  @ # $ % & *",
            "Each run uses the same generated document and timing."
        ]
        let snippets = [
            "struct Workspace {", "    let title = \"Remote workspace\"", "    var windows: [Window] = []",
            "    func render(_ frame: Frame) {", "        viewport.display(frame)", "        metrics.record(frame.timestamp)",
            "    }", "}", "// Fine text and syntax colors", "let position = Point(x: 128, y: 256)"
        ]
        for row in 0..<(height * 2 / 34) {
            let y = CGFloat(height * 2 - 42 - row * 34)
            if row % 12 == 0 {
                Self.text(doc, "Section \(row / 12 + 1)  /  Workspace notes", x: 28, y: y, size: 25, gray: 0.1)
            } else {
                Self.text(doc, String(format: "%03d  ", row + 1) + paragraphs[row % paragraphs.count], x: 28, y: y, size: 19, gray: 0.22)
            }
            Self.text(editor, String(format: "%03d  ", row + 1) + snippets[row % snippets.count], x: 20, y: y, size: 18,
                      color: row % 4 == 0 ? CGColor(red: 0.48, green: 0.78, blue: 1, alpha: 1) : CGColor(gray: 0.85, alpha: 1))
        }
        guard let background = bg.makeImage(), let document = doc.makeImage(), let code = editor.makeImage() else {
            throw LabError.message("无法缓存桌面滚动测试图")
        }
        self.background = background; self.document = document; self.code = code
    }

    func draw(in context: CGContext, frame: Int, fps: Int, megabits: Int) {
        let t = Double(frame) / Double(fps), omega = 2 * Double.pi / 8
        context.draw(background, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Document speed varies continuously between 180 and 660 pixels/s; code scrolls at 180.
        scroll(document, in: documentRect, offset: 420 * t + 240 / omega * (1 - cos(omega * t)), context: context)
        scroll(code, in: codeRect, offset: 180 * t, context: context)
        context.saveGState(); context.clip(to: chartRect.insetBy(dx: 20, dy: 20))
        for series in 0..<3 {
            context.setStrokeColor([CGColor(red: 0.4, green: 0.78, blue: 1, alpha: 1),
                                    CGColor(red: 0.54, green: 0.9, blue: 0.62, alpha: 1),
                                    CGColor(red: 1, green: 0.65, blue: 0.4, alpha: 1)][series])
            context.setLineWidth(2); context.beginPath()
            for point in 0...180 {
                let x = chartRect.minX + 24 + CGFloat(point) / 180 * (chartRect.width - 48)
                let wave = sin(Double(point) * 0.07 + t * 1.5 + Double(series) * 2) * 0.28
                    + sin(Double(point) * 0.23 - t * 0.6) * 0.07
                let y = chartRect.midY + CGFloat(wave) * (chartRect.height - 70)
                if point == 0 { context.move(to: CGPoint(x: x, y: y)) } else { context.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.strokePath()
        }
        context.restoreGState()
        let line = "SYNTHETIC desktop | \(width)x\(height) | target \(fps) fps | ceiling \(megabits) Mbps | frame \(frame)"
        Self.text(context, line, x: 26, y: 17, font: statusFont, color: CGColor(gray: 0.88, alpha: 1))
    }

    private func scroll(_ image: CGImage, in rect: CGRect, offset: Double, context: CGContext) {
        context.saveGState(); context.clip(to: rect); context.interpolationQuality = .none
        let imageHeight = CGFloat(image.height), shift = floor(CGFloat(offset).truncatingRemainder(dividingBy: imageHeight))
        let y = rect.maxY - imageHeight + shift
        context.draw(image, in: CGRect(x: rect.minX, y: y, width: rect.width, height: imageHeight))
        context.draw(image, in: CGRect(x: rect.minX, y: y - imageHeight, width: rect.width, height: imageHeight))
        context.restoreGState()
    }
    private static func context(_ width: Int, _ height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
    }
    private static func fill(_ context: CGContext, _ rect: CGRect, gray: CGFloat) {
        context.setFillColor(CGColor(gray: gray, alpha: 1)); context.fill(rect)
    }
    private static func text(_ context: CGContext, _ string: String, x: CGFloat, y: CGFloat, size: CGFloat, gray: CGFloat) {
        text(context, string, x: x, y: y, size: size, color: CGColor(gray: gray, alpha: 1))
    }
    private static func text(_ context: CGContext, _ string: String, x: CGFloat, y: CGFloat, size: CGFloat, color: CGColor) {
        text(context, string, x: x, y: y, font: CTFontCreateWithName("Menlo" as CFString, size, nil), color: color)
    }
    private static func text(_ context: CGContext, _ string: String, x: CGFloat, y: CGFloat, font: CTFont, color: CGColor) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color]))
        context.textPosition = CGPoint(x: x, y: y); CTLineDraw(line, context)
    }
}
