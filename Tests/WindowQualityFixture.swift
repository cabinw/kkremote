import AppKit
import ScreenCaptureKit
import CoreImage
import CoreMedia

/// Owned real AppKit window. No other app content is captured by this probe.
final class QualityFixtureView:NSView {
    var tick=0
    var scrolling=false
    var renderingScale:CGFloat=1
    override var isFlipped:Bool { true }
    override func draw(_ dirtyRect:NSRect) {
        NSColor.white.setFill();bounds.fill()
        NSGraphicsContext.saveGraphicsState()
        defer {NSGraphicsContext.restoreGraphicsState()}
        // Vector/text redraw into a larger native backing store, not image scaling.
        let renderingTransform=NSAffineTransform();renderingTransform.scale(by:renderingScale);renderingTransform.concat()
        func text(_ value:String,_ x:CGFloat,_ y:CGFloat,_ size:CGFloat,_ color:NSColor = .black) {
            (value as NSString).draw(at:NSPoint(x:x,y:y),withAttributes:[.font:NSFont.systemFont(ofSize:size),.foregroundColor:color])
        }
        text("KKRemote · Native text quality",16,14,20)
        text("真实窗口 / Real AppKit window",16,45,16)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect:NSRect(x:0,y:78,width:bounds.width,height:680)).addClip()
        if scrolling { let t=AffineTransform(translationByX:0,byY:-CGFloat(tick%180));(t as NSAffineTransform).concat() }
        for (i,size) in [9.0,11,13,15,18,22].enumerated() {
            let y=CGFloat(85+i*52)
            text("Aa 0123456789 细节清晰度",16,y,size)
            text("Red Blue 文字 Aa 0123",16,y+25,12,i%2==0 ? .systemRed:.systemBlue)
        }
        text("1 / 2 / 3 px lines at Mac 2×",16,420,14)
        for row in 0..<3 {
            for col in 0..<100 {
                (col%2==0 ? NSColor.black:NSColor.white).setFill()
                NSRect(x:16+CGFloat(col)*CGFloat(row+1)/2,y:450+CGFloat(row*30),width:CGFloat(row+1)/2,height:20).fill()
            }
        }
        NSColor.black.setStroke()
        for row in 0..<7 { let p=NSBezierPath();p.lineWidth=0.5;p.move(to:NSPoint(x:16,y:570+row*28));p.line(to:NSPoint(x:400,y:570+row*28));p.stroke() }
        for col in 0..<6 { let p=NSBezierPath();p.lineWidth=0.5;p.move(to:NSPoint(x:16+col*76,y:570));p.line(to:NSPoint(x:16+col*76,y:738));p.stroke() }
        text("A1 中文 123.45",24,577,12)
        text("Text / 文字 / 中文",24,605,12)
        NSGraphicsContext.restoreGraphicsState()
        text("Static ROI; only footer moves",16,770,13)
        NSColor.systemGreen.setFill();NSRect(x:16+tick%350,y:810,width:20,height:10).fill()
        // At effective 3x these are exact black/white one-pixel columns. At 2x
        // the source cannot represent all columns; upscaling cannot recover them.
        for col in 0..<300 {
            (col%2==0 ? NSColor.black:NSColor.white).setFill()
            NSRect(x:270+CGFloat(col)/3,y:540,width:1/3.0,height:18).fill()
        }
    }
}

final class QualityCapture:NSObject,SCStreamOutput {
    let queue=DispatchQueue(label:"quality.capture")
    var continuation:CheckedContinuation<CVPixelBuffer,Error>?
    var count=0
    func stream(_ stream:SCStream,didOutputSampleBuffer sample:CMSampleBuffer,of type:SCStreamOutputType) {
        guard type == .screen,let a=(CMSampleBufferGetSampleAttachmentsArray(sample,createIfNecessary:false) as? [[SCStreamFrameInfo:Any]])?.first,
              (a[.status] as? Int)==SCFrameStatus.complete.rawValue,let buffer=CMSampleBufferGetImageBuffer(sample) else { return }
        count += 1
        guard count>=8,let c=continuation else{return};continuation=nil;c.resume(returning:buffer)
    }
}

