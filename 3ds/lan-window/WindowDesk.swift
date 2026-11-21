import AppKit
import ScreenCaptureKit

@MainActor final class WindowDesk {
    private let catalog = HostWindowCatalog()
    private var entries = [RemoteWindow]()
    private var preferredWidths = [String:Int]()
    private var fit: DeskWindowFit?
    private var target: RemoteWindow?
    private var stream: SCStream?
    private var frames: Frames?
    private var control: HostWindowControl?
    private var focus: String?
    private var sequence = 0
    private var selected: Int?
    private var previousWideJPEG = Data()
    private var previousWideView = [Int]()
    private var reader: PopReader?
    private var keyboardArt = Data()

    func run() async throws {
        signal(SIGPIPE, SIG_IGN)
        do { try await serve() }
        catch { await close(); throw error }
        await close()
    }
    private func serve() async throws {
        for page in 0..<3 { keyboardArt.append(try DeskArt.keyboard(page)) }
        while let line = await Task.detached(operation: { readLine() }).value {
            if line == "catalog" {
                try send(0, try await directory())
                continue
            }
            if line.hasPrefix("read ") {
                let fields = line.split(separator:" ")
                guard fields.count == 4, let index = Int(fields[1]), entries.indices.contains(index),
                      let page = UInt16(fields[2]) else { try send(3,Data()); continue }
                let entry = entries[index]
                if reader?.windowID != entry.id { reader = PopReader(windowID:entry.id) }
                let data = try reader!.response(target:entry,page:Int(page),reported:fields[3] == "1")
                try send(0,data)
                continue
            }
            reader = nil
            let values = line.split(separator:" ").compactMap { Int($0) }
            guard values.count == 6 || values.count == 9 else { throw LabError.message("Invalid window request") }
            let (index, action, value, x, y) = (values[0], values[1], values[2], values[3], values[4])
            guard entries.indices.contains(index) else { try send(3, Data()); continue }
            let changed = selected != index
            let app = entries[index].application
            let sizes = app.caseInsensitiveCompare("PopAgent") == .orderedSame ? [640,800,960] : [400,640,800,960]
            var width = preferredWidths[app] ?? sizes[0]
            let resizing = !changed && action == 5
            if resizing {
                let current = sizes.firstIndex(of:width) ?? 0
                width = sizes[(current+1) % sizes.count]
                preferredWidths[app] = width
            }
            if changed || resizing {
                await close(restoreSize:changed)
                selected = index
                do {
                    let initial = try await catalog.resolve(entries[index].id)
                    if fit == nil { fit = DeskWindowFit(initial) }
                    await fit?.fit(width:width)
                    let entry = try await catalog.current(initial)
                    let feed = try await startWindowFeed(entry,desk:true)
                    target = entry; (stream,frames) = feed
                    control = try? HostWindowControl(target:entry)
                    if control != nil { _ = await perform("focus") }
                } catch { fputs("Selected window is unavailable\n",stderr) }
            }
            guard let frames, !frames.isStopped() else { try send(3,Data()); continue }
            var status: UInt8 = control == nil ? 2 : 0
            if action != 0 && !changed {
                if action == 4 {
                    movePointer(x,y)
                } else if action == 1 || action == 2 {
                    if !(await perform(action == 1 ? "click" : "secondary", x:x, y:y)) { status = 1 }
                } else if action == 3 {
                    let special = [8:"backspace",9:"tab",13:"return",27:"escape",130:"left",131:"right",132:"up",133:"down"]
                    let ok: Bool
                    if let key = special[value] { ok = await perform("key", key:key) }
                    else if (32...126).contains(value) { ok = await perform("insertText", text:String(UnicodeScalar(value)!)) }
                    else { ok = false }
                    if !ok { status = 1 }
                }
            }
            let wide = values.count == 9
            let zoom = wide ? values[5] : (values[5] == 1 ? 2 : 1)
            guard (1...3).contains(zoom) else { throw LabError.message("Invalid reading scale") }
            let left = wide ? values[6] : (zoom == 1 ? 0 : min(400,max(0,x-200)))
            let top = wide ? values[7] : (zoom == 1 ? 0 : min(240,max(0,y-120)))
            guard (0...800-(800+zoom/2)/zoom).contains(left), (0...480-480/zoom).contains(top) else {
                throw LabError.message("Invalid reading region")
            }
            let jpeg = frames.deskJPEG(wide:wide,zoom:zoom,left:left,top:top)
            let view = [zoom,left,top]
            if wide && values[8] == 1 && !jpeg.isEmpty && view == previousWideView && previousWideJPEG == jpeg {
                try send(status,Data())
            } else {
                if wide && !jpeg.isEmpty { previousWideJPEG=jpeg; previousWideView=view }
                try send(status,jpeg)
            }
        }
    }

