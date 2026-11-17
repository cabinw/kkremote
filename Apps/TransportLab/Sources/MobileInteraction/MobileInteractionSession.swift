#if os(iOS)
import SwiftUI

enum MobileInputEvent: Equatable {
    case move(CGPoint), buttonDown, buttonUp, secondaryClick(CGPoint)
    case scroll(CGSize), scrollEnd, text(String, UUID), cancel
}

/// Input is disabled until local preview or a Host control lease is enabled.
@MainActor
final class MobileInteractionSession: ObservableObject {
    @Published private(set) var fillsViewport: Bool
    @Published private(set) var zoom: CGFloat = 1
    @Published private(set) var offset = CGSize.zero
    @Published private(set) var pointer: CGPoint?
    @Published private(set) var status = "点击画面检查坐标"
    @Published private(set) var isDragging = false
    @Published private(set) var isScrolling = false
    @Published private(set) var resetToken = 0
    @Published private(set) var relative = false
    @Published private(set) var inspect = false
    private(set) var source = CGSize.zero
    private(set) var viewport = CGSize.zero
    private(set) var encodedPixels: CGSize?
    private(set) var displayScale: CGFloat = 1
    private var target = ""
    private var lastDragPoint: CGPoint?
    let locksWholeWindow: Bool
    let directScroll: Bool
    let localInputPreview: Bool
    @Published private(set) var remoteInputEnabled = false
    var inputEnabled: Bool { localInputPreview || remoteInputEnabled }
    func enableRemoteInput(_ enabled:Bool) { guard remoteInputEnabled != enabled else { return };cancel();remoteInputEnabled=enabled;resetToken += 1 }
    var onEvent: (MobileInputEvent) -> Void = { _ in }

    init(localInputPreview: Bool = false, directScroll: Bool = false, fillsViewport: Bool = false, locksWholeWindow: Bool = false) {
        self.locksWholeWindow = locksWholeWindow
        self.fillsViewport = locksWholeWindow ? false : fillsViewport
        self.localInputPreview = localInputPreview; self.directScroll = directScroll
    }
    @Published private(set) var keyboardPresented = false
    var fitsKeyboardWidth: Bool { locksWholeWindow && keyboardPresented }
    func setKeyboardPresented(_ value:Bool) {
        guard keyboardPresented != value else { return };cancel();keyboardPresented=value;zoom=1;offset = .zero;resetToken += 1
    }
    func makeGeometry(source: CGSize, viewport: CGSize, encodedPixels: CGSize?, displayScale: CGFloat) -> ViewportGeometry {
        ViewportGeometry(source: source, viewport: viewport, zoom: zoom, offset: offset, fillsViewport: fillsViewport,
                         fitsWidth: fitsKeyboardWidth, encodedPixels: encodedPixels, displayScale: displayScale)
    }
    var geometry: ViewportGeometry { makeGeometry(source: source, viewport: viewport, encodedPixels: encodedPixels, displayScale: displayScale) }

