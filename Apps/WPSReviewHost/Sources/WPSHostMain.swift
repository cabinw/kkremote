import AppKit
import ApplicationServices
import ScreenCaptureKit

@main @MainActor enum WPSHostMain {
    static var host: WPSReviewHost?
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let args = CommandLine.arguments
        // Independent authenticated layout testing; leaves the original loopback review intact.
        if args.contains("--lab-role") || args.contains("--list-windows") { LabCLI.run() }
        let directory = URL(fileURLWithPath: args.last ?? "/tmp/kkremote-wps-review", isDirectory:true)
        try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let report: [String:Any] = ["accessibility":AXIsProcessTrusted(),"screenRecording":CGPreflightScreenCaptureAccess(),
            "screens":NSScreen.screens.map { ["width":$0.visibleFrame.width,"height":$0.visibleFrame.height] }]
        if let bytes = try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) {
            try? bytes.write(to:directory.appendingPathComponent("permissions.json"))
        }
        print("WPS_REVIEW_PERMISSION_CHECK");fflush(stdout)
        if args.contains("--inspect") { return }
        Task { @MainActor in
            do {
                let content=try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:false)
                guard let window=content.windows.first(where:{ $0.owningApplication?.applicationName=="WPS Office" && $0.title=="KKRemote-WPS-Test-20261113.et" }) else { throw WPSFailure("请打开 WPS 测试工作簿") }
                WebRTCRuntime.initialize()
                let instance=try WPSReviewHost(window:window,directory:directory)
                host=instance;try instance.start()
            } catch { print("WPS_REVIEW_ERROR \(error.localizedDescription)");fflush(stdout) }
        }
        NSApp.run()
    }
}
