#if os(iOS) && canImport(WebRTC)
import CoreImage
import WebRTC

/// Observes decoded frames without changing the video renderer or retaining a frame queue.
final class WindowColorSampler:NSObject,RTCVideoRenderer {
    private let lock=NSLock()
    private let queue=DispatchQueue(label:"kkremote.window.edge-color",qos:.utility)
    private let context=CIContext(options:[.cacheIntermediates:false])
    // Match desktop presentation's reference-white mapping. Bounded sRGB
    // implicitly compresses HDR whites and makes a sampled background too gray.
    private let colorSpace=CGColorSpace(name:CGColorSpace.extendedSRGB)!
    private var estimator=WindowEdgeColorEstimator()
    private var region=CGRect(x:0.08,y:0.002,width:0.84,height:0.005)
    private var active=true,busy=false
    private var lastSample=0.0
    private let onColor:(WindowEdgeColor)->Void
    var onNativeColor:((CVPixelBuffer)->Void)?
    init(onColor:@escaping(WindowEdgeColor)->Void) { self.onColor=onColor;super.init() }
    func setSize(_ size:CGSize) {}
    func update(region:CGRect) { lock.lock();self.region=region;lock.unlock() }
    func stop() { lock.lock();active=false;lock.unlock() }
    func renderFrame(_ frame:RTCVideoFrame?) {
        guard let frame,frame.rotation.rawValue==0,let native=frame.buffer as? RTCCVPixelBuffer else { return }
        let now=ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard active,!busy,now-lastSample>=0.5 else { lock.unlock();return }
        busy=true;lastSample=now;let requested=region
        lock.unlock()
        let buffer=native.pixelBuffer
        queue.async { [weak self] in
            guard let self else { return }
            defer { self.lock.lock();self.busy=false;self.lock.unlock() }
            autoreleasepool { [self] in
                let image=CIImage(cvPixelBuffer:buffer)
                let extent=image.extent
                // Source sampling coordinates are top-left; Core Image uses bottom-left.
                let crop=CGRect(x:requested.minX*extent.width,y:(1-requested.maxY)*extent.height,
                    width:requested.width*extent.width,height:requested.height*extent.height).intersection(extent)
                guard crop.width>=4,crop.height>=1 else { return }
                let strip=image.cropped(to:crop)
                    .transformed(by:CGAffineTransform(translationX:-crop.minX,y:-crop.minY))
                    .transformed(by:CGAffineTransform(scaleX:64/crop.width,y:4/crop.height))
                var rgba=[UInt8](repeating:0,count:64*4*4)
                rgba.withUnsafeMutableBytes { bytes in
                    self.context.render(strip,toBitmap:bytes.baseAddress!,rowBytes:64*4,
                        bounds:CGRect(x:0,y:0,width:64,height:4),format:.RGBA8,colorSpace:self.colorSpace)
                }
                self.lock.lock();let allowed=self.active;self.lock.unlock()
                guard allowed,let color=self.estimator.consume(rgba) else { return }
                if self.onNativeColor != nil {
                    // SDR is used only to identify background pixels. Preserve the
                    // selected pixel's original PQ values for the actual fill.
                    let index = stride(from:0,to:rgba.count,by:4).filter { rgba[$0+3]>=240 }.min {
                        func distance(_ i:Int)->Double {
                            pow(Double(rgba[i])/255-color.red,2)+pow(Double(rgba[i+1])/255-color.green,2)+pow(Double(rgba[i+2])/255-color.blue,2)
                        }
                        return distance($0)<distance($1)
                    }
                    if let index {
                        let x = Int(crop.minX+(Double((index/4)%64)+0.5)*crop.width/64)
                        let y = Int(extent.height-crop.minY-(Double((index/4)/64)+0.5)*crop.height/4)
                        if let swatch = NativeWindowSwatch.make(buffer,x:x,y:y) { self.onNativeColor?(swatch) }
                    }
                }
                self.onColor(color)
            }
        }
    }


}
#endif
