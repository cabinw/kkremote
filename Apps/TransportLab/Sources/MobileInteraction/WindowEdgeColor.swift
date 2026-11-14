import Foundation

/// An sRGB background estimate, shared by the frame sampler and deterministic tests.
struct WindowEdgeColor: Equatable {
    let red: Double, green: Double, blue: Double
    static let initial = WindowEdgeColor(red:0.94,green:0.94,blue:0.94)
    var prefersLightContent: Bool {
        func linear(_ value:Double)->Double { value<=0.04045 ? value/12.92 : pow((value+0.055)/1.055,2.4) }
        return 0.2126*linear(red)+0.7152*linear(green)+0.0722*linear(blue)<0.18
    }
    func distance(to other:Self)->Double {
        max(abs(red-other.red),abs(green-other.green),abs(blue-other.blue))
    }
}

struct WindowEdgeColorEstimator {
    private(set) var current:WindowEdgeColor?
    private var pending:WindowEdgeColor?
    private var confirmations=0

    /// RGBA8, sRGB. A dominant bucket rejects text/icons instead of averaging them into the background.
    mutating func consume(_ rgba:[UInt8])->WindowEdgeColor? {
        guard rgba.count>=16,rgba.count%4==0 else { return nil }
        var buckets:[Int:(count:Int,r:Int,g:Int,b:Int)]=[:],valid=0
        for i in stride(from:0,to:rgba.count,by:4) where rgba[i+3]>=240 {
            let r=Int(rgba[i]),g=Int(rgba[i+1]),b=Int(rgba[i+2])
            let key=(r>>4)<<8 | (g>>4)<<4 | (b>>4)
            let old=buckets[key] ?? (0,0,0,0)
            buckets[key]=(old.count+1,old.r+r,old.g+g,old.b+b);valid += 1
        }
        guard valid>=4,let winner=buckets.max(by:{$0.value.count<$1.value.count})?.value,
              Double(winner.count)/Double(valid)>=0.35 else { pending=nil;confirmations=0;return nil }
        let divisor=Double(winner.count)*255
        let color=WindowEdgeColor(red:Double(winner.r)/divisor,green:Double(winner.g)/divisor,blue:Double(winner.b)/divisor)
        if let current {
            guard current.distance(to:color)>3.0/255 else { pending=nil;confirmations=0;return nil }
            if let pending,pending.distance(to:color)<8.0/255 { confirmations += 1 }
            else { pending=color;confirmations=1 }
            guard confirmations>=2 else { return nil }
        }
        current=color;pending=nil;confirmations=0;return color
    }
}

#if canImport(CoreVideo)
import CoreVideo

enum NativeWindowSwatch {
    /// A tiny uniform P010 image, with the same color attachments as the video.
    /// No HDR-to-SDR conversion or modification of the incoming frame.
    static func make(_ source:CVPixelBuffer,x:Int,y:Int)->CVPixelBuffer? {
        guard CVPixelBufferGetPixelFormatType(source)==kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
              CVPixelBufferGetPlaneCount(source)==2,
              CVPixelBufferLockBaseAddress(source,.readOnly)==kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(source,.readOnly) }
        var result:CVPixelBuffer?
        guard CVPixelBufferCreate(nil,32,32,CVPixelBufferGetPixelFormatType(source),
            [kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary,&result)==kCVReturnSuccess,
              let result,CVPixelBufferLockBaseAddress(result,[])==kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(result,[]) }
        let px = min(max(0,x),CVPixelBufferGetWidth(source)-1)
        let py = min(max(0,y),CVPixelBufferGetHeight(source)-1)
        for plane in 0..<2 {
            guard let input=CVPixelBufferGetBaseAddressOfPlane(source,plane),
                  let output=CVPixelBufferGetBaseAddressOfPlane(result,plane) else { return nil }
            let components = plane==0 ? 1:2
            let sx = plane==0 ? px:px/2, sy = plane==0 ? py:py/2
            let pixel = input.advanced(by:sy*CVPixelBufferGetBytesPerRowOfPlane(source,plane)+sx*components*2)
            for row in 0..<CVPixelBufferGetHeightOfPlane(result,plane) {
                let target = output.advanced(by:row*CVPixelBufferGetBytesPerRowOfPlane(result,plane))
                for column in 0..<CVPixelBufferGetWidthOfPlane(result,plane) {
                    target.advanced(by:column*components*2).copyMemory(from:pixel,byteCount:components*2)
                }
            }
        }
        for key in [kCVImageBufferColorPrimariesKey,kCVImageBufferTransferFunctionKey,kCVImageBufferYCbCrMatrixKey,
                    kCVImageBufferMasteringDisplayColorVolumeKey,kCVImageBufferContentLightLevelInfoKey] {
            if let value=CVBufferCopyAttachment(source,key,nil) { CVBufferSetAttachment(result,key,value,.shouldPropagate) }
        }
        return result
    }
}
#endif

#if canImport(CoreImage) && canImport(CoreVideo)
import CoreImage

/// Desktop presentation preserves the PQ reference-white range as SDR UI.
/// Extended sRGB avoids the implicit HDR compression of a bounded output space;
/// the BGRA8 destination clips only values outside the desktop display range.
final class DesktopVideoColor {
    private let context=CIContext(options:[.cacheIntermediates:false])
    private let outputSpace=CGColorSpace(name:CGColorSpace.extendedSRGB)!
    private var pool:CVPixelBufferPool?
    private var size=CGSize.zero

