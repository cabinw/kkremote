import AppKit
import CoreGraphics
import Metal
import QuartzCore

// Shared standalone probe plumbing for overlay-test v2+ variants.
// No video capture, networking, remote input injection, or Accessibility permission.

struct WindowInfo {
    let id: CGWindowID
    let pid: pid_t
    let owner: String
    let title: String
    let frame: CGRect
    let layer: Int

    static func visible() -> [WindowInfo] {
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let id = row[kCGWindowNumber as String] as? UInt32,
                  let pid = row[kCGWindowOwnerPID as String] as? Int32,
                  let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  (row[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { return nil }
            return WindowInfo(id: id, pid: pid,
                owner: row[kCGWindowOwnerName as String] as? String ?? "",
                title: row[kCGWindowName as String] as? String ?? "",
                frame: frame, layer: row[kCGWindowLayer as String] as? Int ?? 0)
        }
    }

    var appKitFrame: NSRect {
        // CG coordinates originate at the top-left of the primary display.
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        return NSRect(x: frame.minX, y: primaryTop - frame.maxY, width: frame.width, height: frame.height)
    }
}

enum OverlayStyle: Int, CaseIterable {
    case subtle, standard, vivid
    init?(cliValue: String) {
        switch cliValue.lowercased() {
        case "subtle", "柔和": self = .subtle
        case "standard", "标准": self = .standard
        case "vivid", "鲜明": self = .vivid
        default: return nil
        }
    }
    var title: String { ["柔和", "标准", "鲜明"][rawValue] }
    var intensity: Double { [0.75, 1.0, 1.32][rawValue] }
}

enum AppearanceMode: String {
    case auto, light, dark
}

enum BannerMode {
    case standard
    case smartCollapsible(startCollapsed: Bool, autoCollapseDelay: TimeInterval)
}

enum BannerDockEdge: String, CaseIterable {
    case top, bottom, left, right

    var title: String {
        switch self {
        case .top: return "顶栏融合"
        case .bottom: return "底边停靠"
        case .left: return "左侧边停靠"
        case .right: return "右侧边停靠"
        }
    }
}

struct ProbeEffect {
    let versionTag: String
    let subtitleTag: String
    let shaderFragmentSource: String
    var bannerMode: BannerMode = .standard
    var outerPadding: CGFloat = 0
    var overlayBelowTarget: Bool = false
    var supportsFourEdgeDock: Bool = false
    var initialDockEdge: BannerDockEdge = .bottom
    var initialDockRatio: CGFloat = 0.5
    var makeUnderlayView: (() -> NSView)? = nil
    var layoutUnderlayView: ((NSView, CGRect, CGFloat, Bool, Bool, Double) -> Void)? = nil
    var updateUniforms: ((inout OverlayUniforms, CGRect, TimeInterval, CGFloat) -> Void)? = nil
    var setupExtraMenuItems: ((NSMenu, Probe) -> Void)? = nil
}

// Byte-for-byte aligned with Metal `Uniforms` (stride 96).
struct OverlayUniforms {
    var size: SIMD2<Float>          // offset 0
    var scale: Float                // offset 8
    var time: Float                 // offset 12
    var radius: Float               // offset 16
    var intensity: Float            // offset 20
    var dark: Float                 // offset 24
    var presence: Float             // offset 28
    var cursor: SIMD2<Float>        // offset 32
    var clickOrigin: SIMD2<Float>   // offset 40
    var clickAge: Float             // offset 48
    var activity: Float             // offset 52
    var bannerFold: Float           // offset 56 (0 = collapsed, 1 = expanded)
    var param0: Float               // offset 60
    var bannerRect: SIMD4<Float>    // offset 64 (x, y_topLeft, w, h)
    var custom: SIMD4<Float>        // offset 80
}

let sharedMetalPreamble = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 size;
    float scale;
    float time;
    float radius;
    float intensity;
    float dark;
    float presence;
    float2 cursor;
    float2 clickOrigin;
    float clickAge;
    float activity;
    float bannerFold;
    float param0;
    float4 bannerRect;
    float4 custom;
};

struct VOut { float4 position [[position]]; };

