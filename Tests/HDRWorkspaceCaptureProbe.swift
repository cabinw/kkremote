import Foundation
import AppKit
import ScreenCaptureKit
import CoreImage

/// Captures only the exact owned fixture identity supplied by the test harness.
@main enum HDRWorkspaceCaptureProbe {
    @MainActor static func main() {
        _=NSApplication.shared
        guard CommandLine.arguments.count==2 else {exit(2)}
        let root=URL(fileURLWithPath:CommandLine.arguments[1])
        Task { @MainActor in
            do {
                let fixture=try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("fixture.json"))) as! [String:Any]
                guard let title=fixture["title"] as? String,title.contains("KKRemote"),
                      let number=fixture["windowID"] as? UInt32,let pid=fixture["pid"] as? Int32 else {throw NSError(domain:"invalid-owned-fixture",code:1)}
                let content=try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:false)
                guard let window=content.windows.first(where:{$0.windowID==number && $0.owningApplication?.processID==pid && $0.title==title}) else {throw NSError(domain:"owned-fixture-missing",code:1)}
                let filter=SCContentFilter(desktopIndependentWindow:window)
                let c=SCStreamConfiguration(preset:.captureHDRStreamCanonicalDisplay)
                c.captureResolution = .best;c.width=Int((filter.contentRect.width*CGFloat(filter.pointPixelScale)).rounded());c.height=Int((filter.contentRect.height*CGFloat(filter.pointPixelScale)).rounded())
                c.width-=c.width%2;c.height-=c.height%2
                c.pixelFormat=kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange;c.colorSpaceName=CGColorSpace.itur_2100_PQ;c.colorMatrix=kCVImageBufferYCbCrMatrix_ITU_R_2020
                c.minimumFrameInterval = .zero;c.queueDepth=3;c.scalesToFit=false;c.preservesAspectRatio=true;c.ignoreShadowsSingleWindow=true;c.ignoreGlobalClipSingleWindow=true;c.shouldBeOpaque=true;c.showsCursor=false
                let shot=try await SCScreenshotManager.captureSampleBuffer(contentFilter:filter,configuration:c)
                guard let buffer=CMSampleBufferGetImageBuffer(shot) else {throw NSError(domain:"missing-buffer",code:1)}
                try CIContext().writePNGRepresentation(of:CIImage(cvPixelBuffer:buffer),to:root.appendingPathComponent("preview-sdr.png"),format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.extendedSRGB)!)
                CVPixelBufferLockBaseAddress(buffer,.readOnly)
                defer{CVPixelBufferUnlockBaseAddress(buffer,.readOnly)}
                let stride=CVPixelBufferGetBytesPerRowOfPlane(buffer,0),height=CVPixelBufferGetHeightOfPlane(buffer,0)
                try Data(bytes:CVPixelBufferGetBaseAddressOfPlane(buffer,0)!,count:stride*height).write(to:root.appendingPathComponent("luma-p010.raw"))
                let info:[String:Any]=["title":title,"width":CVPixelBufferGetWidth(buffer),"height":CVPixelBufferGetHeight(buffer),"rowBytes":stride,"sourcePoints":[filter.contentRect.width,filter.contentRect.height],"pointPixelScale":filter.pointPixelScale,"scalesToFit":false,"transfer":String(describing:CVBufferCopyAttachment(buffer,kCVImageBufferTransferFunctionKey,nil)),"primaries":String(describing:CVBufferCopyAttachment(buffer,kCVImageBufferColorPrimariesKey,nil))]
                try JSONSerialization.data(withJSONObject:info,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("capture.json"));print("HDR_WINDOW_CAPTURE_DONE");fflush(stdout);exit(0)
            } catch {print("HDR_WINDOW_CAPTURE_FAILED \(error)");fflush(stdout);exit(1)}
        }
        RunLoop.main.run()
    }
}
