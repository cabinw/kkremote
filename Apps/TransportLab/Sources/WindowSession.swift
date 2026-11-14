import Foundation

/// Window viewing and optional layout protocol carried by the existing authenticated TLS session.
/// Handles are session/catalog scoped. Input additionally requires an explicit control capability and a fresh lease.
struct RemoteWindow: Codable, Identifiable, Equatable {
    let id: String
    let number: UInt32
    let processID: Int32
    let application: String
    let title: String
    let widthPoints: Double
    let heightPoints: Double
    var label: String { title.isEmpty ? application : "\(application) · \(title)" }
}

struct WindowViewport: Codable, Equatable {
    let width: Double
    let height: Double
    /// Physical pixels per client point; absent on older clients. Never an AX size.
    var displayScale: Double? = nil
    var isValid: Bool {
        width.isFinite && height.isFinite && (200...2000).contains(width) && (150...2000).contains(height) &&
        (displayScale.map { $0.isFinite && (1...3).contains($0) } ?? true)
    }
}

struct WindowMessage: Codable {
    static let version = 1
    var version = Self.version
    var action: String
    var requestID: String
    var windowID: String? = nil
    var windows: [RemoteWindow]? = nil
    var selected: RemoteWindow? = nil
    var mediaSession: String? = nil
    var error: String? = nil
    var viewport: WindowViewport? = nil
    var controlLease: String? = nil
    var input: WindowInput? = nil
    var controlState: WindowControlState? = nil
}

#if os(macOS)
import ScreenCaptureKit
import AppKit
import ApplicationServices

final class HostWindowCatalog {
    private var entries: [String: RemoteWindow] = [:]

    func refresh() async throws -> [RemoteWindow] {
        // Only advertise windows on the current desktop. Hidden helper/autofill
        // surfaces otherwise look selectable but can produce no captured frames.
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let windows = content.windows.filter {
            $0.windowLayer == 0 && $0.frame.width > 100 && $0.frame.height > 100 &&
            $0.owningApplication != nil && $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier
        }.prefix(128).map { window in
            RemoteWindow(id: UUID().uuidString, number: window.windowID,
                processID: window.owningApplication!.processID,
                application: String(window.owningApplication!.applicationName.prefix(64)),
                title: String((window.title ?? "").prefix(128)),
                widthPoints: window.frame.width, heightPoints: window.frame.height)
        }.sorted { ($0.application, $0.title, $0.number) < ($1.application, $1.title, $1.number) }
        // A fresh directory invalidates old unselected handles, including after close/reopen.
        entries = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        return windows
    }

    func resolve(_ handle: String) async throws -> RemoteWindow {
        guard let entry = entries[handle] else { throw LabError.message("窗口列表已更新，请刷新后重新选择") }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard let window = content.windows.first(where: { $0.windowID == entry.number &&
            $0.owningApplication?.processID == entry.processID && $0.windowLayer == 0 }) else {
            entries.removeValue(forKey: handle)
            throw LabError.message("窗口已关闭或不可捕获，请刷新列表")
        }
        return RemoteWindow(id:entry.id,number:entry.number,processID:entry.processID,
            application:entry.application,title:entry.title,widthPoints:window.frame.width,heightPoints:window.frame.height)
    }

    func current(_ entry: RemoteWindow) async throws -> RemoteWindow {
        // Selected handles survive a directory refresh, but never a process/window replacement.
        let content = try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:false)
        guard let window = content.windows.first(where: { $0.windowID == entry.number &&
            $0.owningApplication?.processID == entry.processID && $0.windowLayer == 0 }) else {
            throw LabError.message("窗口已关闭或不可捕获")
        }
        return RemoteWindow(id:entry.id,number:entry.number,processID:entry.processID,
            application:entry.application,title:entry.title,widthPoints:window.frame.width,heightPoints:window.frame.height)
    }
}

