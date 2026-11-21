import AppKit
import CoreText
import ApplicationServices

// Read only static text in a scrollable content area of the selected PopAgent window.
@MainActor final class PopReader {
    let windowID: String
    private var text = ""
    private var document: ReadingPages?
    private var nextRefresh: TimeInterval = 0
    private var cachedPage = -1
    private var jpeg = Data()

    init(windowID: String) { self.windowID = windowID }

    private static func body(_ window: AXUIElement) -> String {
        func attribute(_ node: AXUIElement, _ key: String) -> CFTypeRef? {
            var result: CFTypeRef?
            AXUIElementCopyAttributeValue(node,key as CFString,&result)
            return result
        }
        var areas = [[String]](), visited = 0
        func scan(_ node: AXUIElement, _ area: Int?, _ depth: Int) {
            guard depth < 40, visited < 8000 else { return }
            visited += 1
            let role = attribute(node,kAXRoleAttribute) as? String ?? ""
            if role == kAXStaticTextRole {
                if let area, let value = attribute(node,kAXValueAttribute) as? String {
                    let block = value.trimmingCharacters(in:.whitespacesAndNewlines)
                    if !block.isEmpty { areas[area].append(block) }
                }
                return
            }
            if [kAXButtonRole,kAXMenuButtonRole,kAXTextFieldRole,kAXTextAreaRole,kAXScrollBarRole,
                kAXToolbarRole,kAXOutlineRole,kAXMenuRole].contains(role) { return }
            var content = area
            if role == kAXScrollAreaRole && content == nil { content=areas.count; areas.append([]) }
            for child in attribute(node,kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                scan(child,content,depth+1)
            }
        }
        scan(window,nil,0)
        return areas.map{$0.joined(separator:"\n\n")}.max(by:{$0.utf16.count < $1.utf16.count}) ?? ""
    }

    func response(target: RemoteWindow, page: Int, reported: Bool) throws -> Data {
        let now = ProcessInfo.processInfo.systemUptime
        if now >= nextRefresh {
            let pop = target.application.caseInsensitiveCompare("PopAgent") == .orderedSame
            let body = pop ? DeskWindowFit.selectedWindow(target).map(Self.body) ?? "" : ""
            let value = !body.isEmpty ? body : (pop ? "当前窗口没有可读取的对话正文。" : "请选择 PopAgent 的对话窗口。")
            if value != text {
                document = try ReadingPages(value)
                text = value
                cachedPage = -1
            }
            nextRefresh = now + 1.5
        }
        guard let document else { throw LabError.message("Reader unavailable") }
        let index = min(page,document.starts.count-1)
        let changed = index != cachedPage
        if changed { jpeg = try document.render(index); cachedPage = index }
        var result = Data()
        result.u16(index); result.u16(document.starts.count)
        if changed || !reported { result.append(jpeg) }
        return result
    }
}

@MainActor struct ReadingPages {
    let framesetter: CTFramesetter
    let starts: [Int]
    static let path = CGPath(rect:CGRect(x:12,y:9,width:376,height:222), transform:nil)
    init(_ text: String) throws {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.lineSpacing = 2
        style.paragraphSpacing = 4
        let content = NSAttributedString(string:text,attributes:[.font:NSFont.systemFont(ofSize:20,weight:.regular),
            .foregroundColor:NSColor.white,.paragraphStyle:style])
        framesetter = CTFramesetterCreateWithAttributedString(content)
        var offsets = [Int](), offset = 0
        while offset < content.length {
            let frame = CTFramesetterCreateFrame(framesetter,CFRange(location:offset,length:0), Self.path,nil)
            let length = CTFrameGetVisibleStringRange(frame).length
            guard length > 0, offsets.count < 65535 else { throw LabError.message("Text pagination failed") }
            offsets.append(offset); offset += length
        }
        starts = offsets.isEmpty ? [0] : offsets
    }
    func render(_ page: Int) throws -> Data {
        let frame = CTFramesetterCreateFrame(framesetter,CFRange(location:starts[page],length:0),Self.path,nil)
        return try DeskArt.jpeg(800,240) {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            context.scaleBy(x:2,y:1)
            context.textMatrix = .identity
            CTFrameDraw(frame,context)
        }
    }
}