    func convert(_ source:CVPixelBuffer, outputSize:CGSize? = nil)->CVPixelBuffer? {
        let transfer=CVBufferCopyAttachment(source,kCVImageBufferTransferFunctionKey,nil)
        let isPQ=transfer.map { CFEqual($0,kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ) } ?? false
        let native=CGSize(width:CVPixelBufferGetWidth(source),height:CVPixelBufferGetHeight(source))
        var next=native
        if let outputSize,outputSize.width.isFinite,outputSize.height.isFinite,
           outputSize.width >= 1,outputSize.height >= 1,outputSize.width <= 4096,outputSize.height <= 4096,
           outputSize.width*outputSize.height <= 8_388_608 {
            next=CGSize(width:outputSize.width.rounded(),height:outputSize.height.rounded())
        }
        if !isPQ && next == native { return source }
        if pool == nil || size != next {
            let attributes:[CFString:Any]=[kCVPixelBufferWidthKey:Int(next.width),kCVPixelBufferHeightKey:Int(next.height),
                kCVPixelBufferPixelFormatTypeKey:kCVPixelFormatType_32BGRA,kCVPixelBufferIOSurfacePropertiesKey:[:],
                kCVPixelBufferMetalCompatibilityKey:true]
            guard CVPixelBufferPoolCreate(nil,[kCVPixelBufferPoolMinimumBufferCountKey:2] as CFDictionary,
                attributes as CFDictionary,&pool)==kCVReturnSuccess else { return nil }
            size=next
        }
        var output:CVPixelBuffer?
        guard let pool,CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil,pool,
            [kCVPixelBufferPoolAllocationThresholdKey:8] as CFDictionary,&output)==kCVReturnSuccess,
              let output else { return nil }
        var image=CIImage(cvPixelBuffer:source)
        if next != native {
            // Resample once at the final screen-pixel size. Lanczos retains thin
            // text strokes better than repeated layer bilinear scaling.
            let sx=next.width/native.width,sy=next.height/native.height
            image=image.clampedToExtent().applyingFilter("CILanczosScaleTransform",parameters:["inputScale":sy,"inputAspectRatio":sx/sy])
                .cropped(to:CGRect(origin:.zero,size:next))
        }
        context.render(image,to:output,bounds:CGRect(origin:.zero,size:next),colorSpace:outputSpace)
        // Conversion is complete: tag the output honestly as SDR, never PQ.
        CVBufferRemoveAllAttachments(output)
        CVBufferSetAttachment(output,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,.shouldPropagate)
        CVBufferSetAttachment(output,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_sRGB,.shouldPropagate)
        CVBufferSetAttachment(output,kCVImageBufferCGColorSpaceKey,CGColorSpace(name:CGColorSpace.sRGB)!, .shouldPropagate)
        return output
    }
}

/// Sender-only opt-in path. ScreenCaptureKit supplies linear extended-sRGB
/// RGBA half-float; resample before 4:2:0 and preserve HDR in BT.2020/PQ P010.
final class WindowTextPixelConverter {
    private let context=CIContext(options:[.cacheIntermediates:false])
    private let linear=CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
    private let pq=CGColorSpace(name:CGColorSpace.itur_2100_PQ)!
    private let pool:CVPixelBufferPool
    private let size:CGSize
    init(size:CGSize) throws {
        guard size.width.isFinite,size.height.isFinite,size.width>=2,size.height>=2,
              size.width<=4096,size.height<=4096,size.width*size.height<=3_686_400,
              Int(size.width)%2==0,Int(size.height)%2==0 else {throw NSError(domain:"window-text-size",code:1)}
        self.size=size
        var pool:CVPixelBufferPool?
        let attributes:[CFString:Any]=[kCVPixelBufferWidthKey:Int(size.width),kCVPixelBufferHeightKey:Int(size.height),
            kCVPixelBufferPixelFormatTypeKey:kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey:[:],kCVPixelBufferMetalCompatibilityKey:true]
        guard CVPixelBufferPoolCreate(nil,[kCVPixelBufferPoolMinimumBufferCountKey:3] as CFDictionary,attributes as CFDictionary,&pool)==0,let pool else {throw NSError(domain:"window-text-pool",code:1)}
        self.pool=pool
    }
    func convert(_ source:CVPixelBuffer)->CVPixelBuffer? {
        guard CVPixelBufferGetPixelFormatType(source)==kCVPixelFormatType_64RGBAHalf else{return nil}
        var output:CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil,pool,[kCVPixelBufferPoolAllocationThresholdKey:8] as CFDictionary,&output)==0,let output else{return nil}
        CVBufferSetAttachment(output,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_2020,.shouldPropagate)
        CVBufferSetAttachment(output,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,.shouldPropagate)
        CVBufferSetAttachment(output,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_2020,.shouldPropagate)
        var image=CIImage(cvPixelBuffer:source,options:[.colorSpace:linear])
        if image.extent.size != size {
            let sx=size.width/image.extent.width,sy=size.height/image.extent.height
            image=image.clampedToExtent().applyingFilter("CILanczosScaleTransform",parameters:["inputScale":sy,"inputAspectRatio":sx/sy]).cropped(to:CGRect(origin:.zero,size:size))
        }
        context.render(image,to:output,bounds:CGRect(origin:.zero,size:size),colorSpace:pq)
        return output
    }
}
#endif