    func configure(source: CGSize, viewport: CGSize, target: String, encodedPixels: CGSize? = nil, displayScale: CGFloat = 1) {
        let layoutChanged = self.source != source || self.viewport != viewport || self.target != target
        guard layoutChanged || self.encodedPixels != encodedPixels || self.displayScale != displayScale else { return }
        let previous = geometry
        let sameWindow = self.source == source && self.target == target && previous.isValid
        cancel(); self.source = source; self.viewport = viewport; self.target = target
        self.encodedPixels = encodedPixels; self.displayScale = displayScale
        // New decoder telemetry must not alter the user's current zoom/pan.
        if !layoutChanged { resetToken += 1; return }
        if sameWindow && !locksWholeWindow {
            // A keyboard changes the visible area, not the window. Preserve the
            // point at the center and its display scale instead of jumping to fit.
            let center = CGPoint(x: (previous.viewport.width / 2 - previous.contentRect.minX) / previous.scale,
                                 y: (previous.viewport.height / 2 - previous.contentRect.minY) / previous.scale)
            let base = ViewportGeometry(source: source, viewport: viewport, fillsViewport: fillsViewport)
            if base.isValid {
                zoom = min(4, max(1, previous.scale / base.scale))
                let next = ViewportGeometry(source: source, viewport: viewport, zoom: zoom,
                    offset: CGSize(width: (source.width / 2 - center.x) * base.scale * zoom,
                                   height: (source.height / 2 - center.y) * base.scale * zoom), fillsViewport: fillsViewport)
                offset = next.clampedOffset; resetToken += 1
                return
            }
        }
        fit()
    }
    /// Reveal an acknowledged source-space focus rectangle without changing zoom.
    func reveal(_ rect: CGRect, padding: CGFloat = 16) {
        let g = geometry
        guard !locksWholeWindow, g.isValid, !rect.isNull, !rect.isEmpty,
              [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy({ $0.isFinite }) else { return }
        let start = g.displayPoint(for: rect.origin)
        let end = g.displayPoint(for: CGPoint(x: rect.maxX, y: rect.maxY))
        let dx = start.x < padding ? padding - start.x : min(0, viewport.width - padding - end.x)
        let dy = start.y < padding ? padding - start.y : min(0, viewport.height - padding - end.y)
        offset = ViewportGeometry(source: source, viewport: viewport, zoom: zoom,
            offset: CGSize(width: offset.width + dx, height: offset.height + dy), fillsViewport: fillsViewport).clampedOffset
    }
    func fit() {
        cancel(); zoom = 1; offset = .zero
        if fillsViewport {
            // Start at the window's top-left, keeping row labels and the first column visible.
            let size = geometry.contentSize
            offset = CGSize(width:max(0,(size.width-viewport.width)/2),height:max(0,(size.height-viewport.height)/2))
        }
        pointer = nil; resetToken += 1
    }
    func setFillsViewport(_ value: Bool) { fillsViewport = locksWholeWindow ? false : value; fit() }
    func zoomIn() { guard !locksWholeWindow else { return }; cancel(); zoom = min(4, zoom + 0.5); resetToken += 1 }
    func toggleMode() {
        cancel(); relative.toggle(); pointer = nil; resetToken += 1
        status = relative ? "滑动控制指针" : "点击画面检查坐标"
    }
    func toggleInspection() { cancel(); inspect.toggle(); resetToken += 1 }
    func invalidate() { cancel(); pointer = nil; resetToken += 1 }
    func cancel() {
        if isDragging { emit(.buttonUp); isDragging = false }
        if isScrolling { emit(.scrollEnd); isScrolling = false }
        lastDragPoint = nil
    }
    func commit(_ text: String, id: UUID) { guard inputEnabled else { return }; emit(.text(text, id)); status = localInputPreview ? "已提交至本地预览":"等待远端确认" }

    func handle(_ action: LocalGestureAction) {
        let geometry = self.geometry
        switch action {
        case let .zoom(factor, anchor):
            guard !locksWholeWindow else { return }
            cancel()
            let next = geometry.zoomed(to: zoom * factor, anchor: anchor)
            zoom = next.zoom; offset = next.clampedOffset
        case let .pan(delta):
            guard !locksWholeWindow else { return }
            offset = ViewportGeometry(source: source, viewport: viewport, zoom: zoom,
                offset: CGSize(width: offset.width + delta.width, height: offset.height + delta.height), fillsViewport: fillsViewport).clampedOffset
        case .cancel: cancel()
        default:
            guard inputEnabled, !inspect, geometry.isValid else { return }
            handleInput(action, geometry: geometry)
        }
    }
    private func handleInput(_ action: LocalGestureAction, geometry: ViewportGeometry) {
        switch action {
        case let .tap(point):
            guard let point = resolve(point) else { status = "画面外 · 已忽略"; return }
            move(point, label: "点击"); emit(.buttonDown); emit(.buttonUp)
        case let .secondaryClick(point):
            guard let point = resolve(point) else { return }
            move(point, label: "右键预览"); emit(.secondaryClick(point))
        case let .relativeMove(delta):
            let origin = pointer ?? center
            move(clamp(CGPoint(x: origin.x + delta.width / geometry.scale, y: origin.y + delta.height / geometry.scale)), label: "指针")
        case let .dragBegan(point):
            guard !remoteInputEnabled else { status="拖选尚未启用，请直接点击或滑动滚动";return }
            guard let sourcePoint = resolve(point) else { return }
            lastDragPoint = point
            move(sourcePoint, label: "拖拽开始"); isDragging = true; emit(.buttonDown)
        case let .dragMoved(point):
            guard isDragging else { return }
            // Dragging beyond the content clamps to its edge and still releases.
            let origin = pointer ?? center, previous = lastDragPoint ?? point
            let mapped = relative ? CGPoint(x: origin.x + (point.x - previous.x) / geometry.scale,
                                            y: origin.y + (point.y - previous.y) / geometry.scale) :
                CGPoint(x: (point.x - geometry.contentRect.minX) / geometry.scale,
                        y: (point.y - geometry.contentRect.minY) / geometry.scale)
            lastDragPoint = point
            move(clamp(mapped), label: "拖拽中")
        case .dragEnded: cancel(); status = "拖拽已释放"
        case let .scrollBegan(point):
            guard let sourcePoint=resolve(point) else { return }
            if remoteInputEnabled { move(sourcePoint,label:"滚动") }
            isScrolling = true; status = "滚动中"
        case let .scroll(delta):
            guard isScrolling else { return }
            emit(.scroll(CGSize(width: delta.width / geometry.scale, height: delta.height / geometry.scale)))
        case .scrollEnded: cancel(); status = "滚动已结束"
        default: break
        }
    }
    private var center: CGPoint { CGPoint(x: source.width / 2, y: source.height / 2) }
    private func resolve(_ point: CGPoint) -> CGPoint? { relative ? (pointer ?? center) : geometry.sourcePoint(at: point) }
    private func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, source.width - 0.001), max(0, point.x)), y: min(max(0, source.height - 0.001), max(0, point.y)))
    }
    private func move(_ point: CGPoint, label: String) {
        pointer = point; status = "\(label) · \(Int(point.x)), \(Int(point.y))"; emit(.move(point))
    }
    private func emit(_ event: MobileInputEvent) { if inputEnabled { onEvent(event) } }
}
#endif
