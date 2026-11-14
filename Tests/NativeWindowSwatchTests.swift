import Foundation
import CoreVideo

@main struct NativeWindowSwatchTests {
    static func main() {
        var source:CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil,70,38,kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary,&source)==kCVReturnSuccess)
        let buffer=source!
        CVBufferSetAttachment(buffer,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,.shouldPropagate)
        CVBufferSetAttachment(buffer,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_2020,.shouldPropagate)
        CVBufferSetAttachment(buffer,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_2020,.shouldPropagate)
        precondition(CVPixelBufferLockBaseAddress(buffer,[])==kCVReturnSuccess)
        for plane in 0..<2 {
            let components=plane==0 ? 1:2
            for y in 0..<CVPixelBufferGetHeightOfPlane(buffer,plane) {
                let row=CVPixelBufferGetBaseAddressOfPlane(buffer,plane)!.advanced(by:y*CVPixelBufferGetBytesPerRowOfPlane(buffer,plane)).assumingMemoryBound(to:UInt16.self)
                for x in 0..<(CVPixelBufferGetWidthOfPlane(buffer,plane)*components) {
                    row[x]=UInt16(64+(y*17+x*3+plane*200)%800)<<6
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer,[])
        var checks=0
        for (x,y) in [(17,19),(0,0),(-9,-9),(999,999)] {
            let swatch=NativeWindowSwatch.make(buffer,x:x,y:y)!
            precondition(CVPixelBufferGetWidth(swatch)==32 && CVPixelBufferGetHeight(swatch)==32)
            precondition(CVPixelBufferGetPixelFormatType(swatch)==CVPixelBufferGetPixelFormatType(buffer))
            for key in [kCVImageBufferTransferFunctionKey,kCVImageBufferColorPrimariesKey,kCVImageBufferYCbCrMatrixKey] {
                precondition(CFEqual(CVBufferCopyAttachment(swatch,key,nil),CVBufferCopyAttachment(buffer,key,nil)))
            }
            CVPixelBufferLockBaseAddress(swatch,.readOnly)
            for plane in 0..<2 {
                let components=plane==0 ? 1:2
                let sx=(plane==0 ? min(max(x,0),69):min(max(x,0),69)/2)*components
                let sy=plane==0 ? min(max(y,0),37):min(max(y,0),37)/2
                for rowIndex in 0..<CVPixelBufferGetHeightOfPlane(swatch,plane) {
                    let row=CVPixelBufferGetBaseAddressOfPlane(swatch,plane)!.advanced(by:rowIndex*CVPixelBufferGetBytesPerRowOfPlane(swatch,plane)).assumingMemoryBound(to:UInt16.self)
                    for column in 0..<(CVPixelBufferGetWidthOfPlane(swatch,plane)*components) {
                        let expected=UInt16(64+(sy*17+(sx+column%components)*3+plane*200)%800)<<6
                        precondition(row[column]==expected);checks += 1
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(swatch,.readOnly)
        }
        CVPixelBufferLockBaseAddress(buffer,.readOnly)
        for plane in 0..<2 {
            for y in 0..<CVPixelBufferGetHeightOfPlane(buffer,plane) {
                let row=CVPixelBufferGetBaseAddressOfPlane(buffer,plane)!.advanced(by:y*CVPixelBufferGetBytesPerRowOfPlane(buffer,plane)).assumingMemoryBound(to:UInt16.self)
                for x in 0..<(CVPixelBufferGetWidthOfPlane(buffer,plane)*(plane==0 ? 1:2)) {
                    precondition(row[x]==UInt16(64+(y*17+x*3+plane*200)%800)<<6);checks += 1
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer,.readOnly)
        var sdr:CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil,32,32,kCVPixelFormatType_32BGRA,nil,&sdr)==kCVReturnSuccess)
        precondition(NativeWindowSwatch.make(sdr!,x:0,y:0)==nil)
        print("Native HDR swatch: \(checks) exact Y/UV checks passed; source unchanged, format and PQ attachments preserved; unsupported format falls back")
    }
}
