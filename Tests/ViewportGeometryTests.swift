import Foundation
import CoreGraphics

@main
struct ViewportGeometryTests {
    static func main() {
        var assertions = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message); assertions += 1
        }
        func close(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.000001 }
        let phone = CGSize(width: 393, height: 600)
        let wide = CGSize(width: 1280, height: 720)
        let fit = ViewportGeometry(source: wide, viewport: phone)
        check(close(fit.contentRect.width, phone.width), "Aspect fit fills width")
        check(fit.sourcePoint(at: CGPoint(x: 100, y: 10)) == nil, "Letterbox rejects input")
        check(fit.sourcePoint(at: CGPoint(x: -1, y: 300)) == nil, "Outside viewport rejects input")
        let center = fit.sourcePoint(at: CGPoint(x: phone.width / 2, y: phone.height / 2))!
        check(close(center.x, 640) && close(center.y, 360), "Center maps to source center")
        for viewport in [phone, CGSize(width: 852, height: 320), CGSize(width: 1000, height: 1000), CGSize(width: 320, height: 900)] {
            for source in [wide, CGSize(width: 720, height: 1000)] {
                for zoom: CGFloat in [1, 1.5, 2, 4] {
                    let geometry = ViewportGeometry(source: source, viewport: viewport, zoom: zoom,
                                                    offset: CGSize(width: 10000, height: -10000))
                    let rect = geometry.contentRect
                    if rect.width >= viewport.width {
                        check(rect.minX <= 0.000001 && rect.maxX >= viewport.width - 0.000001, "Pan cannot reveal horizontal blank space")
                    }
                    if rect.height >= viewport.height {
                        check(rect.minY <= 0.000001 && rect.maxY >= viewport.height - 0.000001, "Pan cannot reveal vertical blank space")
                    }
                    for x in stride(from: CGFloat(0.1), through: 0.9, by: 0.1) {
                        for y in stride(from: CGFloat(0.1), through: 0.9, by: 0.1) {
                            let display = CGPoint(x: viewport.width * x, y: viewport.height * y)
                            if let point = geometry.sourcePoint(at: display) {
                                let result = geometry.displayPoint(for: point)
                                check(close(result.x, display.x) && close(result.y, display.y), "Round trip remains accurate after zoom/pan")
                            }
                        }
                    }
                }
            }
        }
        let square = ViewportGeometry(source: CGSize(width: 1000, height: 1000), viewport: CGSize(width: 500, height: 500))
        let anchor = CGPoint(x: 150, y: 200)
        let before = square.sourcePoint(at: anchor)!
        let after = square.zoomed(to: 2, anchor: anchor).sourcePoint(at: anchor)!
        check(close(before.x, after.x) && close(before.y, after.y), "Pinch keeps its anchor")
        check(ViewportGeometry(source: .zero, viewport: phone).sourcePoint(at: .zero) == nil, "Unknown source disables mapping")
        check(ViewportGeometry(source: wide, viewport: .zero).sourcePoint(at: .zero) == nil, "Zero viewport disables mapping")
        check(ViewportGeometry(source: wide, viewport: phone, zoom: .nan).zoom == 1, "Invalid zoom is sanitized")
        check(ViewportGeometry(source: wide, viewport: phone, zoom: 99).zoom == 4, "Zoom has a bound")
        let nativeSource = CGSize(width:645,height:1309)
        let nativePixels = CGSize(width:1290,height:2618)
        let nativeViewport = CGSize(width:430,height:873)
        let exact = ViewportGeometry(source:nativeSource,viewport:nativeViewport,encodedPixels:nativePixels,displayScale:3)
        check(exact.pixelExact,"Matching native canvas enables exact pixels")
        check(close(exact.contentSize.width*3,1290) && close(exact.contentSize.height*3,2618),"Display preserves decoded pixel dimensions")
        check(exact.contentRect.origin == .zero,"One spare row stays at the bottom instead of half-pixel centering")
        check(exact.sourcePoint(at:CGPoint(x:200,y:872.9)) == nil,"Spare bottom row never sends input")
        check(close(exact.scale,2.0/3),"Mac source points remain distinct from phone points")
        for (source,pixels,viewport) in [
            (nativeSource,nativePixels,nativeViewport),
            (CGSize(width:1221,height:645),CGSize(width:2442,height:1290),CGSize(width:814,height:430)),
            (nativeSource,nativePixels,CGSize(width:430+1.0/3,height:873))
        ] {
            let g=ViewportGeometry(source:source,viewport:viewport,encodedPixels:pixels,displayScale:3)
            check(g.pixelExact,"Portrait, landscape and spare-column canvases are exact")
            check(close(g.contentRect.minX*3,(g.contentRect.minX*3).rounded()) && close(g.contentRect.minY*3,(g.contentRect.minY*3).rounded()),"Origin sits on the physical pixel grid")
            check(close(g.contentSize.width*3,pixels.width) && close(g.contentSize.height*3,pixels.height),"Neither axis is resampled")
            for x in stride(from:CGFloat(0.1),through:0.9,by:0.1) {
                for y in stride(from:CGFloat(0.1),through:0.9,by:0.1) {
                    let point=CGPoint(x:source.width*x,y:source.height*y)
                    let mapped=g.sourcePoint(at:g.displayPoint(for:point))!
                    check(close(mapped.x,point.x) && close(mapped.y,point.y),"Exact display/input mapping round trips")
                }
            }
        }
        let spareColumn=ViewportGeometry(source:nativeSource,viewport:CGSize(width:430+1.0/3,height:873),encodedPixels:nativePixels,displayScale:3)
        check(spareColumn.sourcePoint(at:CGPoint(x:430.1,y:200)) == nil,"Spare column rejects touches")
        let retina2=ViewportGeometry(source:nativeSource,viewport:CGSize(width:645,height:1309.5),encodedPixels:nativePixels,displayScale:2)
        check(retina2.pixelExact && close(retina2.scale,1),"2x screens preserve exact pixels too")
        for g in [
            ViewportGeometry(source:nativeSource,viewport:nativeViewport),
            ViewportGeometry(source:nativeSource,viewport:nativeViewport,zoom:2,encodedPixels:nativePixels,displayScale:3),
            ViewportGeometry(source:nativeSource,viewport:nativeViewport,fillsViewport:true,encodedPixels:nativePixels,displayScale:3),
            ViewportGeometry(source:nativeSource,viewport:CGSize(width:430,height:518),fitsWidth:true,encodedPixels:nativePixels,displayScale:3),
            ViewportGeometry(source:CGSize(width:500,height:1015),viewport:nativeViewport,encodedPixels:CGSize(width:1000,height:2030),displayScale:3),
            ViewportGeometry(source:CGSize(width:645,height:1310),viewport:nativeViewport,encodedPixels:CGSize(width:1290,height:2620),displayScale:3),
            ViewportGeometry(source:CGSize(width:645,height:1309.5),viewport:nativeViewport,encodedPixels:nativePixels,displayScale:3),
            ViewportGeometry(source:nativeSource,viewport:CGSize(width:430,height:874),encodedPixels:nativePixels,displayScale:3),
            ViewportGeometry(source:nativeSource,viewport:CGSize(width:430,height:2620.0/3),encodedPixels:nativePixels,displayScale:3),
            ViewportGeometry(source:CGSize(width:1221,height:645),viewport:nativeViewport,encodedPixels:nativePixels,displayScale:3),
            ViewportGeometry(source:nativeSource,viewport:nativeViewport,encodedPixels:CGSize(width:1291,height:2618),displayScale:3),
            ViewportGeometry(source:nativeSource,viewport:nativeViewport,encodedPixels:CGSize(width:1290,height:CGFloat.nan),displayScale:3),
            ViewportGeometry(source:nativeSource,viewport:nativeViewport,encodedPixels:nativePixels,displayScale:0),
            ViewportGeometry(source:nativeSource,viewport:nativeViewport,encodedPixels:nativePixels,displayScale:.nan)
        ] {
            check(!g.pixelExact,"Old frames, padding, aspect mismatch, keyboard, zoom and invalid metadata fall back")
            let legacy=ViewportGeometry(source:g.source,viewport:g.viewport,zoom:g.zoom,offset:g.offset,fillsViewport:g.fillsViewport,fitsWidth:g.fitsWidth)
            check(g.contentRect == legacy.contentRect && g.scale == legacy.scale,"Fallback exactly preserves existing geometry")
        }
        let zoomed=exact.zoomed(to:2,anchor:CGPoint(x:200,y:400))
        let originalPoint=exact.sourcePoint(at:CGPoint(x:200,y:400))!
        let zoomedPoint=zoomed.sourcePoint(at:CGPoint(x:200,y:400))!
        check(!zoomed.pixelExact && close(originalPoint.x,zoomedPoint.x) && close(originalPoint.y,zoomedPoint.y),"Leaving exact mode retains the pinch anchor")
        print("Viewport geometry: \(assertions) assertions passed")
    }
}
