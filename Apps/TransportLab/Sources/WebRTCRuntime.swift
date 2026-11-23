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
    // CLI probes only. Never enabled by signalling or client interaction.
    static var sdkDropDiagnostics = false
    static var disableFrameDropperForSelfTest = false
    // Reduce periodic keyframe bursts. PLI/requested keyframes bypass this periodic limit.
    // CLI keeps a 2-second control; this limit is expressed in frames by VideoToolbox.
    static var hevcKeyframeSeconds: Int32 = 10
    // Explicit quality experiments retain the existing rate budget and frame reordering policy.
    static var hevcMaximumFrameQP: Int?
    static var windowTextQuality = false
    private(set) static var mode = PacingMode.interactive
    private(set) static var playout = PlayoutMode.adaptive
    private static var initialized = false
    static func initialize(_ mode: PacingMode = .interactive, playout: PlayoutMode? = nil) {
        let selectedPlayout = playout ?? self.playout
        precondition(!initialized || (self.mode == mode && self.playout == selectedPlayout), "WebRTC field trials cannot change in a running process")
        guard !initialized else { return }
        self.mode = mode; self.playout = selectedPlayout; initialized = true
        // M157 screenshare defaults: factor=1.0, queue=2875 ms. Verified against
        // the shipped binary and upstream AlrExperimentSettings parser. This changes
        // drain pacing, not a hard packet TTL or the congestion controller's minimum rate.
        // The pinned ObjC SDK exposes no per-factory equivalent for this field trial.
        var settings = mode == .upstream ? [:] : ["WebRTC-ProbingScreenshareBwe": mode.screenShareSettings]
        if disableFrameDropperForSelfTest { settings["WebRTC-FrameDropper"] = "Disabled" }
        if let delay = selectedPlayout.senderOverride {
            // M157 commit 95554e4a: signal the standard RTP playout-delay extension.
            // This adjusts playback scheduling on compatible receivers without
            // disabling congestion control, frame dependencies, NACK or RTX recovery.
            settings["WebRTC-ForceSendPlayoutDelay"] = delay
        }
        RTCInitFieldTrialDictionary(settings)
        RTCInitializeSSL()
    }
}

enum PlayoutMode: String, Codable {
    case adaptive, realtime
    var senderOverride: String? {
        switch self {
        case .adaptive: return nil
        case .realtime: return "min_ms:0,max_ms:50"
        }
    }
}
