import AppKit
import Foundation

private enum V15Stage: String, CaseIterable {
    case nebula, spotlight, caustics

    var title: String {
        switch self {
        case .nebula: return "星云萤火舞台"
        case .spotlight: return "英雄聚光灯台"
        case .caustics: return "流体水波焦散"
        }
    }

    var compactLabel: String {
        switch self {
        case .nebula: return "星云舞台"
        case .spotlight: return "聚光舞台"
        case .caustics: return "水波舞台"
        }
    }

    var accentColor: NSColor {
        switch self {
        case .nebula: return NSColor(srgbRed: 0.62, green: 0.88, blue: 1.00, alpha: 1.0)
        case .spotlight: return NSColor(srgbRed: 1.00, green: 0.86, blue: 0.56, alpha: 1.0)
        case .caustics: return NSColor(srgbRed: 0.34, green: 0.98, blue: 0.90, alpha: 1.0)
        }
    }

    var tintColor: NSColor {
        switch self {
        case .nebula: return NSColor(srgbRed: 0.06, green: 0.06, blue: 0.16, alpha: 0.88)
        case .spotlight: return NSColor(srgbRed: 0.11, green: 0.09, blue: 0.08, alpha: 0.88)
        case .caustics: return NSColor(srgbRed: 0.03, green: 0.11, blue: 0.15, alpha: 0.88)
        }
    }

    var weights: SIMD4<Float> {
        switch self {
        case .nebula: return SIMD4(1, 0, 0, 0)
        case .spotlight: return SIMD4(0, 1, 0, 0)
        case .caustics: return SIMD4(0, 0, 1, 0)
        }
    }
}

private final class V15Controller: NSObject {
    static var current: V15Controller?

    weak var probe: Probe?
    private var stage: V15Stage
    private var stageWeights: SIMD4<Float>
    private var dragVisibility: Float = 0
    private var lastUpdateTime: CFTimeInterval = CACurrentMediaTime()
    private var stageMenuItems: [V15Stage: NSMenuItem] = [:]
    private var dockMenuItems: [BannerDockEdge: NSMenuItem] = [:]

    init(initialStage: V15Stage) {
        self.stage = initialStage
        self.stageWeights = initialStage.weights
        super.init()
    }

