import AppKit

// All typography and app icons are rasterized once on the Mac, including non-Latin window titles.
@MainActor enum DeskArt {
    struct Key {
        let rect: NSRect
        let code: UInt8
        let label: String
    }
    static let bg = NSColor(srgbRed: 0.07, green: 0.10, blue: 0.14, alpha: 1)
    static let surface = NSColor(srgbRed: 0.15, green: 0.20, blue: 0.26, alpha: 1)
    static let accent = NSColor(srgbRed: 0.40, green: 0.91, blue: 0.80, alpha: 1)
    static func fill(_ rect: NSRect, _ color: NSColor, radius: CGFloat = 0) {
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }
    static func label(_ text: String, in rect: NSRect, size: CGFloat, color: NSColor, bold: Bool = false) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let font = NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        let height = ceil(font.ascender - font.descender + font.leading)
        let box = NSRect(x: rect.minX, y: rect.midY-height/2, width: rect.width, height: height)
        (text as NSString).draw(in: box, withAttributes: [.font:font, .foregroundColor:color, .paragraphStyle:paragraph])
    }
    static func jpeg(_ width: Int, _ height: Int, draw: () -> Void) throws -> Data {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else { throw LabError.message("Cannot draw controls") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        fill(NSRect(x:0,y:0,width:width,height:height), bg)
        draw()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.87]) else {
            throw LabError.message("Cannot encode control artwork")
        }
        return data
    }
    static func card(_ window: RemoteWindow) throws -> Data {
        try jpeg(78,62) {
            let icon = NSRunningApplication(processIdentifier:window.processID)?.icon
                ?? NSWorkspace.shared.icon(for: .applicationBundle)
            icon.draw(in:NSRect(x:12,y:4,width:54,height:54))
        }
    }
    static func keyboard(_ page: Int) throws -> Data {
        // Touch geometry uses the same top-left coordinates serialized beside the artwork.
        typealias Item = (String, UInt8, Int)
        func chars(_ text: String) -> [Item] { text.utf8.map { (String(UnicodeScalar($0)), $0, 1) } }
        var rows = [chars(page == 1 ? "!@#$%^&*()" : "1234567890")]
        let alpha = page == 1
        rows.append(chars(page == 2 ? "-/:;()$&@=" : alpha ? "QWERTYUIOP" : "qwertyuiop"))
        rows.append(chars(page == 2 ? "[]{}#%*_+" : alpha ? "ASDFGHJKL" : "asdfghjkl"))
        rows.append([(page == 1 ? "SHIFT" : "Shift",128,2)] + chars(page == 2 ? "!?.,'\\\"~" : alpha ? "ZXCVBNM" : "zxcvbnm") + [("Del",8,2)])
        rows.append([(page == 2 ? "ABC" : "#+=",129,2),("Esc",27,1),("Tab",9,1),("Space",32,4),(".",46,1),("Enter",13,2)])
        var keys = [Key]()
        for (r, items) in rows.enumerated() {
            let units = items.reduce(0) { $0 + $1.2 }
            var offset = 0
            for (label,code,weight) in items {
                let left = 2 + offset*316/units
                offset += weight
                keys.append(Key(rect:NSRect(x:left,y:r*31,width:2+offset*316/units-left,height:31), code:code,label:label))
            }
        }
        let image = try jpeg(320,155) {
            for key in keys {
                let r = NSRect(x:key.rect.minX+1,y:155-key.rect.maxY+2,width:key.rect.width-2,height:key.rect.height-3)
                let special = key.code < 32 || key.code >= 128
                let highlight = key.code == 13 || (key.code == 128 && alpha)
                fill(r, highlight ? accent : surface, radius:5)
                label(key.label,in:r,size:special ? 11 : 15,color:highlight ? bg : .white,bold:special)
            }
        }
        var data = Data([UInt8(keys.count)])
        for key in keys {
            data.u16(Int(key.rect.minX)); data.append(UInt8(key.rect.minY))
            data.append(UInt8(key.rect.width)); data.append(UInt8(key.rect.height)); data.append(key.code)
        }
        try data.blob(image)
        return data
    }
}
extension Data {
    mutating func u16(_ i: Int) { append(UInt8(i >> 8)); append(UInt8(truncatingIfNeeded:i)) }
    mutating func blob(_ item: Data) throws {
        guard item.count <= 65535 else { throw LabError.message("Control artwork too large") }
        u16(item.count); append(item)
    }
}
