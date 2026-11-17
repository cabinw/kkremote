import AppKit
import Foundation

private final class V13Controller: NSObject {
    static var current: V13Controller?

    weak var probe: Probe?
    private var dockMenuItems: [BannerDockEdge: NSMenuItem] = [:]
    private var dockWeights = SIMD4<Float>(0, 1, 0, 0)
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
            let order: [BannerDockEdge] = [.bottom, .right, .top, .left]
            let idx = order.firstIndex(of: probe.dockEdge) ?? 0
            let next = order[(idx + 1) % order.count]
            probe.setDockEdge(next)
            self.syncMenuChecks()
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "停靠位置（可拖拽胶囊或轻点）", action: nil, keyEquivalent: "")
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
            compactLabel = "取景顶栏"
            subtitle = "V13 外置取景锁定框 · 双星巡航外框（顶栏）"
        case .bottom:
            compactLabel = "取景受控"
            subtitle = "V13 外置取景锁定框 · 四边可拖拽吸附"
        case .left:
            compactLabel = "取景左侧"
            subtitle = "V13 外置取景锁定框 · 左侧边停靠"
        case .right:
            compactLabel = "取景右侧"
            subtitle = "V13 外置取景锁定框 · 右侧边停靠"
        }
        let accent = NSColor(srgbRed: 0.45, green: 0.98, blue: 0.88, alpha: 1.0)
        let tint = NSColor(srgbRed: 0.04, green: 0.09, blue: 0.14, alpha: 0.88)
        probe?.bannerView.applySemanticAppearance(
            subtitle: subtitle,
            status: "正在受控中",
            compact: compactLabel,
            accentColor: accent,
            tintColor: tint
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
            ? (probe?.snapCandidateEdge ?? .bottom)
            : (probe?.dockEdge ?? .bottom)
        let targetWeights = weightVector(for: activeEdge)
        dockWeights += (targetWeights - dockWeights) * min(1.0, dt * 11.0)

        let dragTarget: Float = (probe?.isDraggingBanner == true) ? 1.0 : 0.0
        let dragRate: Float = dragTarget > dragVisibility ? 14.0 : 6.0
        dragVisibility += (dragTarget - dragVisibility) * min(1.0, dt * dragRate)

        u.param0 = dragVisibility
        u.custom = dockWeights
    }
}

