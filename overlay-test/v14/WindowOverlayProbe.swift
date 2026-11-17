import AppKit
import Foundation

private enum V14Theme: String, CaseIterable {
    case prism, violet, solar, emerald

    var title: String {
        switch self {
        case .prism: return "全息棱镜"
        case .violet: return "紫电超频"
        case .solar: return "炽焰极光"
        case .emerald: return "矩阵翡翠"
        }
    }

    var compactLabel: String {
        switch self {
        case .prism: return "全息受控"
        case .violet: return "紫电受控"
        case .solar: return "炽焰受控"
        case .emerald: return "翡翠受控"
        }
    }

    var accentColor: NSColor {
        switch self {
        case .prism: return NSColor(srgbRed: 0.42, green: 0.96, blue: 1.00, alpha: 1.0)
        case .violet: return NSColor(srgbRed: 0.84, green: 0.56, blue: 1.00, alpha: 1.0)
        case .solar: return NSColor(srgbRed: 1.00, green: 0.72, blue: 0.36, alpha: 1.0)
        case .emerald: return NSColor(srgbRed: 0.36, green: 1.00, blue: 0.72, alpha: 1.0)
        }
    }

    var tintColor: NSColor {
        switch self {
        case .prism: return NSColor(srgbRed: 0.04, green: 0.09, blue: 0.17, alpha: 0.88)
        case .violet: return NSColor(srgbRed: 0.11, green: 0.05, blue: 0.18, alpha: 0.88)
        case .solar: return NSColor(srgbRed: 0.17, green: 0.07, blue: 0.06, alpha: 0.88)
        case .emerald: return NSColor(srgbRed: 0.03, green: 0.13, blue: 0.10, alpha: 0.88)
        }
    }

    var weights: SIMD4<Float> {
        switch self {
        case .prism: return SIMD4(1, 0, 0, 0)
        case .violet: return SIMD4(0, 1, 0, 0)
        case .solar: return SIMD4(0, 0, 1, 0)
        case .emerald: return SIMD4(0, 0, 0, 1)
        }
    }
}

private final class V14Controller: NSObject {
    static var current: V14Controller?

    weak var probe: Probe?
    private var theme: V14Theme
    private var themeWeights: SIMD4<Float>
    private var dragVisibility: Float = 0
    private var shockEpoch: CFTimeInterval = CACurrentMediaTime()
    private var lastUpdateTime: CFTimeInterval = CACurrentMediaTime()
    private var themeMenuItems: [V14Theme: NSMenuItem] = [:]
    private var dockMenuItems: [BannerDockEdge: NSMenuItem] = [:]

    init(initialTheme: V14Theme) {
        self.theme = initialTheme
        self.themeWeights = initialTheme.weights
        super.init()
    }

