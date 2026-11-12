import Foundation
import WebRTC

enum PacingMode: String, Codable {
    case upstream, interactive, smooth
    var screenShareSettings: String {
        switch self {
        case .upstream: return "1.0,2875,80,40,-60,3"
        case .interactive: return "1.5,60,80,40,-60,3"
        case .smooth: return "1.1,60,80,40,-60,3"
        }
    }
}

enum WebRTCRuntime {
    private(set) static var mode = PacingMode.interactive
    private static var initialized = false
    static func initialize(_ mode: PacingMode = .interactive) {
        precondition(!initialized || self.mode == mode, "WebRTC field trials cannot change in a running process")
        guard !initialized else { return }
        self.mode = mode; initialized = true
        // M157 screenshare defaults: factor=1.0, queue=2875 ms. Verified against
        // the shipped binary and upstream AlrExperimentSettings parser. This changes
        // drain pacing, not a hard packet TTL or the congestion controller's minimum rate.
        // The pinned ObjC SDK exposes no per-factory equivalent for this field trial.
        let settings = mode == .upstream ? [:] : ["WebRTC-ProbingScreenshareBwe": mode.screenShareSettings]
        RTCInitFieldTrialDictionary(settings)
        RTCInitializeSSL()
    }
}
