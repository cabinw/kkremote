import Foundation

/// Title agreement is only one part of identity: callers must also verify PID,
/// CG window existence, unique AX match and frame (or the retained AX element).
enum WindowTitleIdentity {
    static func matches(_ accessibilityTitle:String, captureTitle:String, application:String)->Bool {
        if String(accessibilityTitle.prefix(128)) == captureTitle { return true }
        // Observed Chrome AX titles append this suffix; ScreenCaptureKit omits it.
        // Do not accept arbitrary substring matches or strip other app suffixes.
        let suffix=" - Google Chrome"
        guard application == "Google Chrome", !captureTitle.isEmpty,
              accessibilityTitle.hasSuffix(suffix) else { return false }
        return String(accessibilityTitle.dropLast(suffix.count).prefix(128)) == captureTitle
    }
}
