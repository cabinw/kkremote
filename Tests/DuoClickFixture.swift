import AppKit

// For the Duo round trip test, keep the physical display's center on an owned target.
final class ClickCounter: NSView {
    let result: URL
    var hits = 0
    var keyEvents: [String] = []
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let modifier = event.modifierFlags.contains(.capsLock) ? "caps" : (event.modifierFlags.contains(.shift) ? "shift" : "plain")
        keyEvents.append("\(event.keyCode) \(modifier)")
        try? keyEvents.joined(separator: "\n").write(to: result.appendingPathExtension("keys"), atomically: true, encoding: .utf8)
    }

    init(result: URL) {
        self.result = result
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        hits += 1
        // Hold this owned target above other windows for the following desktop click.
        if hits == 1, let window {
            window.level = .popUpMenu
            window.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 35) { window.level = .normal }
        } else {
            window?.level = .normal
        }
        do {
            try String(hits).write(to: result, atomically: true, encoding: .utf8)
        } catch {
            NSLog("Unable to write click result")
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        (hits == 0 ? NSColor.systemIndigo : NSColor.systemGreen).setFill()
        bounds.fill()
        ("Duo window · clicks " + String(hits)).draw(
            at: NSPoint(x: 40, y: bounds.midY),
            withAttributes: [.font: NSFont.systemFont(ofSize: 32), .foregroundColor: NSColor.white])
    }
}

let twoWindows = CommandLine.arguments.dropFirst(2).elementsEqual(["--two-windows"])
guard (CommandLine.arguments.count == 2 || twoWindows), let display = NSScreen.screens.first else { exit(2) }
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let size = CGSize(width: 640, height: 420)
let rect = CGRect(x: display.frame.midX - size.width / 2, y: display.frame.midY - size.height / 2,
                  width: size.width, height: size.height)
let window = NSWindow(contentRect: rect, styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.title = "KKRemote Duo Click Fixture"
window.contentView = ClickCounter(result: URL(fileURLWithPath: CommandLine.arguments[1]))
let secondary: NSWindow? = twoWindows ? NSWindow(contentRect: NSRect(x: 40, y: 70, width: 250, height: 160),
    styleMask: [.titled], backing: .buffered, defer: false) : nil
secondary?.title = "KKRemote Dock Secondary"
secondary?.orderFront(nil)
window.makeKeyAndOrderFront(nil)
app.activate()
app.run()
