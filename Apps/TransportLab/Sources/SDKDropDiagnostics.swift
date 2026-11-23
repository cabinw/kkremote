import Foundation
import WebRTC

/// Opt-in, process-local CLI diagnostics. Keep only whitelisted reason labels, never raw SDK logs.
/// One sending peer per process in these probes; log events have no trustworthy frame identity.
final class SDKDropDiagnostics {
    private let logger = RTCCallbackLogger()
    init(trace: FrameTrace) {
        RTCSetMinDebugLogLevel(.none)
        logger.severity = .verbose
        logger.start { [weak trace] message in
            let reason: String?
            if message.contains("Drop Frame: target bitrate") { reason = "media_optimization" }
            else if message.contains("Incoming frame dropped due to that the encoder is blocked.") { reason = "encoder_queue_blocked" }
            else if message.contains("Same/old NTP timestamp") { reason = "non_increasing_ntp" }
            else if message.contains("Dropping frame. Too large for target bitrate.") { reason = "frame_too_large_for_target" }
            else { reason = nil }
            if let reason { trace?.record(.sdkDrop, reason: reason) }
        }
    }
    func stop() { logger.stop() }
}
