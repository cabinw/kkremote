import Foundation
import CoreImage
import CoreVideo

@main enum WindowPixelQualityTests {
    static func main() throws {
        let budget:CGFloat=2560*1440
        let nativeProposal=MobileWindowSizing.nativeSourcePoints(viewport:CGSize(width:430,height:873),displayScale:3,nativeScale:2,maximumPixels:budget,availablePoints:CGSize(width:1264,height:1400))
        precondition(nativeProposal==CGSize(width:645,height:1309))
        precondition(MobileWindowSizing.nativeClientPixels(viewport:CGSize(width:430,height:873),displayScale:3)==CGSize(width:1290,height:2618))
        precondition(MobileWindowSizing.nativeClientPixels(viewport:CGSize(width:393,height:851.6666666667),displayScale:3)==CGSize(width:1178,height:2554))
        precondition(MobileWindowSizing.nativeClientPixels(viewport:CGSize(width:430,height:873),displayScale:.nan)==nil)
        precondition(MobileWindowSizing.nativeSourcePoints(viewport:CGSize(width:430,height:873),displayScale:3,nativeScale:2,maximumPixels:budget,availablePoints:CGSize(width:1728,height:1084))==nil,"Physical screen height cannot provide the native portrait window")
        precondition(MobileWindowSizing.nativeSourcePoints(viewport:CGSize(width:814,height:430),displayScale:3,nativeScale:2,maximumPixels:budget,availablePoints:CGSize(width:1264,height:1400))==CGSize(width:1221,height:645))
        precondition(MobileWindowSizing.nativeSourcePoints(viewport:CGSize(width:1000,height:1000),displayScale:3,nativeScale:2,maximumPixels:budget,availablePoints:CGSize(width:2000,height:2000))==nil,"Native mode must not silently downscale over budget")
        let portrait=MobileWindowSizing.encodingPixels(for:CGSize(width:430,height:873),nativeScale:2,viewport:CGSize(width:430,height:873),displayScale:3,maximumPixels:budget)!
        precondition(portrait==CGSize(width:1290,height:2618))
        let minimum=MobileWindowSizing.encodingPixels(for:CGSize(width:500,height:1015),nativeScale:2,viewport:CGSize(width:430,height:873),displayScale:3,maximumPixels:budget)!
        precondition(minimum.width==1290 && minimum.height*minimum.width<=budget)
        let large=MobileWindowSizing.encodingPixels(for:CGSize(width:1800,height:1800),nativeScale:2,viewport:CGSize(width:1800,height:1800),displayScale:3,maximumPixels:budget)!
        precondition(large.width*large.height<=budget)
        precondition(MobileWindowSizing.encodingPixels(for:CGSize(width:430,height:873),nativeScale:2,viewport:CGSize(width:430,height:873),displayScale:Double.nan,maximumPixels:budget)==nil)
        precondition((try? WindowTextPixelConverter(size:CGSize(width:8192,height:8192)))==nil)
        let converter=try WindowTextPixelConverter(size:CGSize(width:48,height:48))
        let linear=CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!,context=CIContext()
        func source(_ level:CGFloat)->CVPixelBuffer {
            var b:CVPixelBuffer?
            precondition(CVPixelBufferCreate(nil,32,32,kCVPixelFormatType_64RGBAHalf,[kCVPixelBufferIOSurfacePropertiesKey:[:],kCVPixelBufferMetalCompatibilityKey:true] as CFDictionary,&b)==0)
            let image=CIImage(color:CIColor(red:level,green:level,blue:level,alpha:1,colorSpace:linear)!).cropped(to:CGRect(x:0,y:0,width:32,height:32))
            context.render(image,to:b!,bounds:image.extent,colorSpace:linear)
            return b!
        }
        var levels=[Int]()
        for level:CGFloat in [0,0.18,1,2,4] {
            autoreleasepool {
                let out=converter.convert(source(level))!
                precondition(CVPixelBufferGetWidth(out)==48)
                precondition(CFEqual(CVBufferCopyAttachment(out,kCVImageBufferTransferFunctionKey,nil),kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ))
                CVPixelBufferLockBaseAddress(out,.readOnly)
                levels.append(Int(CVPixelBufferGetBaseAddressOfPlane(out,0)!.assumingMemoryBound(to:UInt16.self)[0]>>6))
                CVPixelBufferUnlockBaseAddress(out,.readOnly)
            }
        }
        precondition(levels[0]<=65 && zip(levels,levels.dropFirst()).allSatisfy{$0<$1},"HDR must remain above SDR white: \(levels)")
        let input=source(1);var held=[CVPixelBuffer]()
        for _ in 0..<8 {held.append(converter.convert(input)!)}
        precondition(converter.convert(input)==nil);held.removeAll();precondition(converter.convert(input) != nil)
        print("Window quality: pixel budget, accepted window sizing, invalid scale, HDR anchors \(levels), bounded pool and recovery passed")
    }
}
