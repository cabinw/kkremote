import Foundation

struct WindowInput: Codable {
    var lease: String
    var sequence: Int
    var kind: String
    var x: Double? = nil
    var y: Double? = nil
    var dx: Double? = nil
    var dy: Double? = nil
    var text: String? = nil
    var focus: String? = nil
    var key: String? = nil
    func valid(width: Double, height: Double) -> Bool {
        guard sequence > 0, !lease.isEmpty else { return false }
        switch kind {
        case "click", "secondary", "scroll":
            guard let x,let y,x.isFinite,y.isFinite,x >= 0,y >= 0,x < width,y < height else { return false }
            if kind == "scroll" { return dx?.isFinite == true && dy?.isFinite == true && abs(dx!) <= 1000 && abs(dy!) <= 1000 }
            return true
        case "focus": return true
        case "insertText": return text.map { !$0.isEmpty && $0.utf16.count <= 4000 && !$0.contains("\0") } == true && focus != nil
        case "key": return ["return","escape","backspace","tab","left","right","up","down","home","end","deleteForward"].contains(key ?? "")
        default: return false
        }
    }
}

struct WindowControlState: Codable {
    var focus: String?
}

#if os(macOS)
import AppKit
import ApplicationServices

/// An optional test-Host executor. No mouse button is held across wire messages.
final class HostWindowControl {
    let lease = UUID().uuidString
    let target: RemoteWindow
    private let application: AXUIElement
    private var window: AXUIElement
    private var active = true
    private var sequence = 0
    private var pending: [(String,WindowInput,TimeInterval,(WindowControlState?,String?)->Void)] = []
    private var processing = false
    private var receipts: [String:(WindowControlState?,String?)] = [:]
    private var focusState: WindowControlState?
    private var buttonPoint: CGPoint?
    private var button: CGMouseButton = .left

