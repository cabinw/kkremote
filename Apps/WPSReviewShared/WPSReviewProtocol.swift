import Foundation

struct WPSRect: Codable, Equatable {
    var x: Double, y: Double, width: Double, height: Double
    init(_ r: CGRect) { x=r.minX; y=r.minY; width=r.width; height=r.height }
    var cgRect: CGRect { CGRect(x:x,y:y,width:width,height:height) }
}
struct WPSReviewConfig: Codable {
    let url: String, token: String, session: String, pairingKey: String
    let videoPort: UInt16
}
struct WPSRequest: Codable {
    var kind: String
    var session: String = ""
    var version: Int = 0
    var sequence: Int = 0
    var width: Double? = nil, height: Double? = nil
    var x: Double? = nil, y: Double? = nil
    var dx: Double? = nil, dy: Double? = nil
    var cell: String? = nil, text: String? = nil, id: String? = nil
}
struct WPSState: Codable {
    var session: String
    var version: Int
    var window: WPSRect
    var videoWidth: Int, videoHeight: Int
    var cell: String, value: String
    var formula: WPSRect
    var constrained: Bool
    var error: String? = nil
}
enum WPSWindowLayout {
    static func requested(viewport: CGSize, minimumWidth: Double = 0, screen: CGSize) -> CGSize? {
        guard viewport.width.isFinite,viewport.height.isFinite,viewport.width >= 200,viewport.height >= 150,
              screen.width > 0,screen.height > 0 else { return nil }
        let width = min(screen.width,max(minimumWidth,viewport.width))
        return CGSize(width:width,height:min(screen.height,width*viewport.height/viewport.width))
    }
    static func encoded(_ size: CGSize) -> CGSize {
        // Stay within H.264's verified 720p pixel budget while retaining portrait ratio.
        let scale = min(2,1280/max(size.width,size.height),sqrt(921_600/(size.width*size.height)))
        return CGSize(width:max(16,Int(size.width*scale/16)*16),height:max(16,Int(size.height*scale/16)*16))
    }
}