/// Explicitly enabled test-Host capability. Only resizes the authenticated selected
/// window; no keyboard, pointer injection or arbitrary AX commands are exposed.
@MainActor enum HostWindowLayout {
    private struct NativeLease {
        let target:RemoteWindow
        let element:AXUIElement
        let original:CGRect
        var applied:CGRect?
    }
    private static var nativeLeases:[String:NativeLease]=[:]
    private static var restorations:[String:(id:UUID,task:Task<Void,Never>)]=[:]
    private static func key(_ target:RemoteWindow)->String {"\(target.processID):\(target.number)"}
    private static func nativeRect(_ element:AXUIElement)->CGRect? {
        var p:CFTypeRef?,s:CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,kAXPositionAttribute as CFString,&p) == .success,
              AXUIElementCopyAttributeValue(element,kAXSizeAttribute as CFString,&s) == .success,
              let p,let s,CFGetTypeID(p)==AXValueGetTypeID(),CFGetTypeID(s)==AXValueGetTypeID() else{return nil}
        var point=CGPoint.zero,size=CGSize.zero
        guard AXValueGetValue(p as! AXValue,.cgPoint,&point),AXValueGetValue(s as! AXValue,.cgSize,&size) else{return nil}
        return CGRect(origin:point,size:size)
    }
    /// Release only windows moved by this native session. Respect a subsequent
    /// local user move; never restore another process or a replacement window.
    @discardableResult static func restoreNativeWindows(except keep:RemoteWindow? = nil)->Task<Void,Never> {
        for id in Array(nativeLeases.keys) where keep.map({key($0) != id}) ?? true {
            guard let lease=nativeLeases.removeValue(forKey:id) else{continue}
            let token=UUID()
            let task=Task { @MainActor in
                defer {if restorations[id]?.id==token {restorations.removeValue(forKey:id)}}
                await restore(lease,key:id,token:token)
            }
            restorations[id]=(token,task)
        }
        let pending=restorations.filter { entry in keep.map{key($0) != entry.key} ?? true }.map{ $0.value.task }
        return Task { @MainActor in for task in pending {await task.value} }
    }
    private static func sameFrame(_ a:CGRect,_ b:CGRect)->Bool {
        max(abs(a.minX-b.minX),abs(a.minY-b.minY),abs(a.width-b.width),abs(a.height-b.height))<1
    }
    private static func restore(_ lease:NativeLease,key id:String,token:UUID) async {
        func valid()->Bool {
            guard restorations[id]?.id==token,nativeLeases[id]==nil,
                  let info=(CGWindowListCopyWindowInfo(.optionIncludingWindow,lease.target.number) as? [[String:Any]])?.first,
                  info[kCGWindowOwnerPID as String] as? Int32==lease.target.processID else{return false}
            var windows:CFTypeRef?
            return AXUIElementCopyAttributeValue(AXUIElementCreateApplication(lease.target.processID),kAXWindowsAttribute as CFString,&windows) == .success &&
                (windows as? [AXUIElement])?.contains(where:{CFEqual($0,lease.element)})==true
        }
        func settled(_ expected:CGRect) async -> CGRect? {
            try? await Task.sleep(for:.milliseconds(200))
            for _ in 0..<20 {
                guard valid(),let ax=nativeRect(lease.element),
                      let info=(CGWindowListCopyWindowInfo(.optionIncludingWindow,lease.target.number) as? [[String:Any]])?.first,
                      let bounds=info[kCGWindowBounds as String] as? NSDictionary,
                      let cg=CGRect(dictionaryRepresentation:bounds) else{return nil}
                if sameFrame(ax,cg),sameFrame(ax,expected){return ax}
                try? await Task.sleep(for:.milliseconds(50))
            }
            return nil
        }
        func log(_ status:String){print("NATIVE_WINDOW_RESTORE \(status) target=\(lease.target.number) expected=\(lease.original) actual=\(String(describing:nativeRect(lease.element)))");fflush(stdout)}
        guard valid(),let current=nativeRect(lease.element),
              lease.applied.map({sameFrame(current,$0)}) ?? true else{log("skipped_changed_window");return}
        let primaryTop=NSScreen.screens.first?.frame.maxY ?? 0
        guard NSScreen.screens.contains(where:{screen in
            let r=screen.frame;let ax=CGRect(x:r.minX,y:primaryTop-r.maxY,width:r.width,height:r.height)
            return ax.contains(CGPoint(x:lease.original.midX,y:lease.original.minY+10))
        }) else{log("skipped_missing_display");return}
        // A wide original cannot be restored while still on a narrow virtual
        // display. First shrink to a size that fits both, move, then grow.
        var size=CGSize(width:min(current.width,lease.original.width),height:min(current.height,lease.original.height))
        guard AXUIElementSetAttributeValue(lease.element,kAXSizeAttribute as CFString,AXValueCreate(.cgSize,&size)!) == .success,
              let compact=await settled(CGRect(origin:current.origin,size:size)),valid(),let beforeMove=nativeRect(lease.element),sameFrame(beforeMove,compact) else{log("failed_shrink");return}
        var point=lease.original.origin
        guard AXUIElementSetAttributeValue(lease.element,kAXPositionAttribute as CFString,AXValueCreate(.cgPoint,&point)!) == .success,
              let moved=await settled(CGRect(origin:point,size:compact.size)),valid(),let beforeGrow=nativeRect(lease.element),sameFrame(beforeGrow,moved) else{log("failed_move");return}
        size=lease.original.size
        guard AXUIElementSetAttributeValue(lease.element,kAXSizeAttribute as CFString,AXValueCreate(.cgSize,&size)!) == .success,
              await settled(lease.original) != nil,valid() else{log("failed_expand");return}
        guard valid(),let final=nativeRect(lease.element),sameFrame(final,lease.original) else{log("failed_verify");return}
        log("verified")
    }
    static func resize(_ target: RemoteWindow, viewport: WindowViewport, workspaceDisplayID:UInt32? = nil,
                       maximumPixels:CGFloat = 2560*1440, isCurrent:()->Bool = {true}) async throws {
        guard viewport.isValid else { throw LabError.message("无效的手机工作区尺寸") }
        // A rapid reconnect/reselect must not race a previous session's restore.
        if let previous=restorations[key(target)] {await previous.task.value}
        guard isCurrent() else {throw LabError.message("窗口请求已取消")}
        guard AXIsProcessTrusted() else { throw LabError.message("测试 Host 需要辅助功能权限才能自动调整窗口；当前完整缩放显示") }
        func attribute(_ element: AXUIElement,_ key: String) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element,key as CFString,&value) == .success else { return nil }
            return value
        }
        func rect(_ element: AXUIElement) -> CGRect? {
            guard let p=attribute(element,kAXPositionAttribute),let s=attribute(element,kAXSizeAttribute),
                  CFGetTypeID(p)==AXValueGetTypeID(),CFGetTypeID(s)==AXValueGetTypeID() else { return nil }
            var point=CGPoint.zero,size=CGSize.zero
            guard AXValueGetValue(p as! AXValue,.cgPoint,&point),AXValueGetValue(s as! AXValue,.cgSize,&size) else { return nil }
            return CGRect(origin:point,size:size)
        }
        func resolve(known: AXUIElement? = nil) throws -> AXUIElement {
            guard let info=(CGWindowListCopyWindowInfo(.optionIncludingWindow,target.number) as? [[String:Any]])?.first,
                info[kCGWindowOwnerPID as String] as? Int32 == target.processID,
                let bounds=info[kCGWindowBounds as String] as? NSDictionary,
                let frame=CGRect(dictionaryRepresentation:bounds) else { throw LabError.message("窗口身份已失效") }
            let app=AXUIElementCreateApplication(target.processID)
            AXUIElementSetMessagingTimeout(app,1)
            let matches=(attribute(app,kAXWindowsAttribute) as? [AXUIElement] ?? []).filter {
                guard let r=rect($0),let title=attribute($0,kAXTitleAttribute) as? String else { return false }
                guard WindowTitleIdentity.matches(title,captureTitle:target.title,application:target.application) else { return false }
                // During AppKit resize animation, CG reports the presentation frame
                // while AX reports the destination frame. Retain the exact AX object
                // resolved before mutation, verifying it still belongs to this app.
                if let known { return CFEqual($0,known) }
                return abs(r.minX-frame.minX)<2 && abs(r.minY-frame.minY)<2 && abs(r.width-frame.width)<2 && abs(r.height-frame.height)<2
            }
            guard matches.count == 1 else {
                let candidates=(attribute(app,kAXWindowsAttribute) as? [AXUIElement] ?? []).map {
                    "titleMatch=\(String((attribute($0,kAXTitleAttribute) as? String ?? "").prefix(128)) == target.title) frame=\(String(describing:rect($0)))"
                }
                print("WINDOW_LAYOUT_IDENTITY target=\(target.number) cg=\(frame) matches=\(matches.count) ax=\(candidates)");fflush(stdout)
                throw LabError.message("无法唯一识别所选窗口，保持完整缩放显示")
            }
            return matches[0]
        }
        let window=try resolve()
        guard let frame=rect(window),let primary=NSScreen.screens.first else { throw LabError.message("无法读取窗口尺寸") }
        // Keep the window on its own display; use screen coordinates understood by AX.
        let screens=NSScreen.screens.map { screen -> (NSScreen,CGRect) in
            let margin:CGFloat=workspaceDisplayID == nil ? 8:4
            let r=screen.visibleFrame.insetBy(dx:margin,dy:margin)
            return (screen,CGRect(x:r.minX,y:primary.frame.maxY-r.maxY,width:r.width,height:r.height))
        }
        let destination:(NSScreen,CGRect)
        if let workspaceDisplayID {
            guard let screen=screens.first(where:{($0.0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value==workspaceDisplayID}) else {throw LabError.message("原生像素工作区已不可用")}
            destination=screen
        } else {destination=screens.max { a,b in
            let x=a.1.intersection(frame),y=b.1.intersection(frame)
            return (x.isNull ? 0:x.width*x.height) < (y.isNull ? 0:y.width*y.height)
        }!}
        let usable=destination.1
        let requested:CGSize
        if workspaceDisplayID != nil {
            guard let scale=viewport.displayScale,
                  let points=MobileWindowSizing.nativeSourcePoints(viewport:CGSize(width:viewport.width,height:viewport.height),displayScale:CGFloat(scale),nativeScale:destination.0.backingScaleFactor,maximumPixels:maximumPixels,availablePoints:usable.size) else {
                throw LabError.message("工作区或像素预算不足以原生覆盖客户端；未使用插值替代")
            }
            requested=points
            if nativeLeases[key(target)]==nil {nativeLeases[key(target)]=NativeLease(target:target,element:window,original:frame)}
            func settle(_ expected:CGRect,phase:String) async throws {
                try await Task.sleep(for:.milliseconds(200))
                for _ in 0..<40 {
                    guard isCurrent() else {throw LabError.message("窗口请求已取消")}
                    let element=try resolve(known:window)
                    if let ax=rect(element),
                       let info=(CGWindowListCopyWindowInfo(.optionIncludingWindow,target.number) as? [[String:Any]])?.first,
                       let bounds=info[kCGWindowBounds as String] as? NSDictionary,
                       let actual=CGRect(dictionaryRepresentation:bounds),
                       sameFrame(ax,expected),sameFrame(actual,expected) {
                        nativeLeases[key(target)]?.applied=actual
                        return
                    }
                    try await Task.sleep(for:.milliseconds(50))
                }
                throw LabError.message("原生工作区\(phase)未达到精确尺寸，已停止适配")
            }
            // A wide physical-screen window must fit both screens before moving.
            // Wait for the requested geometry, not merely agreement between AX/CG:
            // both can agree on an old/automatic intermediate AppKit frame.
            var compact=CGSize(width:min(frame.width,requested.width),height:min(frame.height,requested.height))
            guard isCurrent(),AXUIElementSetAttributeValue(window,kAXSizeAttribute as CFString,AXValueCreate(.cgSize,&compact)!) == .success else {throw LabError.message("无法准备原生工作区窗口尺寸")}
            nativeLeases[key(target)]?.applied=rect(window)
            try await settle(CGRect(origin:frame.origin,size:compact),phase:"缩小")
            var point=usable.origin
            guard isCurrent(),AXUIElementSetAttributeValue(window,kAXPositionAttribute as CFString,AXValueCreate(.cgPoint,&point)!) == .success else {throw LabError.message("无法将窗口放入原生像素工作区")}
            nativeLeases[key(target)]?.applied=rect(window)
            try await settle(CGRect(origin:point,size:compact),phase:"移动")
            var exact=requested
            guard isCurrent(),AXUIElementSetAttributeValue(window,kAXSizeAttribute as CFString,AXValueCreate(.cgSize,&exact)!) == .success else {throw LabError.message("应用拒绝原生目标尺寸")}
            nativeLeases[key(target)]?.applied=rect(window)
            try await settle(CGRect(origin:point,size:exact),phase:"调整")
            print("WINDOW_LAYOUT_APPLIED target=\(target.number) requested=\(viewport.width)x\(viewport.height) accepted=\(exact.width)x\(exact.height) nativeExact=true");fflush(stdout)
            return
        } else {requested=CGSize(width:viewport.width,height:viewport.height)}
        guard isCurrent() else {throw LabError.message("窗口请求已取消")}
        var position=usable.origin
        var size=CGSize(width:min(usable.width,requested.width),height:min(usable.height,requested.height))
        guard AXUIElementSetAttributeValue(window,kAXSizeAttribute as CFString,AXValueCreate(.cgSize,&size)!) == .success else {
            throw LabError.message("应用不允许调整窗口尺寸，当前完整缩放显示")
        }
        nativeLeases[key(target)]?.applied=nativeRect(window)
        try await Task.sleep(for:.milliseconds(350))
        guard isCurrent() else {throw LabError.message("窗口请求已取消")}
        let accepted=rect(try resolve(known:window)) ?? frame
        // Respect application minimum width AND screen height. Never crop the client
        // to conceal a minimum-size constraint or place controls beyond the desktop.
        size=CGSize(width:min(usable.width,max(accepted.width,accepted.height*requested.width/requested.height)),
            height:min(usable.height,max(accepted.height,accepted.width*requested.height/requested.width)))
        let current=try resolve(known:window)
        // Moving an animating window can restore its old size. Finish the move
        // first, then make the final size request the last frame mutation.
        _=AXUIElementSetAttributeValue(current,kAXPositionAttribute as CFString,AXValueCreate(.cgPoint,&position)!)
        nativeLeases[key(target)]?.applied=nativeRect(current)
        try await Task.sleep(for:.milliseconds(200))
        guard isCurrent() else {throw LabError.message("窗口请求已取消")}
        let resized=try resolve(known:window)
        guard AXUIElementSetAttributeValue(resized,kAXSizeAttribute as CFString,AXValueCreate(.cgSize,&size)!) == .success else {
            throw LabError.message("应用拒绝目标比例，当前完整缩放显示")
        }
        nativeLeases[key(target)]?.applied=nativeRect(resized)
        // AXSet can return before AppKit starts its animation. Do not accept the
        // old CG/AX frames merely because they still agree in the first few ticks.
        try await Task.sleep(for:.milliseconds(350))
        guard isCurrent() else {throw LabError.message("窗口请求已取消")}
        // Wait for the capture geometry to catch up to the accepted AX frame.
        for _ in 0..<20 {
            try await Task.sleep(for:.milliseconds(50))
            guard isCurrent() else {throw LabError.message("窗口请求已取消")}
            let accepted=rect(try resolve(known:window))
            if let info=(CGWindowListCopyWindowInfo(.optionIncludingWindow,target.number) as? [[String:Any]])?.first,
               let bounds=info[kCGWindowBounds as String] as? NSDictionary,
               let actual=CGRect(dictionaryRepresentation:bounds),let accepted,
               abs(actual.width-accepted.width)<1,abs(actual.height-accepted.height)<1 {
                if workspaceDisplayID != nil {nativeLeases[key(target)]?.applied=actual}
                print("WINDOW_LAYOUT_APPLIED target=\(target.number) requested=\(viewport.width)x\(viewport.height) accepted=\(actual.width)x\(actual.height)");fflush(stdout)
                return
            }
        }
        throw LabError.message("窗口尺寸尚未稳定，当前完整缩放显示")
    }
}
#endif