vertex VOut overlayVertex(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    VOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

static float3 linearRamp3(float s, float3 c0, float3 c1, float3 c2) {
    float u = clamp(s, 0.0, 1.0) * 2.0;
    float3 a = mix(c0, c1, smoothstep(0.0, 1.0, u));
    return mix(a, c2, smoothstep(1.0, 2.0, u));
}

static float3 linearRamp5(float s, float3 c0, float3 c1, float3 c2, float3 c3, float3 c4) {
    float u = clamp(s, 0.0, 1.0) * 4.0;
    float3 a = mix(c0, c1, smoothstep(0.0, 1.0, u));
    a = mix(a, c2, smoothstep(1.0, 2.0, u));
    a = mix(a, c3, smoothstep(2.0, 3.0, u));
    return mix(a, c4, smoothstep(3.0, 4.0, u));
}

// Positive inside an Apple-continuous squircle rounded rectangle (macOS 26 R=22, n=2.85).
static float insideDistance(float2 p, float2 size, float r) {
    float2 h = size * 0.5;
    float R = clamp(r, 0.0, min(h.x, h.y));
    float2 q = abs(p - h) - (h - R);
    if (R <= 0.001) {
        return -max(q.x, q.y);
    }
    if (q.x > 0.0 && q.y > 0.0) {
        const float n = 2.85;
        float2 t = q / R;
        float F = pow(t.x, n) + pow(t.y, n);
        float s = pow(F, 1.0 / n);
        float gx = pow(t.x, n - 1.0);
        float gy = pow(t.y, n - 1.0);
        float grad = length(float2(gx, gy)) * pow(max(F, 1e-6), (1.0 - n) / n);
        return R * (1.0 - s) / max(grad, 0.5);
    }
    return R - max(q.x, q.y);
}

static float smoothEdgeProximity(float2 p, float2 size, float width) {
    float dx = max(min(p.x, size.x - p.x), 0.0);
    float dy = max(min(p.y, size.y - p.y), 0.0);
    float ex = exp(-dx / max(width, 1.0));
    float ey = exp(-dy / max(width, 1.0));
    return 1.0 - (1.0 - ex) * (1.0 - ey);
}

// Smooth aspect-balanced angle [-pi, pi] around the window perimeter.
static float perimeterAngle(float2 p, float2 size) {
    float2 d = p - size * 0.5;
    float wx = pow(max(size.x, 1.0), 0.55);
    float wy = pow(max(size.y, 1.0), 0.55);
    return atan2(d.y / wy, d.x / wx);
}

// Signed distance outside a rounded box (negative inside, positive outside).
static float roundedBoxSDF(float2 p, float2 center, float2 halfSize, float r) {
    float2 q = abs(p - center) - (halfSize - r);
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

static float wrapAngleDelta(float a, float b) {
    float d = fmod(a - b + M_PI_F * 3.0, M_PI_F * 2.0) - M_PI_F;
    return abs(d);
}
"""

final class OverlayPanel: NSPanel {
    var constrainToScreen = true
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        constrainToScreen ? super.constrainFrameRect(frameRect, to: screen) : frameRect
    }

    init(interactive: Bool) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        ignoresMouseEvents = !interactive
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        level = .normal
        animationBehavior = .none
    }
}

final class OverlayCanvas: NSView {
    var style: OverlayStyle = .standard
    var prefersDark = false
    var cornerRadius: CGFloat = 22
    var reduceMotion = false
    var uniformUpdater: ((inout OverlayUniforms, CGRect, TimeInterval, CGFloat) -> Void)?
    private let metalLayer = CAMetalLayer()
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var timer: Timer?
    private var active = false
    private var lastFrameTime = CACurrentMediaTime()
    private var shownAt = CACurrentMediaTime()
    private var animTime: Double = 0
    private var intensity: Float = 1
    private var dark: Float = 0

    init?(prefersDark: Bool, fragmentSource: String) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            log("METAL no device")
            return nil
        }
        let fullSource = sharedMetalPreamble + "\n" + fragmentSource
        do {
            let library = try device.makeLibrary(source: fullSource, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "overlayVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "overlayFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            log("METAL shader setup failed: \(error)")
            return nil
        }
        self.device = device
        commandQueue = queue
        self.prefersDark = prefersDark
        dark = prefersDark ? 1 : 0
        super.init(frame: .zero)
        wantsLayer = true
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.isOpaque = false
        metalLayer.framebufferOnly = true
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer = metalLayer
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func makeBackingLayer() -> CALayer { metalLayer }
    override var wantsUpdateLayer: Bool { false }

    override func layout() {
        super.layout()
        syncDrawableSize()
        if active { renderFrame() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncDrawableSize()
    }

    private func syncDrawableSize() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        let w = max(1, round(bounds.width * scale))
        let h = max(1, round(bounds.height * scale))
        if metalLayer.drawableSize.width != w || metalLayer.drawableSize.height != h {
            metalLayer.drawableSize = CGSize(width: w, height: h)
        }
    }

    func setActive(_ isActive: Bool) {
        guard isActive != active else { return }
        active = isActive
        if isActive {
            shownAt = CACurrentMediaTime()
            lastFrameTime = shownAt
            syncDrawableSize()
            renderFrame()
            let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                self?.renderFrame()
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    private func renderFrame() {
        guard active, bounds.width > 0, bounds.height > 0 else { return }
        syncDrawableSize()
        guard let drawable = metalLayer.nextDrawable(),
              let buffer = commandQueue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        let now = CACurrentMediaTime()
        let step = min(0.1, max(0, now - lastFrameTime))
        lastFrameTime = now
        if !reduceMotion { animTime += step }
        let stepF = Float(step)
        intensity += (Float(style.intensity) - intensity) * min(1, stepF * 5)
        dark += ((prefersDark ? 1 : 0) - dark) * min(1, stepF * 3)
        let fadeDuration = reduceMotion ? 0.15 : 0.35
        let fade = Float(min(1, (now - shownAt) / fadeDuration))
        let scale = Float(metalLayer.contentsScale > 0 ? metalLayer.contentsScale : 2)
        var uniforms = OverlayUniforms(
            size: SIMD2(Float(bounds.width), Float(bounds.height)),
            scale: scale,
            time: Float(animTime),
            radius: Float(cornerRadius),
            intensity: intensity,
            dark: dark,
            presence: fade * fade * (3 - 2 * fade),
            cursor: SIMD2(Float(bounds.width * 0.5), Float(bounds.height * 0.5)),
            clickOrigin: SIMD2(Float(bounds.width * 0.5), Float(bounds.height * 0.5)),
            clickAge: 99,
            activity: 0.25,
            bannerFold: 1,
            param0: 0,
            bannerRect: SIMD4(0, 0, 0, 0),
            custom: SIMD4(0, 0, 0, 0))
        uniformUpdater?(&uniforms, window?.frame ?? bounds, step, cornerRadius)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<OverlayUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}

// MARK: - Control bar

final class BannerView: NSView {
    override var allowsVibrancy: Bool { false }
    static let baseSize = NSSize(width: 392, height: 74)
    static let compactBaseSize = NSSize(width: 112, height: 32)

    private var maskedSize = NSSize.zero
    private var lastMaskRadius: CGFloat = -1
    private var customTintColor: NSColor?
    private var dragStartMouse: NSPoint?
    private var dragStartOrigin: NSPoint = .zero
    private var didMoveDuringDrag = false
    private let backdropView = NSVisualEffectView()
    private let tintView = NSView()
    private let spinner = SpinnerMark()
    private let titleField = ControlLabel(labelWithString: "")
    private let subtitleField = ControlLabel(labelWithString: "")
    private let statusLabel = ShimmerLabel(text: "远程控制中")
    private let compactLabel = ControlLabel(labelWithString: "远程控制中")
    private var hoverArea: NSTrackingArea?

    let styleButton = PillButton()
    let pinButton = PillButton()
    let closeButton = PillButton()
    let collapsible: Bool
    var onLayoutMetricsChanged: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    var onBannerClicked: (() -> Void)?
    var onBannerDragBegan: (() -> Void)?
    var onBannerDragMoved: ((NSPoint) -> Void)?
    var onBannerDragEnded: ((NSRect) -> Void)?

    private(set) var foldProgress: CGFloat = 1 {
        didSet {
            if abs(foldProgress - oldValue) > 0.0005 {
                maskedSize = .zero
                needsLayout = true
            }
        }
    }
    var isCollapsedTarget: Bool = false
    var isPinned: Bool = false {
        didSet {
            pinButton.title = isPinned ? "常驻" : "自动"
            pinButton.activeHighlight = isPinned
            pinButton.needsDisplay = true
        }
    }

    var uiScale: CGFloat = 1 {
        didSet {
            if abs(uiScale - oldValue) > 0.001 {
                maskedSize = .zero
                needsLayout = true
            }
        }
    }
    var reduceTransparency = false { didSet { updateTint() } }
    var reduceMotion = false {
        didSet {
            spinner.reduceMotion = reduceMotion
            statusLabel.reduceMotion = reduceMotion
        }
    }

    init(owner: String, subtitle: String, collapsible: Bool, startCollapsed: Bool,
         target: AnyObject, styleAction: Selector, closeAction: Selector, pinAction: Selector?) {
        self.collapsible = collapsible
        self.isCollapsedTarget = startCollapsed
        self.foldProgress = startCollapsed ? 0 : 1
        super.init(frame: NSRect(origin: .zero, size: Self.baseSize))
        wantsLayer = true
        layer?.cornerRadius = 20
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0

        backdropView.material = .hudWindow
        backdropView.blendingMode = .behindWindow
        backdropView.state = .active
        backdropView.appearance = NSAppearance(named: .darkAqua)
        addSubview(backdropView)

        tintView.wantsLayer = true
        tintView.layer = CALayer()
        addSubview(tintView)
        updateTint()

        titleField.stringValue = "\(owner) 工作区"
        titleField.textColor = .white.withAlphaComponent(0.96)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        titleField.cell?.truncatesLastVisibleLine = true

        subtitleField.stringValue = subtitle
        subtitleField.textColor = .white.withAlphaComponent(0.74)
        subtitleField.lineBreakMode = .byTruncatingTail
        subtitleField.maximumNumberOfLines = 1
        subtitleField.cell?.truncatesLastVisibleLine = true

        compactLabel.textColor = NSColor(srgbRed: 0.87, green: 0.87, blue: 0.98, alpha: 0.96)
        compactLabel.lineBreakMode = .byTruncatingTail
        compactLabel.maximumNumberOfLines = 1

        styleButton.isBordered = false
        styleButton.toolTip = "切换柔和、标准、鲜明"
        styleButton.target = target
        styleButton.action = styleAction

        pinButton.isBordered = false
        pinButton.title = "自动"
        pinButton.toolTip = "切换闲置自动折叠 / 常驻展开"
        pinButton.target = target
        pinButton.action = pinAction
        pinButton.isHidden = !collapsible

        closeButton.isBordered = false
        closeButton.title = "结束"
        closeButton.toolTip = "结束遮罩样式测试"
        closeButton.target = target
        closeButton.action = closeAction

        addSubview(spinner)
        addSubview(titleField)
        addSubview(subtitleField)
        addSubview(statusLabel)
        addSubview(compactLabel)
        addSubview(styleButton)
        addSubview(pinButton)
        addSubview(closeButton)
        updateMaterialMask()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func currentLogicalSize(forScale s: CGFloat) -> NSSize {
        let expandedW = (collapsible ? 426 : Self.baseSize.width) * s
        let expandedH = Self.baseSize.height * s
        if !collapsible {
            return NSSize(width: round(expandedW), height: round(expandedH))
        }
        let compactW = Self.compactBaseSize.width * s
        let compactH = Self.compactBaseSize.height * s
        let k = easeFold(foldProgress)
        return NSSize(width: round(compactW + (expandedW - compactW) * k),
                      height: round(compactH + (expandedH - compactH) * k))
    }

    func setFoldProgress(_ value: CGFloat) {
        foldProgress = min(1, max(0, value))
    }

    private func easeFold(_ t: CGFloat) -> CGFloat {
        t * t * (3 - 2 * t)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        hoverArea = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(hoverArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let onButton = [styleButton, pinButton, closeButton].contains { !$0.isHidden && $0.frame.contains(pt) }
        if !onButton && (onBannerDragMoved != nil || onBannerClicked != nil) {
            dragStartMouse = NSEvent.mouseLocation
            dragStartOrigin = window?.frame.origin ?? .zero
            didMoveDuringDrag = false
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startMouse = dragStartMouse, let onDragMoved = onBannerDragMoved else {
            super.mouseDragged(with: event)
            return
        }
        let nowMouse = NSEvent.mouseLocation
        let dx = nowMouse.x - startMouse.x
        let dy = nowMouse.y - startMouse.y
        if !didMoveDuringDrag && hypot(dx, dy) > 3 {
            didMoveDuringDrag = true
            onBannerDragBegan?()
        }
        if didMoveDuringDrag {
            onDragMoved(NSPoint(x: dragStartOrigin.x + dx, y: dragStartOrigin.y + dy))
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStartMouse != nil else {
            super.mouseUp(with: event)
            return
        }
        let moved = didMoveDuringDrag
        dragStartMouse = nil
        didMoveDuringDrag = false
        if moved {
            if let frame = window?.frame { onBannerDragEnded?(frame) }
        } else {
            onBannerClicked?()
        }
    }

    func applySemanticAppearance(subtitle: String? = nil, status: String? = nil,
                                 compact: String? = nil, accentColor: NSColor? = nil,
                                 tintColor: NSColor? = nil) {
        if let subtitle { subtitleField.stringValue = subtitle }
        if let status { statusLabel.text = status }
        if let compact { compactLabel.stringValue = compact }
        if let accentColor {
            spinner.accentColor = accentColor
            spinner.needsDisplay = true
            statusLabel.baseColor = accentColor
            statusLabel.needsDisplay = true
            compactLabel.textColor = accentColor.blended(withFraction: 0.45, of: .white) ?? accentColor
        }
        customTintColor = tintColor
        updateTint()
        needsLayout = true
    }

    private func updateTint() {
        let alpha: CGFloat = reduceTransparency ? 0.96 : 0.85
        let base = customTintColor ?? NSColor(srgbRed: 0.145, green: 0.148, blue: 0.165, alpha: 1)
        tintView.layer?.backgroundColor = base.withAlphaComponent(alpha).cgColor
    }

    override func layout() {
        super.layout()
        let s = uiScale
        let w = bounds.width
        let h = bounds.height
        let k = collapsible ? easeFold(foldProgress) : 1
        backdropView.frame = bounds
        tintView.frame = bounds

        let cornerR = min((16 + 4 * k) * s, min(w, h) / 2)
        layer?.cornerRadius = cornerR

        let padX = (12 + 4 * k) * s
        let spinnerSize = (16 + 8 * k) * s
        spinner.frame = NSRect(x: padX, y: (h - spinnerSize) / 2, width: spinnerSize, height: spinnerSize)

        let buttonH = 38 * s
        let buttonY = (h - buttonH) / 2
        let closeW = 46 * s
        let pinW = collapsible ? 44 * s : 0
        let styleW = 72 * s
        let gap = 6 * s
        let closeX = w - padX - closeW
        let pinX = collapsible ? closeX - gap - pinW : closeX
        let styleX = (collapsible ? pinX : closeX) - gap - styleW

        closeButton.frame = NSRect(x: closeX, y: buttonY, width: closeW, height: buttonH)
        pinButton.frame = NSRect(x: pinX, y: buttonY, width: pinW, height: buttonH)
        styleButton.frame = NSRect(x: styleX, y: buttonY, width: styleW, height: buttonH)
        closeButton.uiScale = s
        pinButton.uiScale = s
        styleButton.uiScale = s

        let expandedAlpha = max(0, (k - 0.35) / 0.65)
        let compactAlpha = max(0, 1 - k * 2.2)

        closeButton.alphaValue = expandedAlpha
        pinButton.alphaValue = collapsible ? expandedAlpha : 0
        styleButton.alphaValue = expandedAlpha
        closeButton.isHidden = expandedAlpha <= 0.02
        pinButton.isHidden = !collapsible || expandedAlpha <= 0.02
        styleButton.isHidden = expandedAlpha <= 0.02

        titleField.font = .systemFont(ofSize: 13.5 * s, weight: .medium)
        subtitleField.font = .systemFont(ofSize: 10.5 * s, weight: .medium)
        statusLabel.uiScale = s

        let textX = round(padX + spinnerSize + 10 * s)
        let textW = max(40, round(styleX - 10 * s) - textX)
        let h1 = ceil(titleField.fittingSize.height)
        let h2 = ceil(subtitleField.fittingSize.height)
        let h3 = ceil(statusLabel.intrinsicContentSize.height)
        let lineGap = round(2.0 * s)
        let totalH = h1 + h2 + h3 + lineGap * 2
        let y3 = round((h - totalH) / 2)
        let y2 = y3 + h3 + lineGap
        let y1 = y2 + h2 + lineGap
        statusLabel.frame = NSRect(x: textX, y: y3, width: textW, height: h3)
        subtitleField.frame = NSRect(x: textX, y: y2, width: textW, height: h2)
        titleField.frame = NSRect(x: textX, y: y1, width: textW, height: h1)

        titleField.alphaValue = expandedAlpha
        subtitleField.alphaValue = expandedAlpha
        statusLabel.alphaValue = expandedAlpha
        titleField.isHidden = expandedAlpha <= 0.02
        subtitleField.isHidden = expandedAlpha <= 0.02
        statusLabel.isHidden = expandedAlpha <= 0.02

        compactLabel.font = .systemFont(ofSize: 11.5 * s, weight: .semibold)
        let ch = ceil(compactLabel.fittingSize.height)
        let cw = ceil(compactLabel.fittingSize.width)
        let compactX = round(padX + spinnerSize + 6 * s)
        compactLabel.frame = NSRect(x: compactX, y: round((h - ch) / 2), width: min(cw + 2, max(40, round(w - compactX - 8 * s))), height: ch)
        compactLabel.alphaValue = compactAlpha
        compactLabel.isHidden = !collapsible || compactAlpha <= 0.02

        updateMaterialMask(radius: cornerR)
        onLayoutMetricsChanged?()
    }

    func tickAnimation() {
        spinner.needsDisplay = true
        statusLabel.needsDisplay = true
    }

    private func updateMaterialMask(radius: CGFloat? = nil) {
        let targetR = radius ?? min(20 * uiScale, min(bounds.width, bounds.height) / 2)
        guard bounds.width > 0, bounds.height > 0,
              (maskedSize != bounds.size || abs(lastMaskRadius - targetR) > 0.25) else { return }
        maskedSize = bounds.size
        lastMaskRadius = targetR
        let size = bounds.size
        backdropView.maskImage = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            NSBezierPath(roundedRect: rect, xRadius: targetR, yRadius: targetR).fill()
            return true
        }
        window?.invalidateShadow()
    }
}

final class ControlLabel: NSTextField {
    override var allowsVibrancy: Bool { false }
}

final class PillButton: NSButton {
    override var allowsVibrancy: Bool { false }
    var uiScale: CGFloat = 1 { didSet { needsDisplay = true } }
    var activeHighlight = false
    private var hovering = false
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        hoverArea = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(hoverArea!)
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let radius = min(11 * uiScale, min(bounds.width, bounds.height) / 2)
        let path = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        let baseAlpha: CGFloat = activeHighlight ? 0.19 : 0.095
        NSColor.white.withAlphaComponent(isHighlighted ? 0.05 : hovering ? max(0.22, baseAlpha + 0.06) : baseAlpha).setFill()
        path.fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12 * uiScale, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.95)
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: round((bounds.width - size.width) / 2),
                                            y: round((bounds.height - size.height) / 2)), withAttributes: attributes)
    }
}

final class SpinnerMark: NSView {
    override var allowsVibrancy: Bool { false }
    var reduceMotion = false
    var accentColor: NSColor = .white
    private let epoch = CACurrentMediaTime()
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let s = min(bounds.width, bounds.height) / 24.0
        let count = 8
        let head = reduceMotion ? 0.0 : ((CACurrentMediaTime() - epoch) * 1.15).truncatingRemainder(dividingBy: 1) * Double(count)
        ctx.translateBy(x: bounds.midX, y: bounds.midY)
        ctx.scaleBy(x: s, y: s)
        for i in 0..<count {
            var lag = head - Double(i)
            if lag < 0 { lag += Double(count) }
            let alpha = reduceMotion ? 0.65 : (0.20 + 0.80 * pow(1 - lag / Double(count), 2.2))
            ctx.saveGState()
            ctx.rotate(by: -CGFloat(i) * .pi * 2 / CGFloat(count))
            ctx.setFillColor(accentColor.withAlphaComponent(alpha).cgColor)
            ctx.addPath(CGPath(roundedRect: CGRect(x: -1.0, y: 5.8, width: 2.0, height: 4.1),
                               cornerWidth: 1.0, cornerHeight: 1.0, transform: nil))
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.setFillColor(accentColor.cgColor)
        ctx.move(to: CGPoint(x: -1.6, y: 3.6))
        ctx.addLine(to: CGPoint(x: -1.6, y: -4.8))
        ctx.addLine(to: CGPoint(x: 0.7, y: -2.7))
        ctx.addLine(to: CGPoint(x: 4.1, y: -2.7))
        ctx.closePath()
        ctx.fillPath()
    }
}

final class ShimmerLabel: NSView {
    override var allowsVibrancy: Bool { false }
    var uiScale: CGFloat = 1 { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var reduceMotion = false
    var baseColor: NSColor?
    var text: String {
        didSet { invalidateIntrinsicContentSize(); needsDisplay = true }
    }
    private let epoch = CACurrentMediaTime()
    private static let band: CGImage? = {
        let width = 64
        guard let ctx = CGContext(data: nil, width: width, height: 1, bitsPerComponent: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        for x in 0..<width {
            ctx.setFillColor(gray: pow(sin(Double(x) / Double(width - 1) * .pi), 1.6), alpha: 1)
            ctx.fill(CGRect(x: x, y: 0, width: 1, height: 1))
        }
        return ctx.makeImage()
    }()

    init(text: String) {
        self.text = text
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize {
        let font = NSFont.systemFont(ofSize: 11 * uiScale, weight: .semibold)
        let size = (text as NSString).size(withAttributes: [.font: font])
        return NSSize(width: ceil(size.width + 2 * uiScale), height: ceil(size.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        let font = NSFont.systemFont(ofSize: 11 * uiScale, weight: .semibold)
        let fg = baseColor ?? NSColor(srgbRed: 0.83, green: 0.82, blue: 0.96, alpha: 0.92)
        let base = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: fg])
        let size = base.size()
        let inset = round(2 * uiScale)
        let origin = NSPoint(x: inset, y: round((bounds.height - size.height) / 2))
        base.draw(at: origin)
        guard !reduceMotion else { return }
        let cycle = 3.2, sweep = 1.6
        let u = (CACurrentMediaTime() - epoch).truncatingRemainder(dividingBy: cycle) / sweep
        guard u < 1, let band = Self.band, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let eased = CGFloat(u * u * (3 - 2 * u))
        let bandWidth = 48 * uiScale
        let x = inset - bandWidth + (size.width + bandWidth) * eased
        ctx.saveGState()
        ctx.clip(to: CGRect(x: x, y: 0, width: bandWidth, height: bounds.height), mask: band)
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white]).draw(at: origin)
        ctx.restoreGState()
    }
}

// MARK: - Shared Probe Controller

final class Probe: NSObject, NSApplicationDelegate {
    let effect: ProbeEffect
    let target: WindowInfo
    let duration: TimeInterval
    var appearanceMode: AppearanceMode
    let cornerRadiusOverride: CGFloat?
    let banner = OverlayPanel(interactive: true)
    let overlay = OverlayPanel(interactive: false)
    let overlayRoot = NSView()
    var underlayView: NSView?
    var canvas: OverlayCanvas!
    var bannerView: BannerView!
    let panelOnly = CommandLine.arguments.contains("--panel-only")
    var statusItem: NSStatusItem!
    var pollTimer: Timer?
    var uiAnimTimer: Timer?
    var appearanceItems: [AppearanceMode: NSMenuItem] = [:]
    var styleItems: [OverlayStyle: NSMenuItem] = [:]
    var deadline: Date
    var lastFrame: CGRect = .null
    var lastOrder: CGWindowID?
    var lastVisibility = ""
    var lastDark: Bool?
    var suspended = false
    var style: OverlayStyle = .standard

    private var bannerHovered = false
    private var lastInteractionTime = CACurrentMediaTime()
    private var lastTickTime = CACurrentMediaTime()
    var dockEdge: BannerDockEdge
    var dockRatio: CGFloat
    var isDraggingBanner = false
    var snapCandidateEdge: BannerDockEdge
    var onDockChanged: ((BannerDockEdge) -> Void)?

    init(effect: ProbeEffect, target: WindowInfo, duration: TimeInterval,
         appearanceMode: AppearanceMode, style: OverlayStyle, cornerRadius: CGFloat?) {
        self.effect = effect
        self.target = target
        self.duration = duration
        self.appearanceMode = appearanceMode
        self.style = style
        self.dockEdge = effect.initialDockEdge
        self.snapCandidateEdge = effect.initialDockEdge
        self.dockRatio = min(1, max(0, effect.initialDockRatio))
        cornerRadiusOverride = cornerRadius
        deadline = Date().addingTimeInterval(duration)
        super.init()
    }

    var prefersDark: Bool {
        switch appearanceMode {
        case .light: return false
        case .dark: return true
        case .auto: return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let canvas = OverlayCanvas(prefersDark: prefersDark, fragmentSource: effect.shaderFragmentSource) else {
            fputs("Metal is unavailable; the overlay cannot render.\n", stderr)
            exit(1)
        }
        canvas.style = style
        self.canvas = canvas
        overlayRoot.wantsLayer = true
        overlayRoot.autoresizingMask = [.width, .height]
        if let makeUnderlay = effect.makeUnderlayView {
            let underlay = makeUnderlay()
            underlay.autoresizingMask = [.width, .height]
            overlayRoot.addSubview(underlay)
            underlayView = underlay
        }
        canvas.autoresizingMask = [.width, .height]
        overlayRoot.addSubview(canvas)
        overlay.constrainToScreen = effect.outerPadding <= 0
        overlay.title = "KKRemote \(effect.versionTag)"
        overlay.contentView = overlayRoot

        let startCollapsed: Bool
        let isCollapsible: Bool
        if case let .smartCollapsible(startFolded, _) = effect.bannerMode {
            isCollapsible = true
            startCollapsed = startFolded
            if startFolded {
                lastInteractionTime = CACurrentMediaTime() - 20
            }
        } else {
            isCollapsible = false
            startCollapsed = false
        }

        banner.title = "KKRemote \(effect.versionTag)"
        bannerView = BannerView(owner: target.owner, subtitle: effect.subtitleTag,
                                collapsible: isCollapsible, startCollapsed: startCollapsed,
                                target: self, styleAction: #selector(cycleStyle),
                                closeAction: #selector(quitFromUI), pinAction: #selector(togglePin))
        bannerView.styleButton.title = "\(style.title)样式"
        bannerView.onHoverChanged = { [weak self] hovering in
            guard let self else { return }
            self.bannerHovered = hovering
            self.lastInteractionTime = CACurrentMediaTime()
            if hovering {
                self.bannerView.isCollapsedTarget = false
            }
        }
        if effect.supportsFourEdgeDock {
            bannerView.onBannerDragBegan = { [weak self] in
                guard let self else { return }
                self.isDraggingBanner = true
                self.lastInteractionTime = CACurrentMediaTime()
            }
            bannerView.onBannerDragMoved = { [weak self] rawOrigin in
                guard let self, !self.lastFrame.isNull else { return }
                let rect = self.lastFrame
                let size = self.banner.frame.size
                let minX = rect.minX + 8
                let maxX = max(minX, rect.maxX - size.width - 8)
                let minY = rect.minY + 8
                let maxY = max(minY, rect.maxY - size.height - 8)
                let clamped = NSPoint(x: min(maxX, max(minX, rawOrigin.x)),
                                      y: min(maxY, max(minY, rawOrigin.y)))
                self.banner.setFrameOrigin(clamped)
                let center = NSPoint(x: clamped.x + size.width * 0.5, y: clamped.y + size.height * 0.5)
                self.snapCandidateEdge = self.nearestDock(forCenter: center, size: size, in: rect).0
            }
            bannerView.onBannerDragEnded = { [weak self] finalFrame in
                guard let self else { return }
                self.isDraggingBanner = false
                self.lastInteractionTime = CACurrentMediaTime()
                guard !self.lastFrame.isNull else { return }
                let center = NSPoint(x: finalFrame.midX, y: finalFrame.midY)
                let (edge, ratio) = self.nearestDock(forCenter: center, size: finalFrame.size, in: self.lastFrame)
                self.dockEdge = edge
                self.snapCandidateEdge = edge
                self.dockRatio = ratio
                let targetFrame = self.computedBannerFrame(within: self.lastFrame)
                let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = reduce ? 0.08 : 0.24
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    self.banner.animator().setFrame(targetFrame, display: true)
                }
                self.onDockChanged?(edge)
                log("DOCK edge=\(edge.rawValue) ratio=\(String(format: "%.2f", ratio))")
            }
        }
        banner.contentView = bannerView
        banner.hasShadow = true

        canvas.uniformUpdater = { [weak self] uniforms, overlayWindowFrame, step, cornerRadius in
            guard let self else { return }
            if self.effect.outerPadding > 0, !self.lastFrame.isNull {
                let targetRect = self.lastFrame
                let padLeft = Float(targetRect.minX - overlayWindowFrame.minX)
                let padTop = Float(overlayWindowFrame.maxY - targetRect.maxY)
                uniforms.param0 = Float(self.effect.outerPadding)
                uniforms.custom = SIMD4(padLeft, padTop, Float(targetRect.width), Float(targetRect.height))
                uniforms.cursor = SIMD2(padLeft, padTop)
                uniforms.clickOrigin = SIMD2(Float(targetRect.width), Float(targetRect.height))
                uniforms.clickAge = Float(self.effect.outerPadding)
            }
            self.effect.updateUniforms?(&uniforms, overlayWindowFrame, step, cornerRadius)
            if self.banner.isVisible {
                let b = self.banner.frame
                // Convert banner AppKit coords to overlay top-left local points.
                let bx = Float(b.minX - overlayWindowFrame.minX)
                let by = Float(overlayWindowFrame.maxY - b.maxY)
                uniforms.bannerRect = SIMD4(bx, by, Float(b.width), Float(b.height))
                uniforms.bannerFold = Float(self.bannerView.foldProgress)
            }
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "▣ \(effect.versionTag)"
        let menu = NSMenu()
        menu.addItem(withTitle: "方案：\(effect.versionTag) · \(target.owner) (\(target.id))", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "仅样式预览；无远程连接", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        for candidate in OverlayStyle.allCases {
            let item = NSMenuItem(title: "\(candidate.title)强度", action: #selector(selectStyle(_:)), keyEquivalent: "")
            item.tag = candidate.rawValue
            item.target = self
            styleItems[candidate] = item
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let modes: [(AppearanceMode, String)] = [(.auto, "外观：跟随系统"), (.light, "外观：浅色窗口"), (.dark, "外观：深色窗口")]
        for (idx, pair) in modes.enumerated() {
            let item = NSMenuItem(title: pair.1, action: #selector(selectAppearance(_:)), keyEquivalent: "")
            item.tag = idx
            item.target = self
            appearanceItems[pair.0] = item
            menu.addItem(item)
        }
        effect.setupExtraMenuItems?(menu, self)
        menu.addItem(.separator())
        let toggle = NSMenuItem(title: "隐藏 / 显示遮罩", action: #selector(toggleVisibility), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(withTitle: "\(Int(duration / 60)) 分钟后自动退出", action: nil, keyEquivalent: "")
        let exit = NSMenuItem(title: "结束测试", action: #selector(quitFromUI), keyEquivalent: "q")
        exit.target = self
        menu.addItem(exit)
        statusItem.menu = menu
        syncMenuChecks()

        log("START variant=\(effect.versionTag) window=\(target.id) owner=\(target.owner) pid=\(target.pid) duration=\(Int(duration))s appearance=\(appearanceMode.rawValue)")
        pollTimer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.update() }
        RunLoop.main.add(pollTimer!, forMode: .common)
        update()
    }

    func cornerRadius(for rect: NSRect) -> CGFloat {
        if let cornerRadiusOverride { return cornerRadiusOverride }
        if NSScreen.screens.contains(where: { $0.frame == rect }) { return 0 }
        return ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 ? 22 : 12
    }

    private func setUIAnimationRunning(_ running: Bool) {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !running {
            uiAnimTimer?.invalidate()
            uiAnimTimer = nil
            return
        }
        if reduce && !bannerView.collapsible {
            uiAnimTimer?.invalidate()
            uiAnimTimer = nil
            bannerView.tickAnimation()
            return
        }
        guard uiAnimTimer == nil else { return }
        lastTickTime = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            self?.tickUI()
        }
        RunLoop.main.add(t, forMode: .common)
        uiAnimTimer = t
    }

    private func tickUI() {
        let now = CACurrentMediaTime()
        let dt = min(0.1, max(0, now - lastTickTime))
        lastTickTime = now
        bannerView.tickAnimation()

        if case let .smartCollapsible(_, autoCollapseDelay) = effect.bannerMode, !lastFrame.isNull, !isDraggingBanner {
            let shouldCollapse = !bannerHovered && !bannerView.isPinned && (now - lastInteractionTime >= autoCollapseDelay)
            if shouldCollapse != bannerView.isCollapsedTarget {
                bannerView.isCollapsedTarget = shouldCollapse
                log("BANNER state=\(shouldCollapse ? "collapsed" : "expanded")")
            }
            let targetFold: CGFloat = bannerView.isCollapsedTarget ? 0 : 1
            let diff = targetFold - bannerView.foldProgress
            if abs(diff) > 0.001 {
                let speed: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 16 : 6.2
                let step = diff * min(1, CGFloat(dt) * speed)
                bannerView.setFoldProgress(abs(diff) < 0.01 ? targetFold : bannerView.foldProgress + step)
                positionBanner(within: lastFrame, animated: false)
            }
        }
    }

    private func computedBannerFrame(within rect: NSRect) -> NSRect {
        let scale = min(1.0, (rect.width - 32) / BannerView.baseSize.width)
        bannerView.uiScale = scale
        let panelSize = bannerView.currentLogicalSize(forScale: scale)
        let foldOffset = bannerView.collapsible ? bannerView.foldProgress : 1
        if !effect.supportsFourEdgeDock {
            // Compact pill settles nicely lower (closer to bottom inset) so it stays extra unobtrusive.
            let minMargin: CGFloat = 14
            let expandedY = rect.minY + 18 + BannerView.baseSize.height * scale
            let collapsedY = rect.minY + minMargin
            let targetY = min(collapsedY + (expandedY - collapsedY) * foldOffset, rect.maxY - panelSize.height - 12)
            return NSRect(x: round(rect.midX - panelSize.width / 2), y: round(targetY),
                          width: panelSize.width, height: panelSize.height)
        }
        switch dockEdge {
        case .top:
            // Fuses neatly with macOS titlebar vertical zone (keeps clear of traffic lights when collapsed).
            let minXSafe = rect.minX + 86 - 74 * foldOffset
            let maxXSafe = rect.maxX - panelSize.width - 14
            let x = round(minXSafe + max(0, maxXSafe - minXSafe) * dockRatio)
            let y = round(rect.maxY - panelSize.height - 10)
            return NSRect(x: x, y: y, width: panelSize.width, height: panelSize.height)
        case .bottom:
            let minXSafe = rect.minX + 14
            let maxXSafe = rect.maxX - panelSize.width - 14
            let x = round(minXSafe + max(0, maxXSafe - minXSafe) * dockRatio)
            let y = round(rect.minY + 12)
            return NSRect(x: x, y: y, width: panelSize.width, height: panelSize.height)
        case .left:
            let x = round(rect.minX + 12)
            let minYSafe = rect.minY + 14
            let maxYSafe = max(minYSafe, rect.maxY - panelSize.height - 54)
            let y = round(minYSafe + (maxYSafe - minYSafe) * dockRatio)
            return NSRect(x: x, y: y, width: panelSize.width, height: panelSize.height)
        case .right:
            let x = round(max(rect.minX + 12, rect.maxX - panelSize.width - 12))
            let minYSafe = rect.minY + 14
            let maxYSafe = max(minYSafe, rect.maxY - panelSize.height - 54)
            let y = round(minYSafe + (maxYSafe - minYSafe) * dockRatio)
            return NSRect(x: x, y: y, width: panelSize.width, height: panelSize.height)
        }
    }

    private func nearestDock(forCenter center: NSPoint, size: NSSize, in rect: NSRect) -> (BannerDockEdge, CGFloat) {
        let dTop = max(0, rect.maxY - center.y)
        let dBottom = max(0, center.y - rect.minY)
        let dLeft = max(0, center.x - rect.minX)
        let dRight = max(0, rect.maxX - center.x)
        let edge: BannerDockEdge
        let m = min(min(dTop, dBottom), min(dLeft, dRight))
        if m == dTop { edge = .top }
        else if m == dBottom { edge = .bottom }
        else if m == dLeft { edge = .left }
        else { edge = .right }

        let ratio: CGFloat
        switch edge {
        case .top, .bottom:
            let span = max(1, rect.width - size.width - 100)
            ratio = min(1, max(0, (center.x - size.width * 0.5 - (rect.minX + (edge == .top ? 86 : 14))) / span))
        case .left, .right:
            let span = max(1, rect.height - size.height - 68)
            ratio = min(1, max(0, (center.y - size.height * 0.5 - (rect.minY + 14)) / span))
        }
        return (edge, ratio)
    }

    func setDockEdge(_ edge: BannerDockEdge, ratio: CGFloat? = nil) {
        dockEdge = edge
        snapCandidateEdge = edge
        if let ratio { dockRatio = min(1, max(0, ratio)) }
        lastInteractionTime = CACurrentMediaTime()
        if !lastFrame.isNull {
            let targetFrame = computedBannerFrame(within: lastFrame)
            let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = reduce ? 0.08 : 0.24
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                banner.animator().setFrame(targetFrame, display: true)
            }
        }
        onDockChanged?(edge)
        log("DOCK edge=\(edge.rawValue)")
    }

    private func positionBanner(within rect: NSRect, animated: Bool) {
        let targetFrame = computedBannerFrame(within: rect)
        if animated {
            banner.setFrame(targetFrame, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                banner.animator().setFrame(targetFrame, display: true)
            }
        }
        bannerView.needsLayout = true
        bannerView.layoutSubtreeIfNeeded()
    }

    func setBannerPinned(_ pinned: Bool) {
        bannerView.isPinned = pinned
        lastInteractionTime = CACurrentMediaTime()
        if pinned { bannerView.isCollapsedTarget = false }
    }

    func forceBannerFolded(_ folded: Bool) {
        bannerView.isPinned = !folded
        bannerView.isCollapsedTarget = folded
        bannerView.setFoldProgress(folded ? 0 : 1)
        lastInteractionTime = folded ? CACurrentMediaTime() - 20 : CACurrentMediaTime()
        if !lastFrame.isNull { positionBanner(within: lastFrame, animated: true) }
    }

    @objc func togglePin() {
        setBannerPinned(!bannerView.isPinned)
        log("BANNER pinned=\(bannerView.isPinned)")
    }

    func update() {
        guard Date() < deadline else { quit("deadline"); return }
        let alive = (kill(target.pid, 0) == 0) || (errno != ESRCH)
        guard alive else { quit("target-terminated"); return }
        let windows = WindowInfo.visible()
        guard let index = windows.firstIndex(where: { $0.id == target.id && $0.pid == target.pid }) else {
            hide("target-not-visible")
            return
        }
        let current = windows[index]
        guard !suspended, current.frame.width >= 300, current.frame.height >= 150 else {
            hide("hidden-or-too-small")
            return
        }
        let occluder = windows[..<index].first {
            $0.pid != ProcessInfo.processInfo.processIdentifier && $0.layer == 0 &&
            !($0.owner == "ChatGPT Computer Use" && $0.title == "Software Cursor") &&
            !($0.pid == current.pid && $0.frame.width <= 120 && $0.frame.height <= 44 &&
              current.frame.contains($0.frame) && $0.frame.minY < current.frame.minY + 48) &&
            $0.frame.intersects(current.frame)
        }
        if let occluder {
            hide("occluded-by-\(occluder.owner)-\(occluder.id)-\(occluder.frame)")
            return
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        canvas.reduceMotion = reduceMotion
        bannerView.reduceMotion = reduceMotion
        bannerView.reduceTransparency = reduceTransparency

        let dark = prefersDark
        canvas.prefersDark = dark
        if dark != lastDark {
            log("APPEARANCE \(dark ? "dark" : "light")")
            lastDark = dark
        }
        let appearing = lastVisibility != "visible"
        let rect = current.appKitFrame
        let r = cornerRadius(for: rect)
        let pad = max(0, effect.outerPadding)
        let rawOverlayRect = pad > 0 ? rect.insetBy(dx: -pad, dy: -pad) : rect
        let overlayRect: NSRect
        if pad > 0 {
            let unionScreens = NSScreen.screens
                .filter { $0.frame.intersects(rawOverlayRect) }
                .reduce(NSRect.null) { $0.union($1.frame) }
            let clipped = unionScreens.isNull ? rawOverlayRect : rawOverlayRect.intersection(unionScreens)
            overlayRect = clipped.isNull ? rect : clipped
        } else {
            overlayRect = rect
        }
        if rect != lastFrame || abs(canvas.cornerRadius - r) > 0.01 {
            overlay.setFrame(overlayRect, display: true)
            overlayRoot.frame = NSRect(origin: .zero, size: overlayRect.size)
            canvas.frame = overlayRoot.bounds
            canvas.cornerRadius = r
            if let underlay = underlayView {
                underlay.frame = overlayRoot.bounds
                effect.layoutUnderlayView?(underlay, overlayRoot.bounds, r, dark, reduceTransparency, style.intensity)
            }
            lastFrame = rect
            positionBanner(within: rect, animated: appearing)
            log("FRAME x=\(Int(rect.minX)) y=\(Int(rect.minY)) w=\(Int(rect.width)) h=\(Int(rect.height)) radius=\(Int(r))")
        } else if let underlay = underlayView {
            effect.layoutUnderlayView?(underlay, overlayRoot.bounds, r, dark, reduceTransparency, style.intensity)
        }

        if appearing {
            banner.alphaValue = 0
            let targetY = banner.frame.minY
            if !reduceMotion {
                banner.setFrameOrigin(NSPoint(x: banner.frame.minX, y: max(rect.minY + 6, targetY - 8)))
            }
            if !panelOnly { canvas.setActive(true) }
        }
        let overlayIndex = windows.firstIndex(where: { $0.id == CGWindowID(overlay.windowNumber) })
        let bannerIndex = windows.firstIndex(where: { $0.id == CGWindowID(banner.windowNumber) })
        if panelOnly {
            if !banner.isVisible || bannerIndex == nil || bannerIndex! > index || lastOrder != current.id {
                banner.order(.above, relativeTo: Int(current.id))
                lastOrder = current.id
            }
        } else if effect.overlayBelowTarget {
            let siblingInBetween: Bool = {
                guard let oIdx = overlayIndex, oIdx > index + 1 else { return false }
                return windows[(index + 1)..<oIdx].contains {
                    $0.pid != ProcessInfo.processInfo.processIdentifier && $0.layer == 0 && $0.frame.intersects(current.frame)
                }
            }()
            if !overlay.isVisible || overlayIndex == nil || overlayIndex! <= index || siblingInBetween || lastOrder != current.id {
                overlay.order(.below, relativeTo: Int(current.id))
            }
            if !banner.isVisible || bannerIndex == nil || bannerIndex! > index || lastOrder != current.id {
                banner.order(.above, relativeTo: Int(current.id))
            }
            lastOrder = current.id
        } else if !overlay.isVisible || overlayIndex == nil || overlayIndex! > index || lastOrder != current.id {
            overlay.order(.above, relativeTo: Int(current.id))
            banner.order(.above, relativeTo: overlay.windowNumber)
            lastOrder = current.id
        }
        if appearing {
            let targetFrame = computedBannerFrame(within: rect)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = reduceMotion ? 0.12 : 0.28
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                banner.animator().alphaValue = 1
                banner.animator().setFrameOrigin(targetFrame.origin)
            }
            setUIAnimationRunning(true)
        }
        visibility("visible")
    }

    func hide(_ reason: String) {
        if overlay.isVisible { overlay.orderOut(nil) }
        if banner.isVisible { banner.orderOut(nil) }
        canvas?.setActive(false)
        setUIAnimationRunning(false)
        lastOrder = nil
        visibility(reason)
    }
    func visibility(_ value: String) {
        if value != lastVisibility { log("VISIBILITY \(value)"); lastVisibility = value }
    }
    func syncMenuChecks() {
        for (s, item) in styleItems { item.state = s == style ? .on : .off }
        for (m, item) in appearanceItems { item.state = m == appearanceMode ? .on : .off }
    }
    @objc func cycleStyle() { setStyle(OverlayStyle(rawValue: (style.rawValue + 1) % 3)!) }
    @objc func selectStyle(_ sender: NSMenuItem) { setStyle(OverlayStyle(rawValue: sender.tag)!) }
    func setStyle(_ value: OverlayStyle) {
        style = value
        canvas.style = value
        lastInteractionTime = CACurrentMediaTime()
        bannerView.styleButton.title = "\(value.title)样式"
        bannerView.styleButton.needsDisplay = true
        syncMenuChecks()
        log("STYLE \(value.title) intensity=\(value.intensity)")
    }
    @objc func selectAppearance(_ sender: NSMenuItem) {
        let modes: [AppearanceMode] = [.auto, .light, .dark]
        guard sender.tag >= 0, sender.tag < modes.count else { return }
        appearanceMode = modes[sender.tag]
        syncMenuChecks()
        update()
    }
    @objc func toggleVisibility() { suspended.toggle(); update() }
    @objc func quitFromUI() { quit("user") }
    func quit(_ reason: String = "exit") {
        pollTimer?.invalidate()
        uiAnimTimer?.invalidate()
        canvas?.setActive(false)
        overlay.orderOut(nil)
        banner.orderOut(nil)
        log("STOP reason=\(reason)")
        NSApp.terminate(nil)
    }
}

func log(_ message: String) {
    print("[WindowOverlayProbe] \(message)")
    fflush(stdout)
}

func runProbeMain(effect: ProbeEffect, extraUsage: String = "") {
    let arguments = CommandLine.arguments
    func option(_ name: String) -> String? {
        guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }
    if arguments.contains("--help") {
        let suffix = extraUsage.isEmpty ? "" : " " + extraUsage
        print("""
        WindowOverlayProbe [\(effect.versionTag)] [--list] [--app NAME | --window-id ID] [--frontmost] [--duration SECONDS] [--panel-only]
                           [--style subtle|standard|vivid] [--appearance auto|light|dark] [--corner-radius POINTS]\(suffix)
        """)
        exit(0)
    }
    let windows = WindowInfo.visible().filter { $0.layer == 0 && $0.frame.width > 100 && $0.frame.height > 100 }
    if arguments.contains("--list") {
        for w in windows { print("\(w.id)\t\(w.pid)\t\(w.owner)\t\(w.title)\t\(w.frame)") }
        exit(0)
    }
    let requestedID = option("--window-id").flatMap(UInt32.init)
    if arguments.contains("--window-id") && requestedID == nil {
        fputs("--window-id requires an unsigned integer.\n", stderr)
        exit(1)
    }
    guard let initialStyle = OverlayStyle(cliValue: option("--style") ?? "standard") else {
        fputs("--style must be subtle, standard, or vivid.\n", stderr)
        exit(1)
    }
    guard let appearanceMode = AppearanceMode(rawValue: option("--appearance") ?? "auto") else {
        fputs("--appearance must be auto, light, or dark.\n", stderr)
        exit(1)
    }
    let cornerRadius = option("--corner-radius").flatMap(Double.init).map { CGFloat(max(0, $0)) }
    if arguments.contains("--corner-radius") && cornerRadius == nil {
        fputs("--corner-radius requires a number of points.\n", stderr)
        exit(1)
    }
    let owner = option("--app") ?? "X"
    let candidates = windows.filter { window in
        if let requestedID { return window.id == requestedID }
        return window.owner == owner
    }
    let target: WindowInfo
    if arguments.contains("--frontmost"), let first = candidates.first, requestedID == nil {
        target = first
    } else {
        guard candidates.count == 1, let single = candidates.first else {
            fputs("Expected one visible target, found \(candidates.count). Use --list then --window-id ID (or --frontmost).\n", stderr)
            exit(1)
        }
        target = single
    }
    let duration = option("--duration").flatMap(Double.init) ?? 1800
    guard duration.isFinite && duration > 0 else { fputs("Duration must be positive.\n", stderr); exit(1) }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = Probe(effect: effect, target: target, duration: duration,
                         appearanceMode: appearanceMode, style: initialStyle, cornerRadius: cornerRadius)
    app.delegate = delegate
    app.run()
}
