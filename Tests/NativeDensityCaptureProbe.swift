import Foundation
import AppKit
import ScreenCaptureKit
import CoreImage

@main enum NativeDensityCaptureProbe {
    @MainActor static func main() {
        _=NSApplication.shared
        let root=URL(fileURLWithPath:CommandLine.arguments[1])
        Task { @MainActor in
            do {
                let fixture=try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("fixture.json"))) as! [String:Any]
                let content=try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:false)
                guard let window=content.windows.first(where:{$0.windowID==UInt32(fixture["windowID"] as! Int) && $0.owningApplication?.processID==Int32(fixture["pid"] as! Int) && $0.title=="KKRemote Native Quality Fixture"}) else {throw NSError(domain:"owned-fixture-missing",code:1)}
                let filter=SCContentFilter(desktopIndependentWindow:window)
                var entries=[[String:Any]]()
                for hdr in [false,true] {
                    let c=hdr ? SCStreamConfiguration(preset:.captureHDRStreamCanonicalDisplay):SCStreamConfiguration()
                    c.captureResolution = .best;c.width=Int((filter.contentRect.width*CGFloat(filter.pointPixelScale)).rounded());c.height=Int((filter.contentRect.height*CGFloat(filter.pointPixelScale)).rounded())
                    c.pixelFormat=hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:kCVPixelFormatType_32BGRA
                    c.colorSpaceName=hdr ? CGColorSpace.itur_2100_PQ:CGColorSpace.sRGB
                    if hdr {c.colorMatrix=kCVImageBufferYCbCrMatrix_ITU_R_2020}
                    c.minimumFrameInterval = .zero;c.queueDepth=3;c.scalesToFit=false;c.preservesAspectRatio=true;c.ignoreShadowsSingleWindow=true;c.ignoreGlobalClipSingleWindow=true;c.shouldBeOpaque=true;c.showsCursor=false
                    let shot=try await SCScreenshotManager.captureSampleBuffer(contentFilter:filter,configuration:c)
                    guard let buffer=CMSampleBufferGetImageBuffer(shot) else {throw NSError(domain:"missing-buffer",code:1)}
                    let name=hdr ? "native-pq":"native-rgb"
                    try CIContext().writePNGRepresentation(of:CIImage(cvPixelBuffer:buffer),to:root.appendingPathComponent(name+".png"),format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.extendedSRGB)!)
                    entries.append(["name":name,"width":CVPixelBufferGetWidth(buffer),"height":CVPixelBufferGetHeight(buffer),"sourcePoints":[filter.contentRect.width,filter.contentRect.height],"pointPixelScale":filter.pointPixelScale,"scalesToFit":false])
                }
                try JSONSerialization.data(withJSONObject:entries,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("native-capture.json"))
                print("NATIVE_CAPTURE_DONE");fflush(stdout);exit(0)
            } catch {print("NATIVE_CAPTURE_FAILED \(error)");fflush(stdout);exit(1)}
        }
        RunLoop.main.run()
    }
}