    func attach(to probe: Probe, menu: NSMenu) {
        self.probe = probe
        applyPresentation(snapWeights: true)

        probe.onDockChanged = { [weak self] _ in
            self?.syncMenus()
        }
        probe.bannerView.onBannerClicked = { [weak self] in
            guard let self else { return }
            let all = V15Stage.allCases
            let next = all[((all.firstIndex(of: self.stage) ?? 0) + 1) % all.count]
            self.setStage(next)
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "零边框空间舞台（轻点胶囊切换）", action: nil, keyEquivalent: "")
        let keys = ["1", "2", "3"]
        for (i, s) in V15Stage.allCases.enumerated() {
            let item = NSMenuItem(title: s.title, action: #selector(selectStage(_:)), keyEquivalent: keys[i])
            item.tag = i
            item.target = self
            stageMenuItems[s] = item
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "胶囊停靠边（拖拽即可吸附四边）", action: nil, keyEquivalent: "")
        for (i, edge) in BannerDockEdge.allCases.enumerated() {
            let item = NSMenuItem(title: edge.title, action: #selector(selectDock(_:)), keyEquivalent: "")
            item.tag = i
            item.target = self
            dockMenuItems[edge] = item
            menu.addItem(item)
        }
        syncMenus()
    }

    @objc private func selectStage(_ sender: NSMenuItem) {
        let all = V15Stage.allCases
        guard sender.tag >= 0, sender.tag < all.count else { return }
        setStage(all[sender.tag])
    }

    @objc private func selectDock(_ sender: NSMenuItem) {
        let edges = BannerDockEdge.allCases
        guard sender.tag >= 0, sender.tag < edges.count, let probe else { return }
        probe.setDockEdge(edges[sender.tag])
        syncMenus()
    }

    func setStage(_ newStage: V15Stage) {
        stage = newStage
        applyPresentation(snapWeights: false)
        syncMenus()
        log("STAGE value=\(newStage.rawValue)")
    }

    private func applyPresentation(snapWeights: Bool) {
        if snapWeights {
            stageWeights = stage.weights
        }
        probe?.bannerView.applySemanticAppearance(
            subtitle: "V15 \(stage.title) · 无边框窗后立体氛围",
            status: "正在受控中",
            compact: stage.compactLabel,
            accentColor: stage.accentColor,
            tintColor: stage.tintColor
        )
    }

    private func syncMenus() {
        for (s, item) in stageMenuItems {
            item.state = (s == stage) ? .on : .off
        }
        if let currentEdge = probe?.dockEdge {
            for (e, item) in dockMenuItems {
                item.state = (e == currentEdge) ? .on : .off
            }
        }
    }

    func updateUniforms(_ u: inout OverlayUniforms) {
        let now = CACurrentMediaTime()
        let dt = Float(min(0.1, max(0.0, now - lastUpdateTime)))
        lastUpdateTime = now

        stageWeights += (stage.weights - stageWeights) * min(1.0, dt * 4.2)

        let dragTarget: Float = (probe?.isDraggingBanner == true) ? 1.0 : 0.0
        let dragRate: Float = dragTarget > dragVisibility ? 14.0 : 6.0
        dragVisibility += (dragTarget - dragVisibility) * min(1.0, dt * dragRate)

        u.param0 = dragVisibility
        u.custom = stageWeights
    }
}

private let v15FragmentShader = """
static float fbm3(float2 p) {
    float v = 0.0;
    float a = 0.52;
    for (int i = 0; i < 3; ++i) {
        v += a * valueNoise(p);
        p = float2(p.x * 1.92 - p.y * 0.72, p.x * 0.72 + p.y * 1.92) + float2(7.3, 13.1);
        a *= 0.5;
    }
    return v;
}

// Soft organic bokeh firefly / dust mote orb with crisp sparkle core + ambient halo.
static void renderFireflies(float2 tp, float2 targetSize, float t, float dEdge, float3 cA, float3 cB,
                            thread float &outAlpha, thread float3 &outRGB) {
    float2 center = targetSize * 0.5;
    float2 halfBox = targetSize * 0.5;
    for (int i = 0; i < 18; ++i) {
        float fi = float(i);
        float h0 = hash21(float2(fi * 3.17, 19.4));
        float h1 = hash21(float2(fi * 7.53, 41.2));
        float h2 = hash21(float2(fi * 11.9, 83.7));
        float perimPhase = fract(h0 + t * (0.012 + 0.018 * h1) * ((i % 2 == 0) ? 1.0 : -1.0));
        float ang = (perimPhase - 0.5) * M_PI_F * 2.0;

        // Place orbs organically across outer apron (14..64 pt outward, no straight rectangle!).
        float2 dir = normalize(float2(cos(ang) * halfBox.x, sin(ang) * halfBox.y));
        float2 edgeAnchor = center + float2(
            clamp(dir.x * max(halfBox.x, halfBox.y) * 1.4, -halfBox.x, halfBox.x),
            clamp(dir.y * max(halfBox.x, halfBox.y) * 1.4, -halfBox.y, halfBox.y)
        );
        float radialOrbit = 10.0 + 36.0 * h2 + 8.0 * sin(t * (0.9 + h1 * 0.8) + fi);
        float2 sway = float2(sin(t * 0.85 + fi * 1.7), cos(t * 0.72 + fi * 2.3) - 0.65) * 9.0;
        float2 orbPos = edgeAnchor + dir * radialOrbit + sway;

        float dist = length(tp - orbPos);
        float radius = mix(3.8, 10.5, h0);
        float twinkle = 0.35 + 0.65 * pow(0.5 + 0.5 * sin(t * (1.4 + h2 * 1.6) + fi * 2.9), 2.0);
        float bokeh = exp(-pow(dist / radius, 2.0)) * 0.45 + exp(-pow(dist / (radius * 0.32), 2.0)) * 0.75;
        float contrib = bokeh * twinkle;
        float3 col = mix(cA, cB, h2);
        outAlpha += contrib;
        outRGB += col * contrib;
    }
}

fragment half4 overlayFragment(VOut in [[stage_in]], constant Uniforms &U [[buffer(0)]]) {
    float2 p = in.position.xy / max(U.scale, 1.0);
    float2 padOrigin = U.cursor;
    float2 targetSize = max(U.clickOrigin, float2(1.0));
    float padMax = max(U.clickAge, 20.0);
    float2 tp = p - padOrigin;

    float dIn = insideDistance(tp, targetSize, U.radius);
    float dOut = -dIn;
    if (dOut < -1.0 || dOut >= padMax - 0.5) { return half4(0.0); }

    float dark = U.dark;
    float intense = U.intensity;
    float presence = clamp(U.presence, 0.0, 1.0);
    float4 stageW = U.custom; // (nebula, spotlight, caustics, 0)
    float dragVis = clamp(U.param0, 0.0, 1.0);
    float dEdge = max(dOut, 0.0);

    // NO border or rim lines! Pure soft atmospheric spread decaying smoothly to 0 inside padMax.
    float softStart = smoothstep(-0.6, 4.5, dOut);
    float outerFade = 1.0 - smoothstep(padMax * 0.45, padMax - 3.0, dOut);
    float theta = perimeterAngle(tp, targetSize);

    // Asymmetric gravity bias: deeper illuminated puddle below floating window, airy upward fade.
    float verticalLift = mix(0.88, 1.38, smoothstep(0.0, targetSize.y, tp.y));

    // --- Stage 1: Nebula & Floating Fireflies ---
    float nebulaA = 0.0;
    float3 nebulaRGB = float3(0.0);
    if (stageW.x > 0.005) {
        float2 np = tp * 0.011;
        float n1 = fbm3(np + float2(U.time * 0.07, -U.time * 0.05));
        float n2 = fbm3(np * 1.45 - float2(U.time * 0.06, U.time * 0.08) + float2(n1 * 1.2, 0.0));
        float cloudReach = mix(22.0, 62.0, clamp(n2, 0.0, 1.0)) * verticalLift;
        float cloudMask = exp(-dEdge / max(cloudReach, 8.0)) * (0.30 + 0.55 * n1);
        float3 cloudCol = linearRamp5(
            fract(n2 * 0.85 + theta / (M_PI_F * 2.0) + U.time * 0.025),
            float3(0.14, 0.72, 1.00),
            float3(0.44, 0.34, 1.00),
            float3(0.92, 0.34, 0.76),
            float3(0.18, 0.88, 0.86),
            float3(0.14, 0.72, 1.00)
        );
        float ffA = 0.0;
        float3 ffRGB = float3(0.0);
        renderFireflies(tp, targetSize, U.time, dEdge,
                        float3(0.45, 0.94, 1.00), float3(1.00, 0.80, 0.56), ffA, ffRGB);
        nebulaA = stageW.x * (cloudMask * mix(0.68, 0.78, dark) + ffA * 0.65);
        nebulaRGB = stageW.x * (cloudCol * cloudMask * mix(0.68, 0.78, dark) + ffRGB * 0.65);
    }

    // --- Stage 2: Hero Studio Spotlight Beams & Levitating Floor Bounce ---
    float spotA = 0.0;
    float3 spotRGB = float3(0.0);
    if (stageW.y > 0.005) {
        float2 topApexL = float2(targetSize.x * 0.16, -90.0);
        float2 topApexR = float2(targetSize.x * 0.84, -90.0);
        float2 vL = tp - topApexL;
        float2 vR = tp - topApexR;
        float beamAngL = atan2(vL.x, max(vL.y, 1.0));
        float beamAngR = atan2(vR.x, max(vR.y, 1.0));
        float coneL = exp(-pow((beamAngL + 0.42 + 0.08 * sin(U.time * 0.7)) / 0.38, 2.0));
        float coneR = exp(-pow((beamAngR - 0.42 - 0.08 * cos(U.time * 0.6)) / 0.38, 2.0));
        float shafts = 0.70 + 0.30 * sin(theta * 24.0 + U.time * 0.9);
        float floorGlow = exp(-pow((tp.y - targetSize.y - 14.0) / 34.0, 2.0))
                        * exp(-pow((tp.x - targetSize.x * 0.5) / max(targetSize.x * 0.52, 180.0), 2.0));
        float radialBed = exp(-dEdge / 38.0) * (coneL * 0.48 + coneR * 0.48) * shafts + floorGlow * 0.78;

        float ffA = 0.0;
        float3 ffRGB = float3(0.0);
        renderFireflies(tp, targetSize, U.time * 0.75, dEdge,
                        float3(1.00, 0.88, 0.60), float3(0.60, 0.86, 1.00), ffA, ffRGB);

        float3 beamCol = mix(float3(0.24, 0.62, 1.00), float3(1.00, 0.76, 0.38), clamp(floorGlow + coneR * 0.4, 0.0, 1.0));
        spotA = stageW.y * (radialBed * mix(0.62, 0.74, dark) + ffA * 0.45);
        spotRGB = stageW.y * (beamCol * radialBed * mix(0.62, 0.74, dark) + ffRGB * 0.45);
    }

    // --- Stage 3: Luminous Liquid Water Caustics Pool ---
    float waterA = 0.0;
    float3 waterRGB = float3(0.0);
    if (stageW.z > 0.005) {
        float2 wp = tp * 0.036;
        float warp = fbm3(wp * 0.45 + float2(U.time * 0.14, -U.time * 0.10)) * 2.6;
        float c1 = abs(sin(wp.x + warp + U.time * 0.85) + cos(wp.y - warp * 0.8 - U.time * 0.65));
        float c2 = abs(sin(wp.x * 0.8 - wp.y * 0.6 + U.time * 0.55 + warp));
        float filament = pow(clamp(1.0 - min(c1, c2) * 0.68, 0.0, 1.0), 2.6);
        float poolFalloff = exp(-dEdge / (34.0 * verticalLift));
        float waterMass = poolFalloff * (0.26 + 0.74 * filament);
        float3 waterCol = mix(float3(0.04, 0.68, 0.96), float3(0.45, 1.00, 0.92), filament);
        waterA = stageW.z * waterMass * mix(0.64, 0.74, dark);
        waterRGB = stageW.z * waterCol * waterMass * mix(0.64, 0.74, dark);
    }

    // Soft Anchor Landing Orbs (only when dragging capsule — zero rectangular guide box!).
    float railAlpha = 0.0;
    float3 railCol = float3(0.76, 0.96, 1.00);
    float2 bLocalCenter = U.bannerRect.xy + U.bannerRect.zw * 0.5 - padOrigin;
    if (dragVis > 0.004) {
        float2 pTop = float2(clamp(bLocalCenter.x, 86.0, max(120.0, targetSize.x - 62.0)), -18.0);
        float2 pBot = float2(clamp(bLocalCenter.x, 62.0, max(100.0, targetSize.x - 62.0)), targetSize.y + 18.0);
        float2 pLeft = float2(-18.0, clamp(bLocalCenter.y, 82.0, max(120.0, targetSize.y - 62.0)));
        float2 pRight = float2(targetSize.x + 18.0, clamp(bLocalCenter.y, 82.0, max(120.0, targetSize.y - 62.0)));

        float oT = exp(-pow(length(tp - pTop) / 14.0, 2.0));
        float oB = exp(-pow(length(tp - pBot) / 14.0, 2.0));
        float oL = exp(-pow(length(tp - pLeft) / 14.0, 2.0));
        float oR = exp(-pow(length(tp - pRight) / 14.0, 2.0));
        float dMin = min(min(max(0.0, bLocalCenter.y), max(0.0, targetSize.y - bLocalCenter.y)),
                         min(max(0.0, bLocalCenter.x), max(0.0, targetSize.x - bLocalCenter.x)));
        float activeOrb = (max(0.0, bLocalCenter.y) <= dMin + 0.5 ? oT :
                          (max(0.0, targetSize.y - bLocalCenter.y) <= dMin + 0.5 ? oB :
                          (max(0.0, bLocalCenter.x) <= dMin + 0.5 ? oL : oR)));
        railAlpha = dragVis * (max(max(oT, oB), max(oL, oR)) * 0.45 + activeOrb * 0.65);
    }

    float mask = softStart * outerFade;
    float rawAlpha = (nebulaA + spotA + waterA + railAlpha) * mask;
    float3 rgb = (nebulaRGB + spotRGB + waterRGB + railCol * railAlpha) * mask;
    float alpha = clamp(rawAlpha * intense * presence, 0.0, 0.96);
    float3 outRGB = (rawAlpha > 1e-5) ? (rgb / rawAlpha) * alpha : float3(0.0);
    return half4(half3(outRGB), half(alpha));
}
"""

@main
struct V15ProbeEntry {
    static func main() {
        let args = CommandLine.arguments
        func option(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }

        let startStage = option("--stage").flatMap(V15Stage.init(rawValue:)) ?? .nebula
        if option("--stage") != nil && V15Stage(rawValue: option("--stage")!) == nil {
            fputs("--stage must be nebula, spotlight, or caustics.\n", stderr)
            exit(1)
        }
        let startDock = option("--dock").flatMap(BannerDockEdge.init(rawValue:)) ?? .bottom
        if option("--dock") != nil && BannerDockEdge(rawValue: option("--dock")!) == nil {
            fputs("--dock must be top, bottom, left, or right.\n", stderr)
            exit(1)
        }
        let dockRatio = option("--dock-ratio").flatMap(Double.init).map { CGFloat(min(1.0, max(0.0, $0))) } ?? 0.5
        let alwaysExpanded = args.contains("--always-expanded")

        let controller = V15Controller(initialStage: startStage)
        V15Controller.current = controller

        let effect = ProbeEffect(
            versionTag: "V15",
            subtitleTag: "V15 无边框立体氛围舞台 · 轻点切景",
            shaderFragmentSource: v15FragmentShader,
            bannerMode: alwaysExpanded ? .standard : .smartCollapsible(startCollapsed: true, autoCollapseDelay: 2.2),
            outerPadding: 78,
            overlayBelowTarget: true,
            supportsFourEdgeDock: true,
            initialDockEdge: startDock,
            initialDockRatio: dockRatio,
            updateUniforms: { [weak controller] uniforms, _, _, _ in
                controller?.updateUniforms(&uniforms)
            },
            setupExtraMenuItems: { menu, probe in
                controller.attach(to: probe, menu: menu)
            }
        )
        runProbeMain(
            effect: effect,
            extraUsage: "[--stage nebula|spotlight|caustics] [--dock top|bottom|left|right] [--dock-ratio 0..1] [--always-expanded]"
        )
    }
}