    func attach(to probe: Probe, menu: NSMenu) {
        self.probe = probe
        applyPresentation(snapWeights: true)
        triggerShockwave()

        probe.onDockChanged = { [weak self] _ in
            self?.triggerShockwave()
            self?.syncMenus()
        }
        probe.bannerView.onBannerClicked = { [weak self] in
            guard let self else { return }
            let all = V14Theme.allCases
            let next = all[((all.firstIndex(of: self.theme) ?? 0) + 1) % all.count]
            self.setTheme(next)
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "光谱主题（轻点胶囊切换并脉冲）", action: nil, keyEquivalent: "")
        let keys = ["1", "2", "3", "4"]
        for (i, t) in V14Theme.allCases.enumerated() {
            let item = NSMenuItem(title: t.title, action: #selector(selectTheme(_:)), keyEquivalent: keys[i])
            item.tag = i
            item.target = self
            themeMenuItems[t] = item
            menu.addItem(item)
        }

        let pulseItem = NSMenuItem(title: "发射量子脉冲波", action: #selector(firePulseMenu), keyEquivalent: "p")
        pulseItem.target = self
        menu.addItem(pulseItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "停靠位置（拖拽胶囊吸附四边）", action: nil, keyEquivalent: "")
        for (i, edge) in BannerDockEdge.allCases.enumerated() {
            let item = NSMenuItem(title: edge.title, action: #selector(selectDock(_:)), keyEquivalent: "")
            item.tag = i
            item.target = self
            dockMenuItems[edge] = item
            menu.addItem(item)
        }
        syncMenus()
    }

    @objc private func selectTheme(_ sender: NSMenuItem) {
        let all = V14Theme.allCases
        guard sender.tag >= 0, sender.tag < all.count else { return }
        setTheme(all[sender.tag])
    }

    @objc private func selectDock(_ sender: NSMenuItem) {
        let edges = BannerDockEdge.allCases
        guard sender.tag >= 0, sender.tag < edges.count, let probe else { return }
        probe.setDockEdge(edges[sender.tag])
        syncMenus()
    }

    @objc private func firePulseMenu() {
        triggerShockwave()
    }

    func setTheme(_ newTheme: V14Theme) {
        theme = newTheme
        applyPresentation(snapWeights: false)
        triggerShockwave()
        syncMenus()
        log("THEME value=\(newTheme.rawValue)")
    }

    func triggerShockwave() {
        shockEpoch = CACurrentMediaTime()
    }

    private func applyPresentation(snapWeights: Bool) {
        if snapWeights {
            themeWeights = theme.weights
        }
        probe?.bannerView.applySemanticAppearance(
            subtitle: "V14 \(theme.title) · 轻点切色并脉冲 · 拖拽吸附四边",
            status: "全息远程接管中",
            compact: theme.compactLabel,
            accentColor: theme.accentColor,
            tintColor: theme.tintColor
        )
    }

    private func syncMenus() {
        for (t, item) in themeMenuItems {
            item.state = (t == theme) ? .on : .off
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

        themeWeights += (theme.weights - themeWeights) * min(1.0, dt * 4.8)

        let dragTarget: Float = (probe?.isDraggingBanner == true) ? 1.0 : 0.0
        let dragRate: Float = dragTarget > dragVisibility ? 14.0 : 6.0
        dragVisibility += (dragTarget - dragVisibility) * min(1.0, dt * dragRate)

        let shockAge = Float(max(0.0, now - shockEpoch))
        u.activity = min(shockAge, 99.0)
        u.param0 = dragVisibility
        u.custom = themeWeights
    }
}

private let v14FragmentShader = """
static float3 v14PaletteColor(float s, float4 w, float dark) {
    // 0: Cyber Prism
    float3 cPrism = linearRamp5(
        s,
        float3(0.08, 0.94, 1.00),
        float3(0.24, 0.46, 1.00),
        float3(0.74, 0.28, 1.00),
        float3(1.00, 0.30, 0.70),
        float3(0.08, 0.94, 1.00)
    );
    // 1: Overdrive Violet
    float3 cViolet = linearRamp5(
        s,
        float3(0.60, 0.22, 1.00),
        float3(1.00, 0.20, 0.74),
        float3(0.70, 0.72, 1.00),
        float3(0.22, 0.94, 1.00),
        float3(0.60, 0.22, 1.00)
    );
    // 2: Solar Quantum
    float3 cSolar = linearRamp5(
        s,
        float3(1.00, 0.36, 0.24),
        float3(1.00, 0.78, 0.20),
        float3(1.00, 0.24, 0.66),
        float3(0.56, 0.34, 1.00),
        float3(1.00, 0.36, 0.24)
    );
    // 3: Matrix Emerald
    float3 cEmerald = linearRamp5(
        s,
        float3(0.14, 1.00, 0.66),
        float3(0.08, 0.86, 0.96),
        float3(0.18, 0.54, 1.00),
        float3(0.52, 1.00, 0.38),
        float3(0.14, 1.00, 0.66)
    );
    float3 col = cPrism * w.x + cViolet * w.y + cSolar * w.z + cEmerald * w.w;
    return mix(col * 0.94, min(col * 1.06, float3(1.0)), dark);
}

fragment half4 overlayFragment(VOut in [[stage_in]], constant Uniforms &U [[buffer(0)]]) {
    float2 p = in.position.xy / max(U.scale, 1.0);
    float2 padOrigin = U.cursor;
    float2 targetSize = max(U.clickOrigin, float2(1.0));
    float padMax = max(U.clickAge, 16.0);
    float2 tp = p - padOrigin;

    float dIn = insideDistance(tp, targetSize, U.radius);
    float dOut = -dIn;
    // Target window stays 100% ABOVE overlay; zero pixels rendered inside window bounds.
    if (dOut < -1.0 || dOut >= padMax - 0.5) { return half4(0.0); }

    float dark = U.dark;
    float intense = U.intensity;
    float presence = clamp(U.presence, 0.0, 1.0);
    float4 themeW = U.custom;
    float dragVis = clamp(U.param0, 0.0, 1.0);
    float shockAge = U.activity;
    float dEdge = max(dOut, 0.0);

    float edgeStart = smoothstep(-0.8, 0.45, dOut);
    float outerFade = 1.0 - smoothstep(padMax * 0.48, padMax - 2.0, dOut);
    float bottomShadowComp = 1.0 + 0.38 * smoothstep(targetSize.y - 105.0, targetSize.y, tp.y);

    float theta = perimeterAngle(tp, targetSize);
    float sBase = fract(theta / (M_PI_F * 2.0) + 0.5 - U.time * 0.085);
    float3 baseCol = v14PaletteColor(sBase, themeW, dark);

    // 1. Harmonic Undulating Plasma-Aurora Waves radiating up to ~36 pt outward.
    float w1 = sin(theta * 5.0 - U.time * 2.1);
    float w2 = sin(theta * 9.0 + U.time * 3.1 + 1.4);
    float w3 = cos(theta * 14.0 - U.time * 4.3);
    float waveAmp = clamp(0.56 + 0.24 * w1 + 0.14 * w2 + 0.08 * w3, 0.08, 1.15);
    float plasmaReach = 10.5 + 17.5 * waveAmp;
    float plasmaBody = exp(-dEdge / plasmaReach) * (0.28 + 0.26 * waveAmp);
    float rays = pow(0.5 + 0.5 * sin(theta * 46.0 + U.time * 2.4 + dEdge * 0.07), 3.0);
    float plasmaRays = rays * exp(-dEdge / (plasmaReach * 0.82)) * 0.16;

    // 2. High-Voltage Neon Bevel Lip + Outer Chromatic Collar.
    float rimCore = exp(-pow(max(dEdge - 0.45, 0.0) / 1.15, 2.0));
    float rimCollar = exp(-pow(dEdge / 2.8, 1.55));
    float rimAlpha = (rimCore * 0.72 + rimCollar * 0.62) * bottomShadowComp;

    // 3. Faceted Chromatic Prism Splits at all 4 R=22 corners.
    float dxEdge = min(tp.x, targetSize.x - tp.x);
    float dyEdge = min(tp.y, targetSize.y - tp.y);
    float cornerZone = smoothstep(58.0, 22.0, dxEdge) * smoothstep(58.0, 22.0, dyEdge);
    float prismA = cornerZone * exp(-pow((dOut - 2.2) / 1.0, 2.0));
    float prismB = cornerZone * exp(-pow((dOut - 5.2) / 1.1, 2.0));
    float prismC = cornerZone * exp(-pow((dOut - 8.2) / 1.2, 2.0));
    float3 prismACol = v14PaletteColor(fract(sBase + 0.18), themeW, dark);
    float3 prismCCol = v14PaletteColor(fract(sBase + 0.52), themeW, dark);

    // 4. Six Staggered Orbital Fiber-Optic Photon Streaks.
    float photonAlpha = 0.0;
    float3 photonRGB = float3(0.0);
    for (int k = 0; k < 6; ++k) {
        float fk = float(k);
        float dir = (k % 2 == 0) ? 1.0 : -1.0;
        float spd = (1.15 + 0.24 * fk) * dir;
        float posA = U.time * spd + fk * 1.0472;
        float trail = fmod((posA - theta) * dir + M_PI_F * 4.0, M_PI_F * 2.0);
        float streak = exp(-trail * 5.2) * smoothstep(M_PI_F * 2.0, M_PI_F * 2.0 - 0.10, trail);
        float head = exp(-pow(wrapAngleDelta(theta, posA) / 0.075, 2.0));
        float rad = exp(-dEdge / 4.2) * 0.78 + exp(-dEdge / 13.0) * 0.28;
        float contrib = (head * 0.95 + streak * 0.62) * rad;
        float3 pCol = mix(v14PaletteColor(fract(sBase + fk * 0.16), themeW, dark), float3(1.0), head * 0.42);
        photonAlpha += contrib;
        photonRGB += pCol * contrib;
    }

    // 5. Interactive Telemetry Shockwave radiating from Banner Anchor.
    float shockAlpha = 0.0;
    float3 shockCol = float3(0.88, 0.98, 1.00);
    float2 bLocalCenter = U.bannerRect.xy + U.bannerRect.zw * 0.5 - padOrigin;
    float hasBanner = step(2.0, U.bannerRect.z);
    if (shockAge < 1.5) {
        float tS = shockAge;
        float env = (1.0 - smoothstep(0.55, 1.45, tS)) * smoothstep(0.0, 0.05, tS);
        float rFront = tS * 38.0;
        float radialWave = exp(-pow((dEdge - rFront) / 5.2, 2.0));
        float anchorTheta = hasBanner > 0.5 ? perimeterAngle(bLocalCenter, targetSize) : -M_PI_F * 0.5;
        float arcDelta = wrapAngleDelta(theta, anchorTheta);
        float arcWave = exp(-pow((arcDelta - tS * 3.4) / 0.32, 2.0)) * exp(-dEdge / 14.0);
        shockAlpha = env * (radialWave * 0.48 + arcWave * 0.95);
        shockCol = mix(baseCol, float3(0.95, 0.99, 1.00), 0.55);
    }

    // 6. Exterior MagSafe 4-Edge Snap Rails while dragging.
    float railAlpha = 0.0;
    float3 railColor = float3(0.42, 0.96, 1.00);
    if (dragVis > 0.004) {
        float hSlotW = clamp(targetSize.x * 0.28, 60.0, 124.0) * 0.5;
        float vSlotH = clamp(targetSize.y * 0.22, 48.0, 100.0) * 0.5;
        float cx = clamp(bLocalCenter.x, 86.0 + 48.0, max(140.0, targetSize.x - 62.0));
        float bx = clamp(bLocalCenter.x, 62.0, max(100.0, targetSize.x - 62.0));
        float sy = clamp(bLocalCenter.y, 82.0, max(120.0, targetSize.y - 62.0));

        float dTopRail = roundedBoxSDF(tp, float2(cx, -8.5), float2(hSlotW, 3.2), 3.2);
        float dBotRail = roundedBoxSDF(tp, float2(bx, targetSize.y + 8.5), float2(hSlotW, 3.2), 3.2);
        float dLeftRail = roundedBoxSDF(tp, float2(-8.5, sy), float2(3.2, vSlotH), 3.2);
        float dRightRail = roundedBoxSDF(tp, float2(targetSize.x + 8.5, sy), float2(3.2, vSlotH), 3.2);

        float gTop = exp(-max(dTopRail, 0.0) / 4.0);
        float gBot = exp(-max(dBotRail, 0.0) / 4.0);
        float gLeft = exp(-max(dLeftRail, 0.0) / 4.0);
        float gRight = exp(-max(dRightRail, 0.0) / 4.0);

        float dTopDist = max(0.0, bLocalCenter.y);
        float dBotDist = max(0.0, targetSize.y - bLocalCenter.y);
        float dLeftDist = max(0.0, bLocalCenter.x);
        float dRightDist = max(0.0, targetSize.x - bLocalCenter.x);
        float dMin = min(min(dTopDist, dBotDist), min(dLeftDist, dRightDist));
        float4 nearMask = float4(
            step(dTopDist, dMin + 0.5),
            step(dBotDist, dMin + 0.5) * (1.0 - step(dTopDist, dMin + 0.5)),
            step(dLeftDist, dMin + 0.5) * (1.0 - step(dTopDist, dMin + 0.5)) * (1.0 - step(dBotDist, dMin + 0.5)),
            0.0
        );
        nearMask.w = max(0.0, 1.0 - nearMask.x - nearMask.y - nearMask.z);

        float baseRails = max(max(gTop, gBot), max(gLeft, gRight)) * 0.42;
        float snapRail = gTop * nearMask.x + gBot * nearMask.y + gLeft * nearMask.z + gRight * nearMask.w;
        railAlpha = dragVis * (baseRails + snapRail * 0.72);
        railColor = mix(baseCol, float3(0.92, 0.99, 1.00), clamp(snapRail * 0.75, 0.0, 1.0));
    }

    float waveAlpha = (plasmaBody + plasmaRays) * bottomShadowComp;
    float cornerAlphaA = prismA * 0.65 * bottomShadowComp;
    float cornerAlphaB = prismB * 0.70 * bottomShadowComp;
    float cornerAlphaC = prismC * 0.55 * bottomShadowComp;
    float photonScaled = photonAlpha * 0.58 * bottomShadowComp;
    float shockScaled = shockAlpha * bottomShadowComp;

    float mask = edgeStart * outerFade;
    float rawAlpha = (rimAlpha + waveAlpha + cornerAlphaA + cornerAlphaB + cornerAlphaC + photonScaled + shockScaled + railAlpha) * mask;

    float3 rgb = (baseCol * (rimAlpha + waveAlpha + cornerAlphaB)
                + prismACol * cornerAlphaA
                + prismCCol * cornerAlphaC
                + photonRGB * (0.58 * bottomShadowComp)
                + shockCol * shockScaled
                + railColor * railAlpha) * mask;

    float alpha = clamp(rawAlpha * intense * presence, 0.0, 0.98);
    float3 outRGB = (rawAlpha > 1e-5) ? (rgb / rawAlpha) * alpha : float3(0.0);
    return half4(half3(outRGB), half(alpha));
}
"""

@main
struct V14ProbeEntry {
    static func main() {
        let args = CommandLine.arguments
        func option(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }

        let startTheme = option("--theme").flatMap(V14Theme.init(rawValue:)) ?? .prism
        if option("--theme") != nil && V14Theme(rawValue: option("--theme")!) == nil {
            fputs("--theme must be prism, violet, solar, or emerald.\n", stderr)
            exit(1)
        }
        let startDock = option("--dock").flatMap(BannerDockEdge.init(rawValue:)) ?? .bottom
        if option("--dock") != nil && BannerDockEdge(rawValue: option("--dock")!) == nil {
            fputs("--dock must be top, bottom, left, or right.\n", stderr)
            exit(1)
        }
        let dockRatio = option("--dock-ratio").flatMap(Double.init).map { CGFloat(min(1.0, max(0.0, $0))) } ?? 0.5
        let alwaysExpanded = args.contains("--always-expanded")

        let controller = V14Controller(initialTheme: startTheme)
        V14Controller.current = controller

        let effect = ProbeEffect(
            versionTag: "V14",
            subtitleTag: "V14 量子棱镜全息极光 · 轻点切色脉冲",
            shaderFragmentSource: v14FragmentShader,
            bannerMode: alwaysExpanded ? .standard : .smartCollapsible(startCollapsed: true, autoCollapseDelay: 2.2),
            outerPadding: 44,
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
            extraUsage: "[--theme prism|violet|solar|emerald] [--dock top|bottom|left|right] [--dock-ratio 0..1] [--always-expanded]"
        )
    }
}
