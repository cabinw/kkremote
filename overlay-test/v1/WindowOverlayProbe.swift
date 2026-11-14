import AppKit
import CoreGraphics
import Metal
import QuartzCore

// Standalone visual probe. No capture, networking, remote input, or AX permission.
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
    var title: String { ["柔和", "标准", "鲜明"][rawValue] }
    var intensity: Double { [0.75, 1.0, 1.32][rawValue] }
}

enum AppearanceMode: String {
    case auto, light, dark
}

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(interactive: Bool) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        ignoresMouseEvents = !interactive
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        // Stay at the target's normal window level, never globally floating.
        level = .normal
        animationBehavior = .none
    }
}

// MARK: - Overlay rendering

// Three layers composited in one fragment pass, all in premultiplied sRGB:
//   1. A clean, subtle pastel tint across the center so text stays effortless to read.
//   2. A cohesive, steadily rotating 5-stop sunset-aurora sweep (periwinkle blue
//      -> violet -> rose -> coral -> warm gold) so color transitions read smoothly
//      and rhythmically without chaotic patches.
//   3. A crisp, clearly legible dot matrix illuminated smoothly along the
//      perimeter aura, rhythmic orbiting light crests, and sparse star twinkles.
private let overlayShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 size;      // points
    float scale;      // pixels per point
    float time;       // seconds
    float radius;     // window corner radius, points
    float intensity;  // style multiplier
    float dark;       // 0 light ... 1 dark
    float presence;   // fade-in 0 ... 1
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

// Smooth 5-stop ramp [0, 1] along harmonizing sunset-aurora hues:
// Periwinkle Blue -> Violet -> Rose Pink -> Coral -> Warm Gold.
static float3 linearRamp5(float s, float3 c0, float3 c1, float3 c2, float3 c3, float3 c4) {
    float u = clamp(s, 0.0, 1.0) * 4.0;
    float3 a = mix(c0, c1, smoothstep(0.0, 1.0, u));
    a = mix(a, c2, smoothstep(1.0, 2.0, u));
    a = mix(a, c3, smoothstep(2.0, 3.0, u));
    return mix(a, c4, smoothstep(3.0, 4.0, u));
}

// High-key luminous pastel arc for airy center & clean transition.
static float3 pastelSpectrum(float s) {
    return linearRamp5(s,
                       float3(0.56, 0.68, 1.00),
                       float3(0.74, 0.54, 1.00),
                       float3(1.00, 0.54, 0.84),
                       float3(1.00, 0.60, 0.46),
                       float3(1.00, 0.84, 0.44));
}

// Vivid glassy glow for the outer perimeter (always at least one channel = 1.0).
static float3 richGlowSpectrum(float s) {
    return linearRamp5(s,
                       float3(0.38, 0.54, 1.00),
                       float3(0.64, 0.36, 1.00),
                       float3(1.00, 0.34, 0.74),
                       float3(1.00, 0.44, 0.26),
                       float3(1.00, 0.78, 0.22));
}

// Dark-mode interior leans clean sapphire -> violet -> orchid -> luminous lavender
// so low-alpha text areas stay crisp and jewel-like over dark backgrounds.
static float3 darkCoolSpectrum(float s) {
    return linearRamp5(s,
                       float3(0.44, 0.62, 1.00),
                       float3(0.66, 0.42, 1.00),
                       float3(1.00, 0.44, 0.80),
                       float3(0.84, 0.52, 0.96),
                       float3(0.72, 0.58, 1.00));
}

// High-alpha dark-mode edge adds luminous rose, coral, and sunlit gold.
static float3 darkEdgeSpectrum(float s) {
    return linearRamp5(s,
                       float3(0.42, 0.58, 1.00),
                       float3(0.68, 0.38, 1.00),
                       float3(1.00, 0.38, 0.78),
                       float3(1.00, 0.48, 0.34),
                       float3(1.00, 0.80, 0.30));
}

