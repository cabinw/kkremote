import Foundation
import CoreGraphics

enum LocalGestureAction: Equatable {
    case tap(CGPoint), secondaryClick(CGPoint), relativeMove(CGSize)
    case dragBegan(CGPoint), dragMoved(CGPoint), dragEnded, cancel
    case scrollBegan(CGPoint), scroll(CGSize), scrollEnded
    case pan(CGSize), zoom(CGFloat, CGPoint)
}

/// Deterministic touch arbitration. Once two fingers choose scroll or zoom, that
/// choice is locked until both lift; a pinch can never leak a remote scroll.
struct InteractionGestureMachine {
    struct Contact { let id: Int; let point: CGPoint }
    var directScroll = false
    var relative = false
    var inspect = false
    private var initial: [Contact] = []
    private var last: [Contact] = []
    private var beganAt: TimeInterval = 0
    private var moved = false
    private var dragging = false
    private var scrolling = false
    private var heldBeforeMove = false
    private var suppressed = false
    private enum TwoFingerIntent { case pending, scroll, zoom, pan }
    private var intent = TwoFingerIntent.pending

    mutating func update(_ contacts: [Contact], at time: TimeInterval) -> [LocalGestureAction] {
        let points = contacts.sorted { $0.id < $1.id }
        if points.isEmpty {
            defer { clear() }
            if suppressed { return [] }
            if initial.count == 2 { return intent == .scroll ? [.scrollEnded] : [] }
            if dragging { return [.dragEnded] }
            if scrolling { return [.scrollEnded] }
            guard let start = initial.first, !moved else { return [] }
            return [time - beganAt >= 0.4 ? .secondaryClick(start.point) : .tap(start.point)]
        }
        if suppressed { return [] }
        if points.count > 2 { return cancel() }
        if initial.isEmpty {
            initial = points; last = points; beganAt = time
            return []
        }
        if initial.count == 1 && points.count == 2 {
            let events: [LocalGestureAction] = dragging ? [.dragEnded] : (scrolling ? [.scrollEnded] : [])
            dragging = false; scrolling = false; initial = points; last = points; intent = .pending
            return events
        }
        if initial.count == 2 && points.count == 1 {
            suppressed = true
            return intent == .scroll ? [.scrollEnded] : []
        }
        guard points.map(\.id) == initial.map(\.id) else { return cancel() }
        defer { last = points }
        if points.count == 1 {
            let origin = initial[0].point, current = points[0].point, previous = last[0].point
            let distance = hypot(current.x - origin.x, current.y - origin.y)
            if distance > 6 && !moved { moved = true; heldBeforeMove = time - beganAt >= 0.4 }
            if inspect {
                return moved ? [.pan(delta(current, previous))] : []
            }
            if dragging { return [.dragMoved(current)] }
            if heldBeforeMove && moved {
                dragging = true
                return [.dragBegan(origin), .dragMoved(current)]
            }
            if directScroll && !relative && moved {
                if scrolling { return [.scroll(delta(current, previous))] }
                scrolling = true
                return [.scrollBegan(origin), .scroll(delta(current, origin))]
            }
            // A fast direct swipe is not guessed to be a drag. In trackpad mode
            // it moves the pointer; dragging requires hold then movement.
            return relative && moved ? [.relativeMove(delta(current, previous))] : []
        }
        let center = midpoint(points), oldCenter = midpoint(last), startCenter = midpoint(initial)
        let startDistance = max(1, separation(initial)), currentDistance = max(1, separation(points))
        if intent == .pending {
            if abs(currentDistance / startDistance - 1) > 0.06 {
                intent = .zoom
                return [.zoom(currentDistance / startDistance, startCenter), .pan(delta(center, startCenter))]
            }
            if hypot(center.x - startCenter.x, center.y - startCenter.y) > 8 {
                intent = inspect ? .pan : .scroll
                return inspect ? [.pan(delta(center, startCenter))] : [.scrollBegan(startCenter), .scroll(delta(center, startCenter))]
            }
            return []
        }
        switch intent {
        case .zoom: return [.zoom(currentDistance / max(1, separation(last)), oldCenter), .pan(delta(center, oldCenter))]
        case .pan: return [.pan(delta(center, oldCenter))]
        case .scroll: return [.scroll(delta(center, oldCenter))]
        case .pending: return []
        }
    }
    mutating func cancel() -> [LocalGestureAction] {
        clear(); suppressed = true
        return [.cancel]
    }
    private mutating func clear() {
        initial = []; last = []; moved = false; dragging = false; scrolling = false; heldBeforeMove = false; suppressed = false; intent = .pending
    }
    private func midpoint(_ points: [Contact]) -> CGPoint {
        CGPoint(x: (points[0].point.x + points[1].point.x) / 2, y: (points[0].point.y + points[1].point.y) / 2)
    }
    private func separation(_ points: [Contact]) -> CGFloat {
        hypot(points[0].point.x - points[1].point.x, points[0].point.y - points[1].point.y)
    }
    private func delta(_ point: CGPoint, _ previous: CGPoint) -> CGSize {
        CGSize(width: point.x - previous.x, height: point.y - previous.y)
    }
}
