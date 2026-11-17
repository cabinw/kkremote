import Foundation
import CoreVideo

@main struct DesktopVideoColorTests {
    static func pixel(_ level:Int)->CVPixelBuffer {
        var result:CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil,32,32,kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary,&result)==kCVReturnSuccess)
        let b=result!
        CVBufferSetAttachment(b,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_2020,.shouldPropagate)
        CVBufferSetAttachment(b,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,.shouldPropagate)
        CVBufferSetAttachment(b,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_2020,.shouldPropagate)
        CVPixelBufferLockBaseAddress(b,[])
        for plane in 0..<2 {
            for row in 0..<CVPixelBufferGetHeightOfPlane(b,plane) {
                let values=CVPixelBufferGetBaseAddressOfPlane(b,plane)!.advanced(by:row*CVPixelBufferGetBytesPerRowOfPlane(b,plane)).assumingMemoryBound(to:UInt16.self)
                for col in 0..<32 { values[col]=UInt16(plane==0 ? level:512)<<6 }
            }
        }
        CVPixelBufferUnlockBaseAddress(b,[])
        return b
    }
    static func main() {
        let mapper=DesktopVideoColor()
        // ST 2084 reference points, converted to SDR relative to 203 nit white.
        for (pq,expected) in [(64,0),(200,17),(400,102),(509,186),(569,251),(573,255),(700,255)] {
            autoreleasepool {
                let source=pixel(pq),output=mapper.convert(source)!
                precondition(output !== source)
                precondition(CVPixelBufferGetPixelFormatType(output)==kCVPixelFormatType_32BGRA)
                precondition(CFEqual(CVBufferCopyAttachment(output,kCVImageBufferTransferFunctionKey,nil),kCVImageBufferTransferFunction_sRGB))
                CVPixelBufferLockBaseAddress(output,.readOnly)
                let bytes=CVPixelBufferGetBaseAddress(output)!.assumingMemoryBound(to:UInt8.self)
                for c in 0..<3 { precondition(abs(Int(bytes[c])-expected)<=2,"PQ \(pq): got \(bytes[c]), expected \(expected)") }
                precondition(bytes[3]==255)
                CVPixelBufferUnlockBaseAddress(output,.readOnly)
                precondition(mapper.convert(output) === output,"SDR must pass through")
                CVPixelBufferLockBaseAddress(source,.readOnly)
                precondition(CVPixelBufferGetBaseAddressOfPlane(source,0)!.assumingMemoryBound(to:UInt16.self)[0]==UInt16(pq)<<6)
                CVPixelBufferUnlockBaseAddress(source,.readOnly)
            }
        }
        for level in [64,400,569] {
            autoreleasepool {
                let source=pixel(level)
                let output=mapper.convert(source,outputSize:CGSize(width:43,height:87))!
                precondition(CVPixelBufferGetWidth(output)==43 && CVPixelBufferGetHeight(output)==87)
                let reference=mapper.convert(source)!
                CVPixelBufferLockBaseAddress(reference,.readOnly);CVPixelBufferLockBaseAddress(output,.readOnly)
                let referenceValue=CVPixelBufferGetBaseAddress(reference)!.assumingMemoryBound(to:UInt8.self)[0]
                for y in [0,43,86] { for x in [0,21,42] {
                    let pixel=CVPixelBufferGetBaseAddress(output)!.advanced(by:y*CVPixelBufferGetBytesPerRow(output)+x*4).assumingMemoryBound(to:UInt8.self)
                    for c in 0..<3 { precondition(abs(Int(pixel[c])-Int(referenceValue))<=2,"Resampling changed flat colors or edges") }
                    precondition(pixel[3]==255)
                }}
                CVPixelBufferUnlockBaseAddress(output,.readOnly);CVPixelBufferUnlockBaseAddress(reference,.readOnly)
                let invalid=mapper.convert(source,outputSize:CGSize(width:Double.nan,height:8000))!
                precondition(CVPixelBufferGetWidth(invalid)==32,"Invalid output size must preserve native resolution")
            }
        }
        let source=pixel(569)
        var held:[CVPixelBuffer]=[]
        for _ in 0..<8 { held.append(mapper.convert(source)!) }
        precondition(mapper.convert(source)==nil,"Allocation must be bounded")
        held.removeAll()
        precondition(mapper.convert(source) != nil,"Pool must recover after release")
        print("Desktop color: 7 PQ anchors, neutral RGB, SDR tagging/passthrough, source preservation, bounded pool and recovery passed")
    }
}