@main enum WindowQualityFixture {
    @MainActor static func main() {
        let app=NSApplication.shared;app.setActivationPolicy(.regular)
        let output=URL(fileURLWithPath:CommandLine.arguments.dropFirst().first ?? "/tmp/kkremote-quality")
        try! FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let window=NSWindow(contentRect:NSRect(x:120,y:80,width:430,height:851),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title="KKRemote Native Quality Fixture";window.isReleasedWhenClosed=false
        let view=QualityFixtureView(frame:.zero);window.contentView=view
        let dense=CommandLine.arguments.contains("--native-client-pixels")
        view.renderingScale=(dense || CommandLine.arguments.contains("--native-drawing")) ? 1.5:1
        // A tall native-density window needs a sufficiently large HiDPI screen;
        // ordinary AppKit windows are clamped to the physical screen otherwise.
        let frameSize=CGSize(width:dense ? 645:430,height:dense ? 1310:873)
        let displayIndex=CommandLine.arguments.firstIndex(of:"--display-id")
        let displayID=displayIndex.flatMap{index in index+1<CommandLine.arguments.count ? UInt32(CommandLine.arguments[index+1]):nil}
        let screen=displayID.flatMap{id in NSScreen.screens.first{($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value==id}} ?? NSScreen.main
        let top=(screen?.visibleFrame.maxY ?? 1100)-10
        window.setFrame(NSRect(x:(screen?.visibleFrame.minX ?? 0)+20,y:top-frameSize.height,width:frameSize.width,height:frameSize.height),display:true)
        window.makeKeyAndOrderFront(nil);app.activate(ignoringOtherApps:true)
        let timer=Timer.scheduledTimer(withTimeInterval:1/60,repeats:true) { _ in
            view.tick+=1;view.needsDisplay=true
            if view.tick%30==0 { view.scrolling=FileManager.default.fileExists(atPath:output.appendingPathComponent("scroll.flag").path) }
        }
        _=timer
        try! JSONSerialization.data(withJSONObject:["pid":ProcessInfo.processInfo.processIdentifier,"windowID":window.windowNumber,"title":window.title,
            "windowPoints":[window.frame.width,window.frame.height],"viewPoints":[view.frame.width,view.frame.height],
            "backingScale":window.backingScaleFactor,"drawingScale":view.renderingScale,
            "backingSize":[view.convertToBacking(view.bounds).width,view.convertToBacking(view.bounds).height]]).write(to:output.appendingPathComponent("fixture.json"))
        if CommandLine.arguments.contains("--capture-probe") {
            Task { @MainActor in
                do {
                    try await Task.sleep(for:.seconds(1))
                    let content=try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:false)
                    guard let own=content.windows.first(where:{$0.windowID==window.windowNumber && $0.owningApplication?.processID==ProcessInfo.processInfo.processIdentifier}) else {throw NSError(domain:"owned-window-missing",code:1)}
                    let filter=SCContentFilter(desktopIndependentWindow:own)
                    var results=[[String:Any]]()
                    for scale in [2.0,3.0] {
                        for hdr in [false,true] {
                            let sink=QualityCapture()
                            let c=hdr ? SCStreamConfiguration(preset:.captureHDRStreamCanonicalDisplay):SCStreamConfiguration()
                            c.captureResolution = .best;c.width=Int(filter.contentRect.width*scale);c.height=Int(filter.contentRect.height*scale)
                            c.width-=c.width%2;c.height-=c.height%2;c.queueDepth=3;c.minimumFrameInterval = .zero
                            c.showsCursor=false;c.ignoreShadowsSingleWindow=true;c.ignoreGlobalClipSingleWindow=true
                            c.preservesAspectRatio=true;c.scalesToFit=true;c.shouldBeOpaque=true;c.capturesAudio=false
                            c.pixelFormat=hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:kCVPixelFormatType_32BGRA
                            c.colorSpaceName=hdr ? CGColorSpace.itur_2100_PQ:CGColorSpace.sRGB
                            if hdr { c.colorMatrix=kCVImageBufferYCbCrMatrix_ITU_R_2020 } else { c.captureDynamicRange = .SDR }
                            let stream=SCStream(filter:filter,configuration:c,delegate:nil)
                            try stream.addStreamOutput(sink,type:.screen,sampleHandlerQueue:sink.queue)
                            let buffer=try await withCheckedThrowingContinuation { (cont:CheckedContinuation<CVPixelBuffer,Error>) in
                                sink.queue.async {sink.continuation=cont}
                                sink.queue.asyncAfter(deadline:.now()+12) {
                                    sink.continuation?.resume(throwing:NSError(domain:"capture-timeout",code:1));sink.continuation=nil
                                }
                                Task { do {try await stream.startCapture()} catch {sink.queue.async {sink.continuation?.resume(throwing:error);sink.continuation=nil}} }
                            }
                            try await stream.stopCapture()
                            let name="capture-\(hdr ? "pq":"rgb")-\(Int(scale))x"
                            try CIContext().writePNGRepresentation(of:CIImage(cvPixelBuffer:buffer),to:output.appendingPathComponent(name+".png"),format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.extendedSRGB)!)
                            CVPixelBufferLockBaseAddress(buffer,.readOnly)
                            let planes=CVPixelBufferIsPlanar(buffer) ? CVPixelBufferGetPlaneCount(buffer):1
                            for plane in 0..<planes {
                                let planar=CVPixelBufferIsPlanar(buffer)
                                let rows=planar ? CVPixelBufferGetHeightOfPlane(buffer,plane):CVPixelBufferGetHeight(buffer)
                                let stride=planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer,plane):CVPixelBufferGetBytesPerRow(buffer)
                                let base=planar ? CVPixelBufferGetBaseAddressOfPlane(buffer,plane):CVPixelBufferGetBaseAddress(buffer)
                                try Data(bytes:base!,count:rows*stride).write(to:output.appendingPathComponent(name+"-plane\(plane).raw"))
                            }
                            CVPixelBufferUnlockBaseAddress(buffer,.readOnly)
                            results.append(["name":name,"width":CVPixelBufferGetWidth(buffer),"height":CVPixelBufferGetHeight(buffer),"rowBytes":(0..<planes).map {CVPixelBufferIsPlanar(buffer) ? CVPixelBufferGetBytesPerRowOfPlane(buffer,$0):CVPixelBufferGetBytesPerRow(buffer)},"pixelFormat":CVPixelBufferGetPixelFormatType(buffer),"sourcePoints":[filter.contentRect.width,filter.contentRect.height],"pointPixelScale":filter.pointPixelScale])
                            print("CAPTURED \(name) \(c.width)x\(c.height)");fflush(stdout)
                        }
                    }
                    try JSONSerialization.data(withJSONObject:results,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("captures.json"))
                    print("CAPTURE_PROBE_DONE");fflush(stdout)
                } catch { print("CAPTURE_PROBE_FAILED \(error)");fflush(stdout) }
            }
        }
        app.run()
    }
}
