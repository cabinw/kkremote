import Foundation
import VideoToolbox
import CoreImage
import WebRTC

enum LabError: Error { case message(String) }

/// Offline, owned-fixture-only comparison through the production Main10 codec.
@main enum WindowQualityCodecProbe {
    static func main() throws {
        RTCInitializeSSL()
        let directory=URL(fileURLWithPath:CommandLine.arguments[1])
        var entries=try JSONSerialization.jsonObject(with:Data(contentsOf:directory.appendingPathComponent("captures.json"))) as! [[String:Any]]
        if let rgb=CIImage(contentsOf:directory.appendingPathComponent("capture-rgb-2x.png")) {
            let w=1290,h=2618
            var b:CVPixelBuffer?
            guard CVPixelBufferCreate(nil,w,h,HDRFormat.pixelFormat,[kCVPixelBufferIOSurfacePropertiesKey:[:],kCVPixelBufferMetalCompatibilityKey:true] as CFDictionary,&b)==0,let b else {throw LabError.message("RGB buffer")}
            HDRFormat.tag(b)
            let image=rgb.clampedToExtent().applyingFilter("CILanczosScaleTransform",parameters:["inputScale":Double(h)/rgb.extent.height,"inputAspectRatio":(Double(w)/rgb.extent.width)/(Double(h)/rgb.extent.height)]).cropped(to:CGRect(x:0,y:0,width:w,height:h))
            CIContext().render(image,to:b,bounds:image.extent,colorSpace:CGColorSpace(name:CGColorSpace.itur_2100_PQ)!)
            let name="capture-pq-rgb-lanczos"
            try CIContext().writePNGRepresentation(of:CIImage(cvPixelBuffer:b),to:directory.appendingPathComponent(name+".png"),format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.extendedSRGB)!)
            CVPixelBufferLockBaseAddress(b,.readOnly)
            for p in 0..<2 {try Data(bytes:CVPixelBufferGetBaseAddressOfPlane(b,p)!,count:CVPixelBufferGetBytesPerRowOfPlane(b,p)*CVPixelBufferGetHeightOfPlane(b,p)).write(to:directory.appendingPathComponent(name+"-plane\(p).raw"))}
            CVPixelBufferUnlockBaseAddress(b,.readOnly)
            entries.append(["name":name,"width":w,"height":h,"rowBytes":(0..<2).map{CVPixelBufferGetBytesPerRowOfPlane(b,$0)}])
        }
        for entry in entries where (entry["name"] as! String).contains("pq") {
            let name=entry["name"] as! String,w=entry["width"] as! Int,h=entry["height"] as! Int,strides=entry["rowBytes"] as! [Int]
            var input:CVPixelBuffer?
            guard CVPixelBufferCreate(nil,w,h,HDRFormat.pixelFormat,[kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary,&input)==0,let input else { throw LabError.message("buffer") }
            CVPixelBufferLockBaseAddress(input,[])
            for p in 0..<2 {
                let bytes=try Data(contentsOf:directory.appendingPathComponent(name+"-plane\(p).raw"))
                bytes.withUnsafeBytes { raw in
                    for y in 0..<CVPixelBufferGetHeightOfPlane(input,p) {
                        CVPixelBufferGetBaseAddressOfPlane(input,p)!.advanced(by:y*CVPixelBufferGetBytesPerRowOfPlane(input,p)).copyMemory(from:raw.baseAddress!.advanced(by:y*strides[p]),byteCount:w*2)
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(input,[]);HDRFormat.tag(input)
            let limit=CommandLine.arguments.count>2 ? Int(CommandLine.arguments[2]):nil
            let encoder=HEVCEncoder(maximumFrameQP:limit),decoder=HEVCDecoder(),lock=NSLock()
            var count=0,bytes=0,failures=0
            let context=CIContext(),color=DesktopVideoColor()
            decoder.setCallback { frame in
                guard let buffer=(frame.buffer as? RTCCVPixelBuffer)?.pixelBuffer else{return}
                lock.lock();count+=1;let n=count;lock.unlock()
                if n==1 || n==120 {
                    do {
                        try context.writePNGRepresentation(of:CIImage(cvPixelBuffer:buffer),to:directory.appendingPathComponent(name+"-decoded-\(n).png"),format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.extendedSRGB)!)
                        if let displayed=color.convert(buffer,outputSize:CGSize(width:1290,height:2618)) {
                            try context.writePNGRepresentation(of:CIImage(cvPixelBuffer:displayed),to:directory.appendingPathComponent(name+"-display-\(n).png"),format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)
                        }
                    } catch { print(error) }
                }
            }
            encoder.setCallback { image,_ in
                lock.lock();bytes+=image.buffer.count;lock.unlock()
                return decoder.decode(image,missingFrames:false,codecSpecificInfo:nil,renderTimeMs:0)==0
            }
            let settings=RTCVideoEncoderSettings();settings.name="H265";settings.width=UInt16(w);settings.height=UInt16(h)
            settings.startBitrate=20000;settings.maxBitrate=20000;settings.minBitrate=1;settings.maxFramerate=60;settings.mode = .screensharing;settings.qpMax=51
            guard encoder.startEncode(with:settings,numberOfCores:4)==0 else{throw LabError.message("encoder")}
            for i in 0..<180 {
                let frame=RTCVideoFrame(buffer:RTCCVPixelBuffer(pixelBuffer:input),rotation:._0,timeStampNs:Int64(i)*1_000_000_000/60)
                frame.timeStamp=Int32(i*1500)
                if encoder.encode(frame,codecSpecificInfo:nil,frameTypes:[NSNumber(value:(i==0 ? RTCFrameType.videoFrameKey:.videoFrameDelta).rawValue)]) != 0 { failures+=1 }
                Thread.sleep(forTimeInterval:1/60)
            }
            _=encoder.release();_=decoder.release()
            print("\(name) decoded=\(count) bytes=\(bytes) failures=\(failures)")
            guard count==180,failures==0 else{throw LabError.message("dropped frames")}
        }
    }
}
