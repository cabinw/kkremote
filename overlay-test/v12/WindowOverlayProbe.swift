import AppKit
import Foundation

private final class V12Controller: NSObject {
    static var current: V12Controller?

    weak var probe: Probe?
    private var dockMenuItems: [BannerDockEdge: NSMenuItem] = [:]
    private var dockWeights = SIMD4<Float>(1, 0, 0, 0)
    private var dragVisibility: Float = 0
    private var lastUpdateTime = CACurrentMediaTime()

    func attach(to probe: Probe, menu: NSMenu) {
        self.probe = probe
        applyDockPresentation(for: probe.dockEdge, snapNow: true)

        probe.onDockChanged = { [weak self] edge in
            self?.applyDockPresentation(for: edge, snapNow: false)
        }
        probe.bannerView.onBannerClicked = { [weak self, weak probe] in
            guard let self, let probe else { return }
            let order: [BannerDockEdge] = [.top, .right, .bottom, .left]
            let idx = order.firstIndex(of: probe.dockEdge) ?? 0
            let next = order[(idx + 1) % order.count]
            probe.setDockEdge(next)
            self.syncMenuChecks()
        }

        menu.addItem(.separator())
        let header = NSMenuItem(title: "停靠位置（可拖拽胶囊或点击）", action: nil, keyEquivalent: "")
        menu.addItem(header)
        let keys = ["1", "2", "3", "4"]
        for (i, edge) in BannerDockEdge.allCases.enumerated() {
            let item = NSMenuItem(title: edge.title, action: #selector(selectDock(_:)), keyEquivalent: keys[i])
            item.tag = i
            item.target = self
            dockMenuItems[edge] = item
            menu.addItem(item)
        }
        syncMenuChecks()
    }

    @objc private func selectDock(_ sender: NSMenuItem) {
        let edges = BannerDockEdge.allCases
        guard sender.tag >= 0, sender.tag < edges.count, let probe else { return }
        probe.setDockEdge(edges[sender.tag])
        syncMenuChecks()
    }

    private func syncMenuChecks() {
        guard let currentEdge = probe?.dockEdge else { return }
        for (edge, item) in dockMenuItems {
            item.state = (edge == currentEdge) ? .on : .off
        }
    }

    private func applyDockPresentation(for edge: BannerDockEdge, snapNow: Bool) {
        let compactLabel: String
        let subtitle: String
        switch edge {
        case .top:
            compactLabel = "顶栏受控"
            subtitle = "V12 顶栏融合 · 拖拽胶囊可吸附四边"
        case .bottom:
            compactLabel = "底边受控"
            subtitle = "V12 底边停靠 · 拖拽胶囊可吸附四边"
        case .left:
            compactLabel = "左侧受控"
            subtitle = "V12 左侧停靠 · 拖拽胶囊可吸附四边"
        case .right:
            compactLabel = "右侧受控"
            subtitle = "V12 右侧停靠 · 拖拽胶囊可吸附四边"
        }
        let cyanAccent = NSColor(srgbRed: 0.62, green: 0.95, blue: 1.00, alpha: 1.0)
        let dockTint = NSColor(srgbRed: 0.04, green: 0.09, blue: 0.16, alpha: 0.88)
        probe?.bannerView.applySemanticAppearance(
            subtitle: subtitle,
            status: "正在受控中",
            compact: compactLabel,
            accentColor: cyanAccent,
            tintColor: dockTint
        )
        if snapNow {
            dockWeights = weightVector(for: edge)
        }
        syncMenuChecks()
    }

    private func weightVector(for edge: BannerDockEdge) -> SIMD4<Float> {
        switch edge {
        case .top: return SIMD4(1, 0, 0, 0)
        case .bottom: return SIMD4(0, 1, 0, 0)
        case .left: return SIMD4(0, 0, 1, 0)
        case .right: return SIMD4(0, 0, 0, 1)
        }
    }

    func updateUniforms(_ u: inout OverlayUniforms) {
        let now = CACurrentMediaTime()
        let dt = Float(min(0.1, max(0.0, now - lastUpdateTime)))
        lastUpdateTime = now

        let activeEdge = (probe?.isDraggingBanner == true)
            ? (probe?.snapCandidateEdge ?? .top)
            : (probe?.dockEdge ?? .top)
        let targetWeights = weightVector(for: activeEdge)
        let blend = min(1.0, dt * 11.0)
        dockWeights += (targetWeights - dockWeights) * blend

        let dragTarget: Float = (probe?.isDraggingBanner == true) ? 1.0 : 0.0
        let dragRate: Float = dragTarget > dragVisibility ? 14.0 : 6.0
        dragVisibility += (dragTarget - dragVisibility) * min(1.0, dt * dragRate)

        u.param0 = dragVisibility
        u.custom = dockWeights
    }
}

private let v12FragmentShader = """
fragment half4 overlayFragment(VOut in [[stage_in]], constant Uniforms &U [[buffer(0)]]) {
    float2 p = in.position.xy / max(U.scale, 1.0);
    float2 padOrigin = U.cursor;
    float2 targetSize = max(U.clickOrigin, float2(1.0));
    float padMax = max(U.clickAge, 12.0);
    float2 tp = p - padOrigin;

    float dIn = insideDistance(tp, targetSize, U.radius);
    float dOut = -dIn;
    // Overlay lives strictly BELOW the target window and strictly OUTSIDE its boundary
    // so zero pixels ever cover text or bleed behind translucent macOS titlebars/sidebars.
    if (dOut < -1.0 || dOut >= padMax - 0.5) { return half4(0.0); }

    float dark = U.dark;
    float intense = U.intensity;
    float presence = clamp(U.presence, 0.0, 1.0);
    float4 dockW = U.custom; // (top, bottom, left, right)
    float dragVis = clamp(U.param0, 0.0, 1.0);

    // Smooth entry right at the window outer edge + strict zero fade before padMax (no clip box).
    float edgeStart = smoothstep(-0.8, 0.6, dOut);
    float outerFade = 1.0 - smoothstep(padMax * 0.48, padMax - 2.5, dOut);

    // 1. Crisp Exterior Jewel Rim (punches cleanly around window frame + native shadow).
    float dEdge = max(dOut, 0.0);
    float rimTight = exp(-pow(dEdge / 2.6, 1.55));
    float rimLip = exp(-pow(max(dEdge - 0.45, 0.0) / 1.05, 2.0));
    float haloCorona = exp(-dEdge / 13.5);

    float theta = perimeterAngle(tp, targetSize);
    float s = fract(theta / (M_PI_F * 2.0) + 0.5 + U.time * 0.045);

    float3 jewelLight = linearRamp5(
        s,
        float3(0.04, 0.58, 1.00),
        float3(0.32, 0.44, 0.98),
        float3(0.05, 0.80, 0.92),
        float3(0.14, 0.54, 1.00),
        float3(0.04, 0.58, 1.00)
    );
    float3 jewelDark = linearRamp5(
        s,
        float3(0.36, 0.90, 1.00),
        float3(0.60, 0.68, 1.00),
        float3(0.32, 0.98, 0.90),
        float3(0.46, 0.82, 1.00),
        float3(0.36, 0.90, 1.00)
    );
    float3 jewel = mix(jewelLight, jewelDark, dark);

    // Active-side affinity along outside perimeter of whichever edge hosts the capsule.
    float topMask = smoothstep(56.0, -6.0, tp.y);
    float bottomMask = smoothstep(56.0, -6.0, targetSize.y - tp.y);
    float leftMask = smoothstep(56.0, -6.0, tp.x);
    float rightMask = smoothstep(56.0, -6.0, targetSize.x - tp.x);
    float activeSide = dot(float4(topMask, bottomMask, leftMask, rightMask), dockW);
    // Boost exterior halo softly at the bottom where macOS casts a darker window drop shadow.
    float bottomShadowComp = 1.0 + 0.35 * smoothstep(targetSize.y - 90.0, targetSize.y, tp.y);

    // 2. Exterior Dock Spotlight Crown behind the active capsule anchor.
    float hasBanner = step(2.0, U.bannerRect.z);
    float2 bLocalCenter = U.bannerRect.xy + U.bannerRect.zw * 0.5 - padOrigin;
    float crownTop = dockW.x * exp(-pow((tp.x - bLocalCenter.x) / 120.0, 2.0)) * smoothstep(26.0, -2.0, tp.y);
    float crownBot = dockW.y * exp(-pow((tp.x - bLocalCenter.x) / 120.0, 2.0)) * smoothstep(26.0, -2.0, targetSize.y - tp.y);
    float crownLeft = dockW.z * exp(-pow((tp.y - bLocalCenter.y) / 96.0, 2.0)) * smoothstep(26.0, -2.0, tp.x);
    float crownRight = dockW.w * exp(-pow((tp.y - bLocalCenter.y) / 96.0, 2.0)) * smoothstep(26.0, -2.0, targetSize.x - tp.x);
    float dockCrown = hasBanner * (crownTop + crownBot + crownLeft + crownRight) * exp(-dEdge / 18.0);

    float rimAlpha = (rimTight * 0.74 + rimLip * 0.36) * (0.94 + 0.24 * activeSide) * bottomShadowComp;
    float coronaAlpha = haloCorona * (mix(0.28, 0.34, dark) + 0.16 * activeSide) * bottomShadowComp;
    float crownAlpha = dockCrown * mix(0.46, 0.54, dark) * bottomShadowComp;
    float3 crownColor = mix(jewel, float3(0.26, 0.94, 1.00), 0.45);

    // 3. Exterior MagSafe 4-Edge Snap Rails (illuminate outside edges while dragging).
    float railAlpha = 0.0;
    float3 railColor = float3(0.32, 0.90, 1.00);
    if (dragVis > 0.004) {
        float hSlotW = clamp(targetSize.x * 0.28, 60.0, 124.0) * 0.5;
        float vSlotH = clamp(targetSize.y * 0.22, 48.0, 100.0) * 0.5;
        float cx = clamp(bLocalCenter.x, 86.0 + 48.0, max(140.0, targetSize.x - 62.0));
        float bx = clamp(bLocalCenter.x, 62.0, max(100.0, targetSize.x - 62.0));
        float sy = clamp(bLocalCenter.y, 82.0, max(120.0, targetSize.y - 62.0));

        float dTopRail = roundedBoxSDF(tp, float2(cx, -7.5), float2(hSlotW, 3.0), 3.0);
        float dBotRail = roundedBoxSDF(tp, float2(bx, targetSize.y + 7.5), float2(hSlotW, 3.0), 3.0);
        float dLeftRail = roundedBoxSDF(tp, float2(-7.5, sy), float2(3.0, vSlotH), 3.0);
        float dRightRail = roundedBoxSDF(tp, float2(targetSize.x + 7.5, sy), float2(3.0, vSlotH), 3.0);

        float gTop = exp(-max(dTopRail, 0.0) / 4.0);
        float gBot = exp(-max(dBotRail, 0.0) / 4.0);
        float gLeft = exp(-max(dLeftRail, 0.0) / 4.0);
        float gRight = exp(-max(dRightRail, 0.0) / 4.0);

        float baseRails = max(max(gTop, gBot), max(gLeft, gRight)) * 0.42;
        float snapRail = gTop * dockW.x + gBot * dockW.y + gLeft * dockW.z + gRight * dockW.w;
        float snapCore = (exp(-max(dTopRail, 0.0) / 1.4) * dockW.x + exp(-max(dBotRail, 0.0) / 1.4) * dockW.y
                        + exp(-max(dLeftRail, 0.0) / 1.4) * dockW.z + exp(-max(dRightRail, 0.0) / 1.4) * dockW.w);
        railAlpha = dragVis * (baseRails + snapRail * 0.56 + snapCore * 0.42);
        railColor = mix(railColor, float3(0.55, 0.98, 1.00), clamp(snapRail, 0.0, 1.0));
    }

    float rawAlpha = (rimAlpha + coronaAlpha + crownAlpha + railAlpha) * edgeStart * outerFade;
    float3 rgb = (jewel * (rimAlpha + coronaAlpha) + crownColor * crownAlpha + railColor * railAlpha) * edgeStart * outerFade;
    float alpha = clamp(rawAlpha * intense * presence, 0.0, 0.98);
    float3 outRGB = (rawAlpha > 1e-5) ? (rgb / rawAlpha) * alpha : float3(0.0);
    return half4(half3(outRGB), half(alpha));
}
"""

@main
struct V12ProbeEntry {
    static func main() {
        let args = CommandLine.arguments
        func option(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }

        let startDock = option("--dock").flatMap(BannerDockEdge.init(rawValue:)) ?? .top
        if option("--dock") != nil && BannerDockEdge(rawValue: option("--dock")!) == nil {
            fputs("--dock must be top, bottom, left, or right.\n", stderr)
            exit(1)
        }
        let dockRatio = option("--dock-ratio").flatMap(Double.init).map { CGFloat(min(1.0, max(0.0, $0))) } ?? 0.5
        let alwaysExpanded = args.contains("--always-expanded")

        let controller = V12Controller()
        V12Controller.current = controller

        let effect = ProbeEffect(
            versionTag: "V12",
            subtitleTag: "V12 顶栏融合 · 拖拽胶囊可吸附四边",
            shaderFragmentSource: v12FragmentShader,
            bannerMode: alwaysExpanded ? .standard : .smartCollapsible(startCollapsed: true, autoCollapseDelay: 2.2),
            outerPadding: 34,
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
            extraUsage: "[--dock top|bottom|left|right] [--dock-ratio 0..1] [--always-expanded]"
        )
    }
}
