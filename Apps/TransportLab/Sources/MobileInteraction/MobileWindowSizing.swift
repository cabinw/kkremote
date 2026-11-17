import Foundation
import CoreGraphics

/// Logical window proposals. Actual input mapping must use the acknowledged
/// source/frame size, never this proposal. Keyboard presentation is not a resize.
struct MobileWindowSizing {
    /// Fit a 4:2:0 canvas inside the physical viewport. One unused edge pixel
    /// is preferable to scaling every sample to cover an odd-size viewport.
    static func nativeClientPixels(viewport:CGSize,displayScale:CGFloat)->CGSize? {
        guard viewport.width.isFinite,viewport.height.isFinite,viewport.width>0,viewport.height>0,
              displayScale.isFinite,(1...3).contains(displayScale) else{return nil}
        let size=CGSize(width:floor((viewport.width*displayScale+1e-7)/2)*2,
                        height:floor((viewport.height*displayScale+1e-7)/2)*2)
        guard size.width>=2,size.height>=2 else{return nil}
        return size
    }
    /// Request genuine backing pixels by resizing the source window in points.
    /// App content zoom is independent: this never magnifies a captured bitmap.
    static func nativeSourcePoints(viewport:CGSize,displayScale:CGFloat,nativeScale:CGFloat,
                                   maximumPixels:CGFloat,availablePoints:CGSize)->CGSize? {
        guard viewport.width.isFinite,viewport.height.isFinite,viewport.width>0,viewport.height>0,
              displayScale.isFinite,(1...3).contains(displayScale),nativeScale.isFinite,nativeScale>0,
              maximumPixels.isFinite,maximumPixels>=4,availablePoints.width.isFinite,availablePoints.height.isFinite else{return nil}
        guard let pixels=nativeClientPixels(viewport:viewport,displayScale:displayScale) else{return nil}
        let size=CGSize(width:pixels.width/nativeScale,height:pixels.height/nativeScale)
        guard size.width<=availablePoints.width,size.height<=availablePoints.height,
              size.width*nativeScale<=4096,size.height*nativeScale<=4096,
              size.width*size.height*nativeScale*nativeScale<=maximumPixels else{return nil}
        return size
    }
    enum Mode { case adaptive, desktop }
    static func proposal(for viewport: CGSize, mode: Mode = .adaptive) -> CGSize? {
        guard viewport.width.isFinite, viewport.height.isFinite,
              viewport.width > 0, viewport.height > 0 else { return nil }
        if mode == .desktop { return CGSize(width: 1280, height: 800) }
        let scale = max(1, 320 / viewport.width, 160 / viewport.height)
        let width = min(1600, max(320, (viewport.width * scale).rounded()))
        let height = min(2400, max(160, (viewport.height * scale).rounded()))
        return CGSize(width: width, height: height)
    }
    /// Preserve the window's native pixels within the existing encoder pixel budget.
    /// Even dimensions are required by the 4:2:0 encoder; never upscale beyond capture scale.
    static func capturePixels(for source: CGSize, pointPixelScale: CGFloat, maximumPixels: CGFloat) -> CGSize? {
        guard source.width.isFinite,source.height.isFinite,source.width > 0,source.height > 0,
              pointPixelScale.isFinite,pointPixelScale > 0,maximumPixels.isFinite,maximumPixels >= 4 else { return nil }
        let scale=min(pointPixelScale,sqrt(maximumPixels/source.width/source.height),4096/max(source.width,source.height))
        guard scale.isFinite,scale > 0 else { return nil }
        return CGSize(width:max(2,floor(source.width*scale/2)*2),height:max(2,floor(source.height*scale/2)*2))
    }

    /// Move resampling ahead of chroma subsampling. This is an encoding canvas,
    /// not a claim that the remote app rendered more native detail.
    static func encodingPixels(for source: CGSize, nativeScale: CGFloat, viewport: CGSize,
                               displayScale: CGFloat, maximumPixels: CGFloat) -> CGSize? {
        guard source.width > 0,source.height > 0,viewport.width.isFinite,viewport.height.isFinite,
              viewport.width > 0,viewport.height > 0,displayScale.isFinite,(1...3).contains(displayScale) else {return nil}
        let requested=min(viewport.width/source.width,viewport.height/source.height)*displayScale
        return capturePixels(for:source,pointPixelScale:max(nativeScale,requested),maximumPixels:maximumPixels)
    }

}
