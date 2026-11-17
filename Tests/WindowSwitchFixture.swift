import AppKit

/// Two owned, visibly different real windows for selection/lifecycle regression.
/// Does not inspect, capture, focus or inject events into other applications.
final class FixtureView: NSView {
    let name: String
    let color: NSColor
    var tick = 0
    init(name: String, color: NSColor) { self.name = name; self.color = color; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill(); bounds.fill()
        let text = "KKRemote Window \(name)\nReal window selection test\nFrame \(tick)"
        (text as NSString).draw(in: NSRect(x: 60, y: 250, width: 1100, height: 250),
            withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 44, weight: .bold), .foregroundColor: NSColor.white])
        NSColor.white.setFill()
        NSRect(x: CGFloat(tick % 1000), y: 80, width: 120, height: 60).fill()
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
var windows: [NSWindow] = []
var views: [FixtureView] = []
for (index, name) in ["A", "B"].enumerated() {
    let window = NSWindow(contentRect: NSRect(x: 100 + index * 70, y: 100 + index * 70, width: 1280, height: 720),
        styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    window.title = "KKRemote Window \(name)"
    window.isReleasedWhenClosed = false
    let view = FixtureView(name: name, color: index == 0 ? .systemIndigo : .systemTeal)
    window.contentView = view; window.orderFront(nil)
    windows.append(window); views.append(view)
}
let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
    for view in views { view.tick += 1; view.needsDisplay = true }
}
app.run()