    init(target: RemoteWindow) throws {
        precondition(Thread.isMainThread)
        guard AXIsProcessTrusted() else { throw LabError.message("测试 Host 未获辅助功能权限，暂时只能观看") }
        self.target=target;application=AXUIElementCreateApplication(target.processID)
        AXUIElementSetMessagingTimeout(application,0.3)
        let frame=try Self.cgFrame(target)
        let windows=Self.attribute(application,kAXWindowsAttribute) as? [AXUIElement] ?? []
        let matches=windows.filter {
            guard let r=Self.rect($0) else { return false }
            return WindowTitleIdentity.matches(Self.attribute($0,kAXTitleAttribute) as? String ?? "",captureTitle:target.title,application:target.application) &&
                abs(r.minX-frame.minX)<2 && abs(r.minY-frame.minY)<2 && abs(r.width-frame.width)<2 && abs(r.height-frame.height)<2
        }
        guard matches.count == 1 else { throw LabError.message("无法确认输入目标窗口") }
        window=matches[0]
    }
    func invalidate() {
        precondition(Thread.isMainThread)
        active=false;releaseButton();focusState=nil
        let old=pending;pending=[]
        old.forEach { $0.3(nil,"窗口已切换，输入已取消") }
    }
    func enqueue(id: String,input: WindowInput,reply: @escaping (WindowControlState?,String?)->Void) {
        precondition(Thread.isMainThread)
        if let receipt=receipts[id] { reply(receipt.0,receipt.1);return }
        guard active,input.lease == lease,input.sequence > sequence,input.valid(width:target.widthPoints,height:target.heightPoints) else {
            reply(nil,"输入目标或序号已失效，请重新选择窗口");return
        }
        sequence=input.sequence
        guard pending.count < 32 else { reply(nil,"输入过快，已取消过期操作");return }
        receipts[id]=(nil,"输入正在处理，请勿重复发送")
        pending.append((id,input,ProcessInfo.processInfo.systemUptime,reply))
        guard !processing else { return };processing=true
        Task { @MainActor [weak self] in
            guard let self else { return }
            while !self.pending.isEmpty {
                let item=self.pending.removeFirst()
                var state:WindowControlState?,failure:String?
                do {
                    guard self.active,ProcessInfo.processInfo.systemUptime-item.2 < 0.8 else { throw LabError.message("输入已过期，请重试") }
                    // Reserve the ID before executing: a failed partial text edit must not replay.
                    self.receipts[item.0]=(nil,"此输入已执行或结果不确定，请检查窗口")
                    state=try await self.execute(item.1)
                } catch { self.releaseButton();failure=error.localizedDescription }
                self.receipts[item.0]=(state,failure)
                if self.receipts.count > 256 { self.receipts.removeValue(forKey:self.receipts.keys.first!) }
                item.3(state,failure)
            }
            self.processing=false
        }
    }
    private static func attribute(_ element:AXUIElement,_ key:String)->CFTypeRef? {
        var value:CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,key as CFString,&value) == .success else { return nil };return value
    }
    private static func rect(_ element:AXUIElement)->CGRect? {
        guard let p=attribute(element,kAXPositionAttribute),let s=attribute(element,kAXSizeAttribute),
            CFGetTypeID(p)==AXValueGetTypeID(),CFGetTypeID(s)==AXValueGetTypeID() else { return nil }
        var point=CGPoint.zero,size=CGSize.zero
        guard AXValueGetValue(p as! AXValue,.cgPoint,&point),AXValueGetValue(s as! AXValue,.cgSize,&size) else { return nil }
        return CGRect(origin:point,size:size)
    }
    private static func cgFrame(_ target:RemoteWindow) throws -> CGRect {
        guard let info=(CGWindowListCopyWindowInfo(.optionIncludingWindow,target.number) as? [[String:Any]])?.first,
            info[kCGWindowOwnerPID as String] as? Int32 == target.processID,
            let bounds=info[kCGWindowBounds as String] as? NSDictionary,
            let rect=CGRect(dictionaryRepresentation:bounds) else { throw LabError.message("输入窗口已关闭") }
        return rect
    }
    private func validate(focused: Bool = true) throws -> CGRect {
        guard active,AXIsProcessTrusted() else { throw LabError.message("输入会话已停止") }
        let frame=try Self.cgFrame(target)
        guard abs(frame.width-target.widthPoints)<1,abs(frame.height-target.heightPoints)<1,
            let windows=Self.attribute(application,kAXWindowsAttribute) as? [AXUIElement],windows.contains(where:{CFEqual($0,window)}),
            let ax=Self.rect(window),abs(ax.minX-frame.minX)<2,abs(ax.minY-frame.minY)<2,
            abs(ax.width-frame.width)<2,abs(ax.height-frame.height)<2 else { throw LabError.message("窗口尺寸已改变，请重新选择后操作") }
        if focused {
            guard Self.attribute(application,kAXFrontmostAttribute) as? Bool == true,
                let current=Self.attribute(application,kAXFocusedWindowAttribute),CFEqual(current,window) else {
                throw LabError.message("窗口焦点已改变，输入已暂停")
            }
        }
        return frame
    }
    @MainActor private func focus() async throws {
        _=try validate(focused:false)
        // AX can report a focused window before WindowServer finishes raising it.
        // Explicit remote focus must raise the selected window even in that state.
        AXUIElementSetAttributeValue(application,kAXFrontmostAttribute as CFString,kCFBooleanTrue)
        NSRunningApplication(processIdentifier:target.processID)?.activate(options:[.activateIgnoringOtherApps])
        AXUIElementPerformAction(window,kAXRaiseAction as CFString)
        for _ in 0..<20 {
            let frame=try validate(focused:false)
            let center=CGPoint(x:frame.midX,y:frame.midY)
            let windows=CGWindowListCopyWindowInfo(.optionOnScreenOnly,kCGNullWindowID) as? [[String:Any]] ?? []
            let top=windows.first { info in
                guard (info[kCGWindowLayer as String] as? Int) == 0,
                      (info[kCGWindowAlpha as String] as? Double ?? 1)>0,
                      let bounds=info[kCGWindowBounds as String] as? NSDictionary,
                      let rect=CGRect(dictionaryRepresentation:bounds) else { return false }
                return rect.contains(center)
            }
            if top?[kCGWindowNumber as String] as? UInt32 == target.number {
                _=try validate();return
            }
            try await Task.sleep(for:.milliseconds(30))
        }
        NSLog("KKRemote input focus failed target=%u process=%d front=%d",target.number,target.processID,NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)
        throw LabError.message("目标窗口未能置前，请关闭遮挡界面后重试")
    }
    private func mouse(_ type:CGEventType,point:CGPoint,button:CGMouseButton) throws {
        _=try validate()
        guard let event=CGEvent(mouseEventSource:nil,mouseType:type,mouseCursorPosition:point,mouseButton:button) else { throw LabError.message("无法创建点击事件") }
        event.flags=[];event.setIntegerValueField(.mouseEventClickState,value:1)
        try requireUncovered(point)
        event.post(tap:.cghidEventTap)
    }
    private func requireUncovered(_ point:CGPoint) throws {
        guard let windows=CGWindowListCopyWindowInfo(.optionOnScreenOnly,kCGNullWindowID) as? [[String:Any]],
              let top=windows.first(where: { info in
                  guard (info[kCGWindowLayer as String] as? Int) == 0,
                        (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                        let bounds=info[kCGWindowBounds as String] as? NSDictionary,
                        let rect=CGRect(dictionaryRepresentation:bounds) else { return false }
                  return rect.contains(point)
              }),top[kCGWindowNumber as String] as? UInt32 == target.number,
              top[kCGWindowOwnerPID as String] as? Int32 == target.processID else {
            throw LabError.message("目标窗口被遮挡，请移开遮挡窗口后重试")
        }
        // Dock/window-manager adornments can cover the display in CG metadata
        // while remaining hit-test transparent. AX hit testing distinguishes them
        // from a real menu, panel, or another application's interactive overlay.
        var hit:AXUIElement?,pid:pid_t=0
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),Float(point.x),Float(point.y),&hit) == .success,
              let hit,AXUIElementGetPid(hit,&pid) == .success,pid == target.processID else {
            throw LabError.message("点击位置被其他界面占用，请重试")
        }
    }
    private func releaseButton() {
        guard let point=buttonPoint else { return };buttonPoint=nil
        let type:CGEventType=button == .right ? .rightMouseUp:.leftMouseUp
        let event=CGEvent(mouseEventSource:nil,mouseType:type,mouseCursorPosition:point,mouseButton:button)
        event?.flags=[];event?.setIntegerValueField(.mouseEventClickState,value:1);event?.post(tap:.cghidEventTap)
    }
    @MainActor private func click(_ point:CGPoint,right:Bool = false) async throws {
        button=right ? .right:.left
        try mouse(.mouseMoved,point:point,button:button)
        try mouse(right ? .rightMouseDown:.leftMouseDown,point:point,button:button)
        buttonPoint=point
        defer { releaseButton() }
        try await Task.sleep(for:.milliseconds(25))
    }
    private func key(_ code:CGKeyCode,flags:CGEventFlags = []) throws {
        try validateKeyboardWindow()
        for down in [true,false] {
            guard let event=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down) else { throw LabError.message("无法创建按键") }
            event.flags=flags;event.postToPid(target.processID)
        }
    }
    @MainActor private func unicode(_ text:String) async throws {
        let units=Array(text.utf16);var start=0
        while start < units.count {
            try validateKeyboardWindow()
            var end=min(start+20,units.count)
            if end < units.count,(0xD800...0xDBFF).contains(units[end-1]) { end -= 1 }
            let chunk=Array(units[start..<end])
            for down in [true,false] {
                guard let event=CGEvent(keyboardEventSource:nil,virtualKey:0,keyDown:down) else { throw LabError.message("无法创建文字输入") }
                event.flags=[]
                chunk.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength:chunk.count,unicodeString:$0.baseAddress!) }
                event.postToPid(target.processID)
            }
            start=end;try await Task.sleep(for:.milliseconds(10))
        }
    }
    private func renewKeyboardFocus() -> WindowControlState {
        let state=WindowControlState(focus:UUID().uuidString)
        focusState=state;return state
    }
    private func validateKeyboardWindow() throws {
        _=try validate(focused:false)
        // postToPid targets this process, not the Mac's globally frontmost app.
        // Keep the exact focused-window check so dialogs/other windows cannot
        // receive characters intended for the captured window.
        guard let current=Self.attribute(application,kAXFocusedWindowAttribute),CFEqual(current,window) else {
            throw LabError.message("应用内焦点窗口已改变，请重新点击窗口")
        }
    }
    private func validateKeyboard(_ input:WindowInput) throws {
        guard let expected=focusState?.focus,input.focus == expected else { throw LabError.message("输入焦点已失效，请重新点击窗口") }
        try validateKeyboardWindow()
    }
    @MainActor private func insertText(_ text:String) async throws {
        var pending=""
        for character in text.replacingOccurrences(of:"\r\n",with:"\n").replacingOccurrences(of:"\r",with:"\n") {
            if character == "\n" || character == "\t" {
                if !pending.isEmpty { try await unicode(pending);pending="" }
                try key(character == "\n" ? 36:48)
            } else { pending.append(character) }
        }
        if !pending.isEmpty { try await unicode(pending) }
    }
    @MainActor private func execute(_ input:WindowInput) async throws -> WindowControlState {
        switch input.kind {
        case "focus":
            try await focus();return renewKeyboardFocus()
        case "click", "secondary":
            try await focus()
            let frame=try validate()
            try await click(CGPoint(x:frame.minX+input.x!,y:frame.minY+input.y!),right:input.kind == "secondary")
            try await Task.sleep(for:.milliseconds(30))
            return renewKeyboardFocus()
        case "scroll":
            try await focus()
            let frame=try validate()
            guard let event=CGEvent(scrollWheelEvent2Source:nil,units:.pixel,wheelCount:2,wheel1:Int32(input.dy!.rounded()),wheel2:Int32(input.dx!.rounded()),wheel3:0) else { throw LabError.message("无法创建滚动事件") }
            event.location=CGPoint(x:frame.minX+input.x!,y:frame.minY+input.y!)
            try requireUncovered(event.location);event.post(tap:.cghidEventTap)
        case "key":
            try validateKeyboard(input)
            let codes:[String:CGKeyCode] = ["return":36,"escape":53,"backspace":51,"tab":48,"left":123,"right":124,"down":125,"up":126,"home":115,"end":119,"deleteForward":117]
            try key(codes[input.key!]!)
        case "insertText":
            try validateKeyboard(input)
            try await insertText(input.text!)
        default: throw LabError.message("不支持的输入操作，请更新客户端")
        }
        return focusState ?? WindowControlState()
    }
}
#endif