// Signed distance inside an Apple-continuous squircle rounded rectangle
// (positive inside), matching macOS 26 window corners cleanly.
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

// Smooth C-infinity edge proximity that never produces 45-degree corner creases.
static float smoothEdgeProximity(float2 p, float2 size, float width) {
    float dx = max(min(p.x, size.x - p.x), 0.0);
    float dy = max(min(p.y, size.y - p.y), 0.0);
    float ex = exp(-dx / width);
    float ey = exp(-dy / width);
    return 1.0 - (1.0 - ex) * (1.0 - ey);
}

fragment float4 overlayFragment(VOut in [[stage_in]], constant Uniforms& U [[buffer(0)]]) {
    float2 size = U.size;
    float2 p = in.position.xy / U.scale;   // points, origin at the top-left
    float t = U.time;
    float d = insideDistance(p, size, U.radius);
    float coverage = clamp(d * U.scale + 0.5, 0.0, 1.0);
    if (coverage <= 0.0 || U.presence <= 0.0) { return float4(0.0); }

    float2 uv = p / size;
    // Scale-normalized coordinates keep liquid folds consistent across any aspect ratio.
    float unit = clamp(min(size.x, size.y), 320.0, 900.0);
    float2 pn = (p - size * 0.5) / unit;
    float2 asp = float2(size.x / size.y, 1.0);

    float edgeWidth = clamp(min(size.x, size.y) * 0.18, 36.0, 125.0);
    float edge = smoothEdgeProximity(p, size, edgeWidth);
    float rim = smoothEdgeProximity(p, size, edgeWidth * 0.38);
    float k = U.intensity;

    // Orderly, unified gradient axis rotating steadily clockwise so colors sweep
    // in one coherent, calming progression without unpredictable blotches.
    float theta = t * 0.72;
    float2 dir = float2(cos(theta), sin(theta));
    float2 ortho = float2(-dir.y, dir.x);
    float2 pNorm = (uv - 0.5) * 2.0;
    float gentleCurve = 0.055 * sin(dot(pNorm, ortho) * 1.6 - t * 0.85);
    float s = clamp(0.50 + 0.38 * dot(pNorm, dir) + gentleCurve, 0.0, 1.0);

    float3 lightCol = mix(pastelSpectrum(s), richGlowSpectrum(s), smoothstep(0.0, 0.88, edge) * 0.95);
    float3 darkCore = darkCoolSpectrum(s);
    float3 darkCol = mix(darkCore, darkEdgeSpectrum(s), smoothstep(0.22, 0.80, edge));
    float3 color = mix(lightCol, darkCol, U.dark);

    // Dual smooth orbiting highlights along the perimeter (hue-preserving luminance).
    float angle = atan2((uv.y - 0.5) * asp.y, (uv.x - 0.5) * asp.x);
    float arc = pow(max(0.5 + 0.5 * cos(2.0 * (angle - t * 0.95)), 0.0), 2.8);
    float crest = pow(max(0.5 + 0.5 * cos(angle - theta), 0.0), 2.2) * 0.70
                + pow(max(0.5 + 0.5 * cos(angle - theta + M_PI_F), 0.0), 3.0) * 0.35;
    float highlight = clamp(0.15 * arc * rim + 0.05 * crest * edge, 0.0, 1.0);
    color = mix(color, min(color * 1.15 + 0.12, float3(1.0)), highlight);

    // Restrained, effortless veil concentration: clear interior + luminous border without overpowering UI.
    float centerAlpha = mix(0.075, 0.070, U.dark) * k;
    float edgeAlpha = min(0.90, 0.76 * (0.72 + 0.28 * k));
    float colorAlpha = clamp(mix(centerAlpha, edgeAlpha, pow(max(edge, 0.0), 1.32))
                             + (0.07 * arc * rim + 0.025 * crest * edge) * k, 0.0, 0.92);

    float3 fogColor = mix(float3(0.95, 0.94, 1.00), float3(0.28, 0.24, 0.56), U.dark);
    float fogAlpha = mix(0.025, 0.038, U.dark) * (0.65 + 0.35 * k) * (1.0 - 0.72 * edge);

    float4 outc = float4(fogColor * fogAlpha, fogAlpha);
    outc = float4(color * colorAlpha, colorAlpha) + outc * (1.0 - colorAlpha);

    // Restrained micro-dot lattice with fresh per-cycle random sparkling glow stars.
    const float spacing = 8.5;
    float2 g = p / spacing;
    float2 cell = floor(g);
    float2 f = (fract(g) - 0.5) * spacing;
    float r2 = dot(f, f);

    float seed = hash21(cell + 31.7);
    float rate = 0.26 + 0.32 * hash21(cell + 9.1);
    float phaseClock = t * rate + seed * 19.0;
    float cycle = floor(phaseClock);
    float ph = fract(phaseClock);
    float gate = hash21(cell + float2(cycle * 3.17, 11.4));
    float env = smoothstep(0.0, 0.14, ph) * (1.0 - smoothstep(0.14, 0.48, ph));
    float sparkMain = gate > 0.952 ? env : 0.0;
    float sparkSoft = (gate > 0.875 && gate <= 0.952) ? env : 0.0;

    float sigma = 0.42 + 0.36 * sparkMain + 0.15 * sparkSoft;
    float haloWeight = 0.07 + 0.30 * sparkMain + 0.09 * sparkSoft;
    float dotShape = exp(-r2 / (2.0 * sigma * sigma)) + haloWeight * exp(-r2 / (2.0 * 1.45 * 1.45));

    float edgeDots = pow(max(edge, 0.0), 1.35);
    float baseDot = mix(mix(0.028, 0.30, edgeDots), mix(0.018, 0.26, edgeDots), U.dark);
    float radialPulse = 0.5 + 0.5 * sin(length(pn) * 6.0 - t * 2.2);
    float waveDot = (0.14 * crest + 0.04 * radialPulse) * (0.18 + 0.82 * edge);
    float twinkle = (0.90 * sparkMain + 0.36 * sparkSoft) * (0.34 + 0.66 * edge);
    float dotLevel = baseDot + waveDot + 0.12 * arc * rim + twinkle;
    float dotAlpha = clamp(dotShape * dotLevel, 0.0, 0.95) * mix(0.94, 0.90, U.dark);
    outc = float4(float3(dotAlpha), dotAlpha) + outc * (1.0 - dotAlpha);

    // Subtle static film grain prevents 8-bit gradient banding.
    float grain = (hash21(in.position.xy) - 0.5) * (2.5 / 255.0);
    outc.rgb = clamp(outc.rgb + grain * outc.a, 0.0, outc.a);
    return outc * (coverage * U.presence);
}
"""

struct OverlayUniforms {
    var size: SIMD2<Float>
    var scale: Float
    var time: Float
    var radius: Float
    var intensity: Float
    var dark: Float
    var presence: Float
}

final class OverlayCanvas: NSView {
    var style: OverlayStyle = .standard
    var prefersDark = false
    var cornerRadius: CGFloat = 22
    var reduceMotion = false
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

    init?(prefersDark: Bool) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            log("METAL no device")
            return nil
        }
        do {
            // Compiled at runtime so the probe stays a single swiftc-built file.
            let library = try device.makeLibrary(source: overlayShaderSource, options: nil)
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

    /// Rendering only runs while the overlay is on screen; each appearance fades in.
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
            presence: fade * fade * (3 - 2 * fade))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<OverlayUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}

// MARK: - Control bar

final class BannerView: NSVisualEffectView {
    static let baseSize = NSSize(width: 392, height: 74)
    private let baseCornerRadius: CGFloat = 20
    private var maskedSize = NSSize.zero
    private let tintView = NSView()
    private let spinner = SpinnerMark()
    private let titleField = ControlLabel(labelWithString: "")
    private let subtitleField = ControlLabel(labelWithString: "")
    private let statusLabel = ShimmerLabel(text: "远程控制中")
    let styleButton = PillButton()
    let closeButton = PillButton()

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

    init(owner: String, target: AnyObject, styleAction: Selector, closeAction: Selector) {
        super.init(frame: NSRect(origin: .zero, size: Self.baseSize))
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.cornerRadius = baseCornerRadius
        layer?.masksToBounds = true
        layer?.borderWidth = 0

        tintView.wantsLayer = true
        tintView.layer = CALayer()
        addSubview(tintView)
        updateTint()

        titleField.stringValue = "\(owner) 工作区"
        titleField.textColor = .white.withAlphaComponent(0.96)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        titleField.cell?.truncatesLastVisibleLine = true

        subtitleField.stringValue = "样式预览 · 未连接远程设备"
        subtitleField.textColor = .white.withAlphaComponent(0.52)
        subtitleField.lineBreakMode = .byTruncatingTail
        subtitleField.maximumNumberOfLines = 1
        subtitleField.cell?.truncatesLastVisibleLine = true

        styleButton.isBordered = false
        styleButton.toolTip = "切换柔和、标准、鲜明"
        styleButton.target = target
        styleButton.action = styleAction

        closeButton.isBordered = false
        closeButton.title = "结束"
        closeButton.toolTip = "结束遮罩样式测试"
        closeButton.target = target
        closeButton.action = closeAction

        addSubview(spinner)
        addSubview(titleField)
        addSubview(subtitleField)
        addSubview(statusLabel)
        addSubview(styleButton)
        addSubview(closeButton)
        updateMaterialMask()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func updateTint() {
        let alpha: CGFloat = reduceTransparency ? 0.96 : 0.78
        // Neutral charcoal so colorful overlay pixels behind the glass don't muddy it.
        tintView.layer?.backgroundColor = NSColor(srgbRed: 0.145, green: 0.148, blue: 0.165, alpha: alpha).cgColor
    }

    override func layout() {
        super.layout()
        let s = uiScale
        let w = bounds.width
        let h = bounds.height
        tintView.frame = bounds
        layer?.cornerRadius = min(baseCornerRadius * s, min(w, h) / 2)

        let padX = 16 * s
        let spinnerSize = 24 * s
        spinner.frame = NSRect(x: padX, y: (h - spinnerSize) / 2, width: spinnerSize, height: spinnerSize)

        let buttonH = 38 * s
        let buttonY = (h - buttonH) / 2
        let closeW = 46 * s
        let styleW = 72 * s
        let gap = 8 * s
        let closeX = w - padX - closeW
        let styleX = closeX - gap - styleW
        closeButton.frame = NSRect(x: closeX, y: buttonY, width: closeW, height: buttonH)
        styleButton.frame = NSRect(x: styleX, y: buttonY, width: styleW, height: buttonH)
        closeButton.uiScale = s
        styleButton.uiScale = s

        titleField.font = .systemFont(ofSize: 13.5 * s, weight: .medium)
        subtitleField.font = .systemFont(ofSize: 10 * s, weight: .regular)
        statusLabel.uiScale = s

        let textX = padX + spinnerSize + 10 * s
        let textW = max(40, styleX - 10 * s - textX)
        let h1 = ceil(titleField.fittingSize.height)
        let h2 = ceil(subtitleField.fittingSize.height)
        let h3 = statusLabel.intrinsicContentSize.height
        let lineGap = 2.0 * s
        let totalH = h1 + h2 + h3 + lineGap * 2
        let y3 = round((h - totalH) / 2)
        let y2 = y3 + h3 + lineGap
        let y1 = y2 + h2 + lineGap
        statusLabel.frame = NSRect(x: textX, y: y3, width: textW, height: h3)
        subtitleField.frame = NSRect(x: textX, y: y2, width: textW, height: h2)
        titleField.frame = NSRect(x: textX, y: y1, width: textW, height: h1)

        updateMaterialMask()
    }

    func tickAnimation() {
        spinner.needsDisplay = true
        statusLabel.needsDisplay = true
    }

    private func updateMaterialMask() {
        guard bounds.width > 0, bounds.height > 0, maskedSize != bounds.size else { return }
        maskedSize = bounds.size
        let size = bounds.size
        let radius = min(baseCornerRadius * uiScale, min(size.width, size.height) / 2)
        // behindWindow material is composited separately. Layer clipping alone
        // leaves its rectangular corners visible; mask the native material too.
        maskImage = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
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
        // Raised glass above the dark charcoal dock, never dark sunken cutouts.
        NSColor.white.withAlphaComponent(isHighlighted ? 0.05 : hovering ? 0.16 : 0.095).setFill()
        path.fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12 * uiScale, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.95)
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                                            y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
}

/// Activity spinner with a pointer glyph.
final class SpinnerMark: NSView {
    override var allowsVibrancy: Bool { false }
    var reduceMotion = false
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
            ctx.setFillColor(NSColor.white.withAlphaComponent(alpha).cgColor)
            ctx.addPath(CGPath(roundedRect: CGRect(x: -1.0, y: 5.8, width: 2.0, height: 4.1),
                               cornerWidth: 1.0, cornerHeight: 1.0, transform: nil))
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.move(to: CGPoint(x: -1.6, y: 3.6))
        ctx.addLine(to: CGPoint(x: -1.6, y: -4.8))
        ctx.addLine(to: CGPoint(x: 0.7, y: -2.7))
        ctx.addLine(to: CGPoint(x: 4.1, y: -2.7))
        ctx.closePath()
        ctx.fillPath()
    }
}

/// Status text with a smooth diagonal light sweep.
final class ShimmerLabel: NSView {
    override var allowsVibrancy: Bool { false }
    var uiScale: CGFloat = 1 { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var reduceMotion = false
    private let text: String
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
        let base = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: NSColor(srgbRed: 0.83, green: 0.82, blue: 0.96, alpha: 0.92)])
        let size = base.size()
        // Match NSTextField(labelWithString:)'s 2pt horizontal text inset.
        let inset = 2 * uiScale
        let origin = NSPoint(x: inset, y: (bounds.height - size.height) / 2)
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

// MARK: - Probe

final class Probe: NSObject, NSApplicationDelegate {
    let target: WindowInfo
    let duration: TimeInterval
    var appearanceMode: AppearanceMode
    let cornerRadiusOverride: CGFloat?
    let banner = OverlayPanel(interactive: true)
    let overlay = OverlayPanel(interactive: false)
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

    init(target: WindowInfo, duration: TimeInterval, appearanceMode: AppearanceMode, cornerRadius: CGFloat?) {
        self.target = target
        self.duration = duration
        self.appearanceMode = appearanceMode
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
        guard let canvas = OverlayCanvas(prefersDark: prefersDark) else {
            fputs("Metal is unavailable; the overlay cannot render.\n", stderr)
            exit(1)
        }
        self.canvas = canvas
        overlay.title = "KKRemote Overlay Test"
        overlay.contentView = canvas
        banner.title = "KKRemote 遮罩样式测试"
        bannerView = BannerView(owner: target.owner, target: self,
                                styleAction: #selector(cycleStyle), closeAction: #selector(quitFromUI))
        bannerView.styleButton.title = "\(style.title)样式"
        banner.contentView = bannerView
        banner.hasShadow = true

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "▣ 遮罩测试"
        let menu = NSMenu()
        menu.addItem(withTitle: "目标：\(target.owner) · 窗口 \(target.id)", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "仅样式测试；无远程连接", action: nil, keyEquivalent: "")
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

        log("START window=\(target.id) owner=\(target.owner) pid=\(target.pid) duration=\(Int(duration))s appearance=\(appearanceMode.rawValue)")
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
        if !running || reduce {
            uiAnimTimer?.invalidate()
            uiAnimTimer = nil
            if running { bannerView.tickAnimation() }
            return
        }
        guard uiAnimTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            self?.bannerView.tickAnimation()
        }
        RunLoop.main.add(t, forMode: .common)
        uiAnimTimer = t
    }

    func update() {
        guard Date() < deadline else { quit("deadline"); return }
        guard NSRunningApplication(processIdentifier: target.pid)?.isTerminated == false else { quit("target-terminated"); return }
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
        // Conservative probe policy: hide on any overlapping normal window.
        // This prevents painting a mask or clickable banner over unrelated apps.
        let occluder = windows[..<index].first {
            $0.pid != ProcessInfo.processInfo.processIdentifier && $0.layer == 0 &&
            !($0.owner == "ChatGPT Computer Use" && $0.title == "Software Cursor") &&
            // Chromium / Electron / AppKit small titlebar & status slivers.
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
        if rect != lastFrame {
            overlay.setFrame(rect, display: true)
            canvas.cornerRadius = cornerRadius(for: rect)
            let uiScale = min(1.0, (rect.width - 32) / BannerView.baseSize.width)
            let panelSize = NSSize(width: round(BannerView.baseSize.width * uiScale),
                                   height: round(BannerView.baseSize.height * uiScale))
            bannerView.uiScale = uiScale
            let targetY = min(rect.minY + 18 + panelSize.height, rect.maxY - panelSize.height - 12)
            let targetFrame = NSRect(x: round(rect.midX - panelSize.width / 2), y: round(targetY),
                                     width: panelSize.width, height: panelSize.height)
            if appearing {
                banner.setFrame(targetFrame, display: true)
            } else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    banner.animator().setFrame(targetFrame, display: true)
                }
            }
            bannerView.needsLayout = true
            bannerView.layoutSubtreeIfNeeded()
            lastFrame = rect
            log("FRAME x=\(Int(rect.minX)) y=\(Int(rect.minY)) w=\(Int(rect.width)) h=\(Int(rect.height)) radius=\(Int(canvas.cornerRadius))")
        }
        if appearing {
            banner.alphaValue = 0
            let targetY = banner.frame.minY
            if !reduceMotion {
                banner.setFrameOrigin(NSPoint(x: banner.frame.minX, y: max(rect.minY + 6, targetY - 8)))
            }
            if !panelOnly { canvas.setActive(true) }
        }
        // Re-establish adjacency if a click raises the target above our panels.
        let overlayIndex = windows.firstIndex(where: { $0.id == CGWindowID(overlay.windowNumber) })
        if panelOnly {
            let panelIndex = windows.firstIndex(where: { $0.id == CGWindowID(banner.windowNumber) })
            if !banner.isVisible || panelIndex == nil || panelIndex! > index || lastOrder != current.id {
                banner.order(.above, relativeTo: Int(current.id))
                lastOrder = current.id
            }
        } else if !overlay.isVisible || overlayIndex == nil || overlayIndex! > index || lastOrder != current.id {
            overlay.order(.above, relativeTo: Int(current.id))
            banner.order(.above, relativeTo: overlay.windowNumber)
            lastOrder = current.id
        }
        if appearing {
            let scale = min(1.0, (rect.width - 32) / BannerView.baseSize.width)
            let finalY = round(min(rect.minY + 18 + round(BannerView.baseSize.height * scale),
                                   rect.maxY - round(BannerView.baseSize.height * scale) - 12))
            NSAnimationContext.runAnimationGroup { context in
                context.duration = reduceMotion ? 0.12 : 0.28
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                banner.animator().alphaValue = 1
                banner.animator().setFrameOrigin(NSPoint(x: banner.frame.minX, y: finalY))
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

let arguments = CommandLine.arguments
func option(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}
if arguments.contains("--help") {
    print("""
    WindowOverlayProbe [--list] [--app NAME | --window-id ID] [--frontmost] [--duration SECONDS] [--panel-only]
                       [--appearance auto|light|dark] [--corner-radius POINTS]
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
let delegate = Probe(target: target, duration: duration, appearanceMode: appearanceMode, cornerRadius: cornerRadius)
app.delegate = delegate
app.run()
