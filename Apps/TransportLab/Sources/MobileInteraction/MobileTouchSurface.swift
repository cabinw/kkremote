#if os(iOS)
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

struct MobileTouchSurface: UIViewRepresentable {
    @ObservedObject var session: MobileInteractionSession
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isMultipleTouchEnabled = true
        view.accessibilityIdentifier = "viewportGestureSurface"
        let gesture = MobileTouchRecognizer(session: session)
        view.addGestureRecognizer(gesture)
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {
        (view.gestureRecognizers?.first as? MobileTouchRecognizer)?.synchronize()
    }
    static func dismantleUIView(_ view: UIView, coordinator: ()) {
        (view.gestureRecognizers?.first as? MobileTouchRecognizer)?.abort()
    }
}

@MainActor
final class MobileTouchRecognizer: UIGestureRecognizer {
    private let session: MobileInteractionSession
    private var machine = InteractionGestureMachine()
    private var contacts: [ObjectIdentifier: (Int, UITouch)] = [:]
    private var nextID = 0
    private var token: Int
    init(session: MobileInteractionSession) {
        self.session = session; token = session.resetToken
        super.init(target: nil, action: nil)
        cancelsTouchesInView = true
        machine.directScroll = session.directScroll; machine.relative = session.relative; machine.inspect = session.inspect || !session.inputEnabled
    }
    func synchronize() {
        guard token != session.resetToken else { return }
        abort(); token = session.resetToken
        machine.directScroll = session.directScroll; machine.relative = session.relative; machine.inspect = session.inspect || !session.inputEnabled
    }
    func abort() {
        session.cancel()
        if contacts.isEmpty {
            machine = InteractionGestureMachine()
            machine.directScroll = session.directScroll; machine.relative = session.relative; machine.inspect = session.inspect || !session.inputEnabled
        } else {
            _ = machine.cancel()
            if state == .began || state == .changed { state = .cancelled }
        }
    }
    override func reset() {
        super.reset(); contacts = [:]
        machine = InteractionGestureMachine()
        machine.directScroll = session.directScroll; machine.relative = session.relative; machine.inspect = session.inspect || !session.inputEnabled
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches { nextID += 1; contacts[ObjectIdentifier(touch)] = (nextID, touch) }
        update(at: event.timestamp)
        if state == .possible { state = .began }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        update(at: event.timestamp); state = .changed
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches { contacts.removeValue(forKey: ObjectIdentifier(touch)) }
        update(at: event.timestamp)
        if contacts.isEmpty { state = .ended }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { abort() }
    private func update(at time: TimeInterval) {
        let points = contacts.values.map { InteractionGestureMachine.Contact(id: $0.0, point: $0.1.location(in: view)) }
        machine.update(points, at: time).forEach(session.handle)
    }
}
#endif
