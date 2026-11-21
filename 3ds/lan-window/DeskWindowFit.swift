import AppKit
import ApplicationServices

/// A physical window size lease scoped to the current handheld selection.
@MainActor final class DeskWindowFit {
    let target: RemoteWindow
    let element: AXUIElement
    let original: CGRect
    private var applied: CGRect?

    private static func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,key as CFString,&result) == .success else { return nil }
        return result
    }
    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let p = value(element,kAXPositionAttribute), let s = value(element,kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue,.cgPoint,&point), AXValueGetValue(s as! AXValue,.cgSize,&size) else { return nil }
        return CGRect(origin:point,size:size)
    }
    private static func matches(_ a: CGRect, _ b: CGRect) -> Bool {
        max(abs(a.minX-b.minX),abs(a.minY-b.minY),abs(a.width-b.width),abs(a.height-b.height)) < 1
    }
    private static func cgFrame(_ target: RemoteWindow) -> CGRect? {
        guard let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow,target.number) as? [[String:Any]])?.first,
              info[kCGWindowOwnerPID as String] as? Int32 == target.processID,
              let box = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation:box)
    }
    static func selectedWindow(_ target: RemoteWindow) -> AXUIElement? {
        let app = AXUIElementCreateApplication(target.processID)
        AXUIElementSetMessagingTimeout(app,0.4)
        guard let cg = Self.cgFrame(target),
              let windows = Self.value(app,kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        let candidates = windows.filter { window in
            guard let frame = Self.frame(window), Self.matches(frame,cg) else { return false }
            return WindowTitleIdentity.matches(Self.value(window,kAXTitleAttribute) as? String ?? "",
                                               captureTitle:target.title,application:target.application)
        }
        return candidates.count == 1 ? candidates[0] : nil
    }
    init?(_ target: RemoteWindow) {
        var editable = DarwinBoolean(false)
        guard let window = Self.selectedWindow(target), let cg = Self.cgFrame(target),
              Self.value(window,"AXFullScreen") as? Bool != true,
              AXUIElementIsAttributeSettable(window,kAXSizeAttribute as CFString,&editable) == .success,
              editable.boolValue else { return nil }
        self.target=target; self.element=window; self.original=cg
    }
    private func setSize(_ size: CGSize) -> Bool {
        var size=size
        return AXUIElementSetAttributeValue(element,kAXSizeAttribute as CFString,AXValueCreate(.cgSize,&size)!) == .success
    }
    private func settled() async -> CGRect? {
        try? await Task.sleep(for:.milliseconds(200))
        var previous: CGRect?
        for _ in 0..<15 {
            guard let actual = Self.frame(element), let cg = Self.cgFrame(target) else { return nil }
            if Self.matches(actual,cg), let previous, Self.matches(previous,actual) { return cg }
            previous=actual
            try? await Task.sleep(for:.milliseconds(40))
        }
        return nil
    }
    func fit(width: Int) async {
        let requested = CGSize(width:width,height:width*3/5)
        guard setSize(requested) else { return }
        applied = Self.frame(element)
        guard let actual = await settled() else { return }
        applied = actual
        // Probe the app's own minimum, then choose the smallest enclosing 5:3 size.
        let unit = ceil(max(actual.width/5,actual.height/3))
        let size = CGSize(width:unit*5,height:unit*3)
        if size != actual.size, setSize(size) {
            applied = Self.frame(element)
            if let final = await settled() { applied = final }
        }
    }
    func restore() async {
        guard let applied, let current = Self.cgFrame(target), Self.matches(current,applied),
              let ax = Self.frame(element), Self.matches(ax,current),
              !Self.matches(original,current), setSize(original.size) else { return }
        if let restored = await settled(), restored.size == original.size, restored.origin != original.origin {
            var origin=original.origin
            AXUIElementSetAttributeValue(element,kAXPositionAttribute as CFString,AXValueCreate(.cgPoint,&origin)!)
            _ = await settled()
        }
    }
}
