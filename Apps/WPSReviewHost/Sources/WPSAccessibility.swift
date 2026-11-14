import AppKit
import ApplicationServices

struct WPSFailure: Error, LocalizedError {
    let message: String
    init(_ message:String) { self.message=message }
    var errorDescription: String? { message }
}

@MainActor final class WPSAccessibility {
    let windowID: CGWindowID
    let pid: pid_t
    let title: String
    let application: AXUIElement
    init(windowID: CGWindowID, pid: pid_t, title:String) {
        self.windowID=windowID; self.pid=pid; self.title=title
        application=AXUIElementCreateApplication(pid)
    }
    func attribute(_ element:AXUIElement,_ name:String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,name as CFString,&value) == .success else { return nil }
        return value
    }
    func string(_ element:AXUIElement,_ name:String) -> String { attribute(element,name) as? String ?? "" }
    func rect(_ element:AXUIElement) -> CGRect {
        guard let p=attribute(element,kAXPositionAttribute),let s=attribute(element,kAXSizeAttribute),
              CFGetTypeID(p)==AXValueGetTypeID(),CFGetTypeID(s)==AXValueGetTypeID() else { return .zero }
        var point=CGPoint.zero,size=CGSize.zero
        AXValueGetValue(p as! AXValue,.cgPoint,&point);AXValueGetValue(s as! AXValue,.cgSize,&size)
        return CGRect(origin:point,size:size)
    }
    func window() throws -> AXUIElement {
        guard AXIsProcessTrusted() else { throw WPSFailure("独立测试 Host 需要辅助功能权限") }
        guard let running=NSRunningApplication(processIdentifier:pid),!running.isTerminated,
              running.bundleIdentifier?.lowercased().contains("kingsoft") == true || running.bundleIdentifier?.lowercased().contains("wps") == true else { throw WPSFailure("WPS 测试进程已结束") }
        guard let info=(CGWindowListCopyWindowInfo(.optionIncludingWindow,windowID) as? [[String:Any]])?.first,
              info[kCGWindowOwnerPID as String] as? Int32 == pid,
              info[kCGWindowName as String] as? String == title else { throw WPSFailure("已离开测试工作簿，输入已暂停") }
        let windows=attribute(application,kAXWindowsAttribute) as? [AXUIElement] ?? []
        guard let target=windows.first(where:{ string($0,kAXTitleAttribute)==title }) else { throw WPSFailure("找不到指定的 WPS 测试窗口") }
        return target
    }
    func descendants(_ root:AXUIElement) -> [AXUIElement] {
        var result=[AXUIElement](),queue=[root],index=0
        while index<queue.count && index<700 {
            let item=queue[index];index += 1;result.append(item)
            queue += attribute(item,kAXChildrenAttribute) as? [AXUIElement] ?? []
        }
        return result
    }
    func fields() throws -> (AXUIElement,AXUIElement) {
        let items=descendants(try window())
        guard let name=items.first(where:{ string($0,kAXRoleAttribute)==kAXTextFieldRole &&
            string($0,kAXValueAttribute).range(of:"^[A-Z]{1,3}[1-9][0-9]*(:[A-Z]{1,3}[1-9][0-9]*)?$",options:.regularExpression) != nil }),
              let formula=items.first(where:{ string($0,kAXRoleAttribute)==kAXTextAreaRole && abs(rect($0).midY-rect(name).midY)<35 }) else {
            throw WPSFailure("WPS 公式栏不可用，请保持测试表格的公式栏可见")
        }
        return (name,formula)
    }
    func inspect() throws -> (CGRect,String,String,CGRect) {
        let w=try window(),frame=rect(w),fields=try fields(),f=rect(fields.1)
        return (frame,string(fields.0,kAXValueAttribute),string(fields.1,kAXValueAttribute),
            CGRect(x:f.minX-frame.minX,y:f.minY-frame.minY,width:f.width,height:f.height))
    }
    func resize(viewport:CGSize) async throws -> CGRect {
        try await focusWindow()
        let w=try window()
        guard let screen=NSScreen.screens.max(by:{$0.visibleFrame.height<$1.visibleFrame.height}) else { throw WPSFailure("没有可用显示器") }
        let primaryHeight=NSScreen.screens.first?.frame.height ?? screen.frame.height
        let usable=screen.visibleFrame.insetBy(dx:8,dy:8)
        var position=CGPoint(x:usable.minX,y:primaryHeight-usable.maxY)
        guard let plan=WPSWindowLayout.requested(viewport:viewport,screen:usable.size) else { throw WPSFailure("无效的手机工作区尺寸") }
        var size=plan
        let moved=AXUIElementSetAttributeValue(w,kAXPositionAttribute as CFString,AXValueCreate(.cgPoint,&position)!)
        let resized=AXUIElementSetAttributeValue(w,kAXSizeAttribute as CFString,AXValueCreate(.cgSize,&size)!)
        guard moved == .success,resized == .success else { throw WPSFailure("WPS 拒绝调整窗口尺寸") }
        try await Task.sleep(for:.milliseconds(120))
        let accepted=rect(try window())
        // WPS may enforce a minimum width. Recompute height from that accepted width.
        size=CGSize(width:accepted.width,height:min(2400,accepted.width*viewport.height/viewport.width))
        _=AXUIElementSetAttributeValue(w,kAXSizeAttribute as CFString,AXValueCreate(.cgSize,&size)!)
        try await Task.sleep(for:.milliseconds(180))
        return rect(try window())
    }
    func click(_ point:CGPoint) async throws {
        let previous=try inspect()
        try await focusWindow()
        let state=try inspect(),frame=state.0
        guard abs(previous.0.width-frame.width)<1,abs(previous.0.height-frame.height)<1 else { throw WPSFailure("WPS 窗口尺寸已变化，请重新适配") }
        guard point.x>=24,point.x<frame.width-10,point.y>state.3.maxY+12,point.y<frame.height-45 else {
            throw WPSFailure("请点击表格单元格区域")
        }
        let location=CGPoint(x:frame.minX+point.x,y:frame.minY+point.y)
        try mouse(.mouseMoved,location)
        try mouse(.leftMouseDown,location)
        try await Task.sleep(for:.milliseconds(30))
        try mouse(.leftMouseUp,location)
        try await Task.sleep(for:.milliseconds(100))
        _=try window()
    }
    private func focusWindow() async throws {
        let target=try window()
        AXUIElementSetAttributeValue(application,kAXFrontmostAttribute as CFString,kCFBooleanTrue)
        AXUIElementPerformAction(target,kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier:pid)?.activate(options:[.activateIgnoringOtherApps])
        try await Task.sleep(for:.milliseconds(250))
        _=try window()

    }
    private func mouse(_ type:CGEventType,_ point:CGPoint) throws {
        // WPS's Qt grid does not accept background process-scoped mouse posts.
        // Fail closed if anything else covers the exact test window at this point.
        guard isUncovered(point),
              let event=CGEvent(mouseEventSource:nil,mouseType:type,mouseCursorPosition:point,mouseButton:.left) else { throw WPSFailure("测试窗口被遮挡，请重新点击") }
        event.flags=[];event.setIntegerValueField(.mouseEventClickState,value:1)
        event.post(tap:.cghidEventTap)
    }
    private func isUncovered(_ point:CGPoint)->Bool {
        guard let windows=CGWindowListCopyWindowInfo(.optionOnScreenOnly,kCGNullWindowID) as? [[String:Any]],
              let top=windows.first(where:{ info in
                  guard (info[kCGWindowLayer as String] as? Int)==0,
                        let bounds=info[kCGWindowBounds as String] as? [String:Any],
                        let rect=CGRect(dictionaryRepresentation:bounds as CFDictionary) else { return false }
                  return rect.contains(point)
              }),top[kCGWindowNumber as String] as? UInt32 == windowID else { return false }
        return true
    }
    private func key(_ code:CGKeyCode,flags:CGEventFlags = []) throws {
        _=try window()
        guard attribute(application,kAXFrontmostAttribute) as? Bool == true else { throw WPSFailure("WPS 输入焦点已改变") }
        for down in [true,false] {
            let event=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down)
            event?.flags=flags;event?.postToPid(pid)
        }
    }
    private func insertUnicode(_ text:String) async throws {
        let units=Array(text.utf16)
        var offset=0
        while offset<units.count {
            _=try window()
            guard attribute(application,kAXFrontmostAttribute) as? Bool == true else { throw WPSFailure("WPS 输入焦点已改变") }
            var end=min(offset+20,units.count)
            if end<units.count,(0xD800...0xDBFF).contains(units[end-1]) { end -= 1 }
            let chunk=Array(units[offset..<end])
            for down in [true,false] {
                let event=CGEvent(keyboardEventSource:nil,virtualKey:0,keyDown:down)
                event?.flags=[]
                chunk.withUnsafeBufferPointer { event?.keyboardSetUnicodeString(stringLength:chunk.count,unicodeString:$0.baseAddress!) }
                event?.postToPid(pid)
            }
            offset=end
            try await Task.sleep(for:.milliseconds(10))
        }
    }
    private func clickField(_ field:AXUIElement) async throws {
        let rect=rect(field),point=CGPoint(x:rect.midX,y:rect.midY)
        try mouse(.leftMouseDown,point)
        try await Task.sleep(for:.milliseconds(30))
        try mouse(.leftMouseUp,point)
        try await Task.sleep(for:.milliseconds(80))
    }
    func scroll(dx:Double,dy:Double) async throws {
        guard dx.isFinite,dy.isFinite else { throw WPSFailure("无效滚动坐标") }
        try await focusWindow()
        let state=try inspect(),r=state.0
        let event=CGEvent(scrollWheelEvent2Source:nil,units:.pixel,wheelCount:2,
            wheel1:Int32(max(-800,min(800,dy))),wheel2:Int32(max(-800,min(800,dx))),wheel3:0)
        let point=CGPoint(x:r.midX,y:r.minY+max(state.3.maxY+80,r.height*0.6))
        guard isUncovered(point) else { throw WPSFailure("测试窗口被遮挡，请重新滚动") }
        event?.location=point
        event?.post(tap:.cghidEventTap)
        try await Task.sleep(for:.milliseconds(70))
    }
    func replaceCell(_ expected:String,text:String) async throws {
        guard text.utf16.count<=4000,!text.contains("\n"),!text.contains("\r") else { throw WPSFailure("当前支持单行单元格文字，最多 4000 字符") }
        let fields=try fields()
        guard string(fields.0,kAXValueAttribute)==expected,!expected.contains(":") else { throw WPSFailure("选中的单元格已改变，请重新编辑") }
        try await focusWindow()
        try await clickField(fields.1)
        try key(0,flags:.maskCommand)
        try key(51)
        // The iPhone commits the candidate first. Send only confirmed Unicode, never pinyin.
        try await insertUnicode(text)
        try key(36)
        try await Task.sleep(for:.milliseconds(120))
        // Return advances selection. Navigate back and read the actual cell value before ACK.
        let refreshed=try self.fields()
        try await clickField(refreshed.0)
        try key(0,flags:.maskCommand)
        try await insertUnicode(expected)
        try key(36)
        try await Task.sleep(for:.milliseconds(100))
        let after=try inspect()
        guard after.1==expected,after.2==text else { throw WPSFailure("WPS 尚未确认单元格文字，保留草稿可重试") }
    }
}