    private func directory() async throws -> Data {
        let previous = target
        await close()
        entries = try await catalog.refresh()
        let initial = entries.firstIndex { $0.number == previous?.number && $0.processID == previous?.processID }
            ?? entries.firstIndex { $0.application.caseInsensitiveCompare("PopAgent") == .orderedSame } ?? 0
        var data = Data([UInt8(entries.count),UInt8(initial)])
        for entry in entries { try data.blob(DeskArt.card(entry)) }
        data.append(keyboardArt)
        return data
    }
    private func close(restoreSize: Bool = true) async {
        reader = nil
        previousWideJPEG = Data(); previousWideView = []
        control?.invalidate(); control = nil; focus = nil; selected = nil
        if let stream { try? await stream.stopCapture() }
        stream = nil; frames = nil; target = nil
        if restoreSize { await fit?.restore(); fit = nil }
    }
    private func send(_ status: UInt8, _ data: Data) throws {
        var packet = Data([status])
        var length = UInt32(data.count).bigEndian
        withUnsafeBytes(of:&length) { packet.append(contentsOf:$0) }
        packet.append(data)
        try FileHandle.standardOutput.write(contentsOf:packet)
    }
    private func perform(_ kind: String, x: Int = 0, y: Int = 0, key: String? = nil, text: String? = nil) async -> Bool {
        guard let control, let target else { return false }
        sequence += 1
        let action = WindowInput(lease:control.lease,sequence:sequence,kind:kind,
            x:(Double(x)+0.5)*target.widthPoints/800,y:(Double(y)+0.5)*target.heightPoints/480,
            text:text,focus:focus,key:key)
        let (state,error): (WindowControlState?,String?) = await withCheckedContinuation { reply in
            control.enqueue(id:String(sequence),input:action) { reply.resume(returning:($0,$1)) }
        }
        if let error { fputs("Window input refused: \(error)\n",stderr); return false }
        if let token = state?.focus { focus = token }
        if kind != "focus" { fputs("INPUT \(kind) OK\n",stderr) }
        return true
    }

    // Only mirror local reticle motion when the exact selected window is exposed at that point.
    private func movePointer(_ x: Int, _ y: Int) {
        guard control != nil, let target,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processID,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]]
        else { return }
        func bounds(_ item: [String:Any]) -> CGRect? {
            guard let box = item[kCGWindowBounds as String] as? NSDictionary else { return nil }
            return CGRect(dictionaryRepresentation:box)
        }
        guard let entry = list.first(where:{ $0[kCGWindowNumber as String] as? UInt32 == target.number &&
                                             $0[kCGWindowOwnerPID as String] as? Int32 == target.processID }),
              let frame = bounds(entry) else { return }
        let point = CGPoint(x:frame.minX+(Double(x)+0.5)*frame.width/800, y:frame.minY+(Double(y)+0.5)*frame.height/480)
        guard list.first(where:{ ($0[kCGWindowAlpha as String] as? Double ?? 1) > 0 &&
                                  bounds($0)?.contains(point) == true })?[kCGWindowNumber as String] as? UInt32 == target.number else { return }
        CGEvent(mouseEventSource:nil,mouseType:.mouseMoved,mouseCursorPosition:point,mouseButton:.left)?.post(tap:.cghidEventTap)
    }
}
