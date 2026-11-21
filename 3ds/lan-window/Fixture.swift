import AppKit

final class Target: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 305),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
    let button = NSButton()
    let clock = NSTextField(labelWithString: "")
    var taps = 0
    func applicationDidFinishLaunching(_ notification: Notification) {
        window.title = "KKRemote LAN Test"
        window.delegate = self
        let view = window.contentView!
        let title = NSTextField(labelWithString: "KKRemote  •  LIVE")
        title.font = .boldSystemFont(ofSize: 28)
        title.frame = NSRect(x: 30, y: 240, width: 500, height: 42)
        clock.font = .monospacedDigitSystemFont(ofSize: 22, weight: .regular)
        clock.frame = NSRect(x: 30, y: 190, width: 500, height: 40)
        button.frame = NSRect(x: 65, y: 60, width: 430, height: 108)
        button.bezelStyle = .regularSquare
        button.title = "Click here   •   0"
        button.font = .boldSystemFont(ofSize: 26)
        button.target = self; button.action = #selector(count)
        [title, clock, button].forEach(view.addSubview)
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss"
        clock.stringValue = formatter.string(from: Date())
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [self] _ in clock.stringValue = formatter.string(from: Date()) }
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        print(window.windowNumber); fflush(stdout)
    }
    @objc func count() { taps += 1; button.title = "Click here   •   \(taps)"; fputs("CLICK \(taps)\n", stderr) }
    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }
}
@main struct Fixture {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let target = Target(); app.delegate = target
        withExtendedLifetime(target) { app.run() }
    }
}
