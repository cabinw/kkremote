#if os(iOS) && canImport(WebRTC)
import SwiftUI
import WebRTC

/// Separate observation only. The HDR renderer continues to receive native frames.
@MainActor
final class WindowEdgeAppearance: ObservableObject {
    @Published private(set) var color = WindowEdgeColor.initial
    @Published private(set) var ready = false
    @Published private(set) var nativeColor:CVPixelBuffer?
    private var track: RTCVideoTrack?
    private var sampler: WindowColorSampler?
    private var generation = UUID()
    private var region = CGRect(x:0.08,y:0.002,width:0.84,height:0.005)

    var background: Color { Color(.sRGB,red:color.red,green:color.green,blue:color.blue,opacity:1) }

    func bind(_ next: RTCVideoTrack?) {
        guard track !== next else { return }
        if let sampler { sampler.stop();track?.remove(sampler) }
        track = next;sampler = nil;generation = UUID();ready = false;color = .initial;nativeColor = nil
        guard let next else { return }
        let token = generation
        let observer = WindowColorSampler { [weak self] color in
            Task { @MainActor [weak self] in
                guard let self,self.generation == token else { return }
                self.color = color;self.ready = true
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--viewer-ui-review") || ProcessInfo.processInfo.arguments.contains("--viewer-color-review") {
        observer.onNativeColor = { [weak self] buffer in
            Task { @MainActor [weak self] in
                guard let self,self.generation == token else { return }
                self.nativeColor = buffer
                if ProcessInfo.processInfo.arguments.contains("--viewer-color-review") {
                    CVPixelBufferLockBaseAddress(buffer,.readOnly)
                    let y=CVPixelBufferGetBaseAddressOfPlane(buffer,0)!.assumingMemoryBound(to:UInt16.self)[0]>>6
                    let uv=CVPixelBufferGetBaseAddressOfPlane(buffer,1)!.assumingMemoryBound(to:UInt16.self)
                    NSLog("[edge-review] Y=%d U=%d V=%d headroom=%.3f potential=%.3f",Int(y),Int(uv[0]>>6),Int(uv[1]>>6),UIScreen.main.currentEDRHeadroom,UIScreen.main.potentialEDRHeadroom)
                    CVPixelBufferUnlockBaseAddress(buffer,.readOnly)
                }
            }
        }
        }
        observer.update(region:region);sampler = observer;next.add(observer)
    }

    func update(geometry:ViewportGeometry, encoded:CGSize) {
        guard geometry.isValid,encoded.width>0,encoded.height>0 else { return }
        let source = geometry.source
        let scale = min(encoded.width/source.width,encoded.height/source.height)
        let x = max(0,-geometry.contentRect.minX/geometry.scale)
        let y = max(0,-geometry.contentRect.minY/geometry.scale)
        let width = min(source.width-x,geometry.viewport.width/geometry.scale)
        // The first few window pixels include the bright macOS rim, not the
        // title-bar fill. Sample inside the visible background instead.
        let remaining = source.height-y
        let inset = min(12,max(0,remaining-8))
        region = CGRect(x:(x+width*0.08)*scale/encoded.width,
            y:(y+inset)*scale/encoded.height,width:width*0.84*scale/encoded.width,
            height:min(8,remaining-inset)*scale/encoded.height)
        sampler?.update(region:region)
    }
}

/// Color the owning scene's UIKit backing as well as the SwiftUI workspace.
/// No application-wide appearance proxy and no color layer above the video.
struct WindowSceneBackground: UIViewRepresentable {
    let color: WindowEdgeColor
    func makeUIView(context: Context) -> BackingView { BackingView() }
    func updateUIView(_ view: BackingView, context: Context) {
        view.sceneColor=UIColor(red:color.red,green:color.green,blue:color.blue,alpha:1)
        view.apply()
    }
    final class BackingView: UIView {
        var sceneColor=UIColor.clear
        override func didMoveToWindow() { super.didMoveToWindow();apply() }
        func apply() {
            backgroundColor = .clear
            isUserInteractionEnabled = false
            guard let window else { return }
            window.backgroundColor=sceneColor
            window.rootViewController?.view.backgroundColor=sceneColor
        }
    }
}

#endif