private let v13FragmentShader = """
fragment half4 overlayFragment(VOut in [[stage_in]], constant Uniforms &U [[buffer(0)]]) {
    float2 p = in.position.xy / max(U.scale, 1.0);
    float2 padOrigin = U.cursor;
    float2 targetSize = max(U.clickOrigin, float2(1.0));
    float padMax = max(U.clickAge, 12.0);
    float2 tp = p - padOrigin;

    float dIn = insideDistance(tp, targetSize, U.radius);
    float dOut = -dIn;
    if (dOut < -1.0 || dOut >= padMax - 0.5) { return half4(0.0); }

    float dark = U.dark;
    float intense = U.intensity;
    float presence = clamp(U.presence, 0.0, 1.0);
    float4 dockW = U.custom;
    float dragVis = clamp(U.param0, 0.0, 1.0);
    float dEdge = max(dOut, 0.0);

    float edgeStart = smoothstep(-0.8, 0.5, dOut);
    float outerFade = 1.0 - smoothstep(padMax * 0.54, padMax - 2.0, dOut);
    float bottomShadowComp = 1.0 + 0.36 * smoothstep(targetSize.y - 96.0, targetSize.y, tp.y);

    // 1. Crisp Exterior Track Rim (continuous 4-side reference wire just outside window frame).
    float trackLine = exp(-pow(max(dEdge - 0.55, 0.0) / 1.35, 2.0));
    float trackGlow = exp(-dEdge / 10.5);

    // 2. Four Concentric Corner Viewfinder Brackets (precision optical capture frame outside R=22 corners).
    float dxEdge = min(tp.x, targetSize.x - tp.x);
    float dyEdge = min(tp.y, targetSize.y - tp.y);
    float cornerArm = smoothstep(64.0, 32.0, dxEdge) * smoothstep(64.0, 32.0, dyEdge);
    float bracketCore = cornerArm * exp(-pow((dOut - 5.2) / 1.4, 2.0));
    float bracketHalo = cornerArm * exp(-abs(dOut - 5.2) / 4.8);
    float breathe = 0.88 + 0.12 * sin(U.time * 2.2);

    // 3. Dual Counter-Opposite Comet Pulses orbiting outside perimeter track.
    float theta = perimeterAngle(tp, targetSize);
    float a1 = U.time * 1.45;
    float trail1 = fmod(a1 - theta + M_PI_F * 4.0, M_PI_F * 2.0);
    float tail1 = exp(-trail1 * 3.4) * smoothstep(M_PI_F * 2.0, M_PI_F * 2.0 - 0.14, trail1);
    float head1 = exp(-pow(wrapAngleDelta(theta, a1) / 0.10, 2.0));

    float a2 = a1 + M_PI_F;
    float trail2 = fmod(a2 - theta + M_PI_F * 4.0, M_PI_F * 2.0);
    float tail2 = exp(-trail2 * 3.4) * smoothstep(M_PI_F * 2.0, M_PI_F * 2.0 - 0.14, trail2);
    float head2 = exp(-pow(wrapAngleDelta(theta, a2) / 0.10, 2.0));

    float cometTight = exp(-dEdge / 3.5);
    float cometBloom = exp(-dEdge / 16.0);
    float c1 = (head1 * 1.15 + tail1 * 0.72) * cometTight + (head1 * 0.48 + tail1 * 0.28) * cometBloom;
    float c2 = (head2 * 1.15 + tail2 * 0.72) * cometTight + (head2 * 0.48 + tail2 * 0.28) * cometBloom;

    // 4. Dock Anchor Spotlight along whichever edge currently holds the capsule.
    float hasBanner = step(2.0, U.bannerRect.z);
    float2 bLocalCenter = U.bannerRect.xy + U.bannerRect.zw * 0.5 - padOrigin;
    float crownTop = dockW.x * exp(-pow((tp.x - bLocalCenter.x) / 115.0, 2.0)) * smoothstep(26.0, -2.0, tp.y);
    float crownBot = dockW.y * exp(-pow((tp.x - bLocalCenter.x) / 115.0, 2.0)) * smoothstep(26.0, -2.0, targetSize.y - tp.y);
    float crownLeft = dockW.z * exp(-pow((tp.y - bLocalCenter.y) / 92.0, 2.0)) * smoothstep(26.0, -2.0, tp.x);
    float crownRight = dockW.w * exp(-pow((tp.y - bLocalCenter.y) / 92.0, 2.0)) * smoothstep(26.0, -2.0, targetSize.x - tp.x);
    float dockCrown = hasBanner * (crownTop + crownBot + crownLeft + crownRight) * exp(-dEdge / 16.0);

    // 5. Exterior MagSafe 4-Edge Drag Target Rails.
    float railAlpha = 0.0;
    float3 railColor = float3(0.32, 0.96, 0.86);
    if (dragVis > 0.004) {
        float hSlotW = clamp(targetSize.x * 0.28, 60.0, 124.0) * 0.5;
        float vSlotH = clamp(targetSize.y * 0.22, 48.0, 100.0) * 0.5;
        float cx = clamp(bLocalCenter.x, 86.0 + 48.0, max(140.0, targetSize.x - 62.0));
        float bx = clamp(bLocalCenter.x, 62.0, max(100.0, targetSize.x - 62.0));
        float sy = clamp(bLocalCenter.y, 82.0, max(120.0, targetSize.y - 62.0));

        float dTopRail = roundedBoxSDF(tp, float2(cx, -8.0), float2(hSlotW, 3.0), 3.0);
        float dBotRail = roundedBoxSDF(tp, float2(bx, targetSize.y + 8.0), float2(hSlotW, 3.0), 3.0);
        float dLeftRail = roundedBoxSDF(tp, float2(-8.0, sy), float2(3.0, vSlotH), 3.0);
        float dRightRail = roundedBoxSDF(tp, float2(targetSize.x + 8.0, sy), float2(3.0, vSlotH), 3.0);

        float gTop = exp(-max(dTopRail, 0.0) / 4.0);
        float gBot = exp(-max(dBotRail, 0.0) / 4.0);
        float gLeft = exp(-max(dLeftRail, 0.0) / 4.0);
        float gRight = exp(-max(dRightRail, 0.0) / 4.0);

        float baseRails = max(max(gTop, gBot), max(gLeft, gRight)) * 0.42;
        float snapRail = gTop * dockW.x + gBot * dockW.y + gLeft * dockW.z + gRight * dockW.w;
        float snapCore = (exp(-max(dTopRail, 0.0) / 1.4) * dockW.x + exp(-max(dBotRail, 0.0) / 1.4) * dockW.y
                        + exp(-max(dLeftRail, 0.0) / 1.4) * dockW.z + exp(-max(dRightRail, 0.0) / 1.4) * dockW.w);
        railAlpha = dragVis * (baseRails + snapRail * 0.56 + snapCore * 0.42);
        railColor = mix(railColor, float3(0.75, 1.00, 0.94), clamp(snapRail, 0.0, 1.0));
    }

    float3 trackColor = mix(float3(0.06, 0.58, 0.88), float3(0.28, 0.84, 1.00), dark);
    float3 bracketColor = mix(float3(0.08, 0.82, 0.72), float3(0.36, 0.98, 0.86), dark);
    float3 comet1Color = float3(0.26, 0.98, 0.86);
    float3 comet2Color = float3(0.38, 0.72, 1.00);
    float3 crownColor = float3(0.28, 0.92, 0.96);

    float trackAlpha = (trackLine * 0.58 + trackGlow * mix(0.20, 0.26, dark)) * bottomShadowComp;
    float bracketAlpha = (bracketCore * 0.88 + bracketHalo * 0.28) * breathe * bottomShadowComp;
    float cometAlpha1 = c1 * bottomShadowComp;
    float cometAlpha2 = c2 * bottomShadowComp;
    float crownAlpha = dockCrown * mix(0.42, 0.50, dark) * bottomShadowComp;

    float mask = edgeStart * outerFade;
    float rawAlpha = (trackAlpha + bracketAlpha + cometAlpha1 + cometAlpha2 + crownAlpha + railAlpha) * mask;
    float3 rgb = (trackColor * trackAlpha
                + bracketColor * bracketAlpha
                + comet1Color * cometAlpha1
                + comet2Color * cometAlpha2
                + crownColor * crownAlpha
                + railColor * railAlpha) * mask;

    float alpha = clamp(rawAlpha * intense * presence, 0.0, 0.98);
    float3 outRGB = (rawAlpha > 1e-5) ? (rgb / rawAlpha) * alpha : float3(0.0);
    return half4(half3(outRGB), half(alpha));
}
"""

@main
struct V13ProbeEntry {
    static func main() {
        let args = CommandLine.arguments
        func option(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }

        let startDock = option("--dock").flatMap(BannerDockEdge.init(rawValue:)) ?? .bottom
        if option("--dock") != nil && BannerDockEdge(rawValue: option("--dock")!) == nil {
            fputs("--dock must be top, bottom, left, or right.\n", stderr)
            exit(1)
        }
        let dockRatio = option("--dock-ratio").flatMap(Double.init).map { CGFloat(min(1.0, max(0.0, $0))) } ?? 0.5
        let alwaysExpanded = args.contains("--always-expanded")

        let controller = V13Controller()
        V13Controller.current = controller

        let effect = ProbeEffect(
            versionTag: "V13",
            subtitleTag: "V13 窗外精密取景框 · 四边可拖拽吸附",
            shaderFragmentSource: v13FragmentShader,
            bannerMode: alwaysExpanded ? .standard : .smartCollapsible(startCollapsed: true, autoCollapseDelay: 2.2),
            outerPadding: 36,
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
