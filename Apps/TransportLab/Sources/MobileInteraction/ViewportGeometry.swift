import Foundation
import CoreGraphics

/// Pure geometry shared by rendering and hit testing. All source coordinates are
/// logical window points, not encoded pixels or device screen pixels.
struct ViewportGeometry {
    let source: CGSize
    let viewport: CGSize
    let zoom: CGFloat
    let offset: CGSize
    let fillsViewport: Bool
    let fitsWidth: Bool
    let encodedPixels: CGSize?
    let displayScale: CGFloat

    init(source: CGSize, viewport: CGSize, zoom: CGFloat = 1, offset: CGSize = .zero, fillsViewport: Bool = false, fitsWidth: Bool = false, encodedPixels: CGSize? = nil, displayScale: CGFloat = 1) {
        self.source = source
        self.viewport = viewport
        self.zoom = zoom.isFinite ? min(4, max(1, zoom)) : 1
        self.offset = offset
        self.fillsViewport = fillsViewport
        self.fitsWidth = fitsWidth
        self.encodedPixels = encodedPixels
        self.displayScale = displayScale
    }

    var isValid: Bool {
        [source.width, source.height, viewport.width, viewport.height].allSatisfy { $0.isFinite && $0 > 0 }
    }
    var scale: CGFloat {
        guard isValid else { return 0 }
        if pixelExact, let encodedPixels { return encodedPixels.width / displayScale / source.width }
        let x = viewport.width / source.width, y = viewport.height / source.height
        return (fitsWidth ? x : (fillsViewport ? max(x, y) : min(x, y))) * zoom
    }
    /// Only an unpadded, matching source that almost fills the physical viewport
    /// can bypass fit. Tolerances account for floating point arithmetic, not a
    /// missing source row/column or an old frame during a window transition.
    var pixelExact: Bool {
        guard isValid, zoom == 1, !fillsViewport, !fitsWidth,
              displayScale.isFinite, (1...3).contains(displayScale), let pixels = encodedPixels,
              [pixels.width, pixels.height].allSatisfy({ $0.isFinite && $0 > 0 && $0.truncatingRemainder(dividingBy: 2) == 0 }) else { return false }
        let gaps = [viewport.width * displayScale - pixels.width, viewport.height * displayScale - pixels.height]
        guard gaps.allSatisfy({ $0 >= -0.000001 && $0 < 2 - 0.000001 }) else { return false }
        return abs(pixels.width * source.height / source.width - pixels.height) < 0.000001
    }
    var contentSize: CGSize {
        if pixelExact, let encodedPixels { return CGSize(width: encodedPixels.width / displayScale, height: encodedPixels.height / displayScale) }
        return CGSize(width: source.width * scale, height: source.height * scale)
    }
    var clampedOffset: CGSize {
        guard isValid else { return .zero }
        let x = max(0, (contentSize.width - viewport.width) / 2)
        let y = max(0, (contentSize.height - viewport.height) / 2)
        return CGSize(width: offset.width.isFinite ? min(x, max(-x, offset.width)) : 0,
                      height: offset.height.isFinite ? min(y, max(-y, offset.height)) : 0)
    }
    var contentRect: CGRect {
        guard isValid else { return .zero }
        if pixelExact, let encodedPixels {
            // An odd spare pixel belongs on the trailing edge, never half on
            // each side; the video origin stays on the physical pixel grid.
            return CGRect(x: floor(max(0, viewport.width * displayScale - encodedPixels.width) / 2) / displayScale,
                          y: floor(max(0, viewport.height * displayScale - encodedPixels.height) / 2) / displayScale,
                          width: contentSize.width, height: contentSize.height)
        }
        return CGRect(x: (viewport.width - contentSize.width) / 2 + clampedOffset.width,
                      y: fitsWidth ? min(0,max(viewport.height-contentSize.height,offset.height.isFinite ? offset.height:0)) : (viewport.height - contentSize.height) / 2 + clampedOffset.height,
                      width: contentSize.width, height: contentSize.height)
    }
    func sourcePoint(at point: CGPoint) -> CGPoint? {
        guard isValid, point.x.isFinite, point.y.isFinite,
              CGRect(origin: .zero, size: viewport).contains(point), contentRect.contains(point) else { return nil }
        return CGPoint(x: (point.x - contentRect.minX) / scale, y: (point.y - contentRect.minY) / scale)
    }
    func displayPoint(for point: CGPoint) -> CGPoint {
        CGPoint(x: contentRect.minX + point.x * scale, y: contentRect.minY + point.y * scale)
    }
    /// Keep the content under the pinch centroid stationary until an edge clamps it.
    func zoomed(to value: CGFloat, anchor: CGPoint) -> ViewportGeometry {
        guard isValid else { return self }
        let point = CGPoint(x: (anchor.x - contentRect.minX) / scale, y: (anchor.y - contentRect.minY) / scale)
        let next = ViewportGeometry(source: source, viewport: viewport, zoom: value, fillsViewport: fillsViewport, fitsWidth: fitsWidth, encodedPixels: encodedPixels, displayScale: displayScale)
        return ViewportGeometry(source: source, viewport: viewport, zoom: next.zoom,
            offset: CGSize(width: anchor.x - viewport.width / 2 - (point.x - source.width / 2) * next.scale,
                           height: anchor.y - viewport.height / 2 - (point.y - source.height / 2) * next.scale), fillsViewport: fillsViewport, fitsWidth: fitsWidth, encodedPixels: encodedPixels, displayScale: displayScale)
    }
}
