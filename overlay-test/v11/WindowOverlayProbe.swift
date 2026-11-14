import AppKit

// V11: Live Connection States — smooth multi-state semantic morphing between
// 0: Streaming Live (cyan-blue/mint steady aura),
// 1: Paused (calm static warm amber seal),
// 2: Reconnecting (dual fast cyan/coral radar search arcs), and
// 3: Privacy Shield (deep indigo-crimson diagonal security veil).

enum ConnectionState: Int, CaseIterable {
    case live = 0
    case paused = 1
    case reconnecting = 2
    case privacy = 3

    var cliName: String {
        switch self {
        case .live: return "live"
        case .paused: return "paused"
        case .reconnecting: return "reconnecting"
        case .privacy: return "privacy"
        }
    }

    init?(cliValue: String) {
        guard let matched = Self.allCases.first(where: { $0.cliName == cliValue }) else { return nil }
        self = matched
    }

    var menuTitle: String {
        switch self {
        case .live: return "状态：正常推流中 (Live)"
        case .paused: return "状态：临时暂停中 (Paused)"
        case .reconnecting: return "状态：网络重连中 (Reconnecting)"
        case .privacy: return "状态：隐私保护盾 (Privacy Shield)"
        }
    }

    var subtitleText: String {
        switch self {
        case .live: return "正常推流 · 点胶囊切换下个状态"
        case .paused: return "已暂停输入与推流 · 点胶囊继续"
        case .reconnecting: return "信号波动重连握手中 · 点胶囊切换"
        case .privacy: return "隐私脱敏掩蔽 · 远端画面受保护"
        }
    }

    var expandedStatusText: String {
        switch self {
        case .live: return "推流受控中"
        case .paused: return "已暂停控制"
        case .reconnecting: return "重连握手中"
        case .privacy: return "隐私保护中"
        }
    }

    var compactStatusText: String {
        switch self {
        case .live: return "远程控制中"
        case .paused: return "暂停控制中"
        case .reconnecting: return "重连握手中"
        case .privacy: return "隐私保护中"
        }
    }

    var accentColor: NSColor {
        switch self {
        case .live: return NSColor(srgbRed: 0.48, green: 0.88, blue: 1.00, alpha: 1)
        case .paused: return NSColor(srgbRed: 1.00, green: 0.78, blue: 0.34, alpha: 1)
        case .reconnecting: return NSColor(srgbRed: 1.00, green: 0.56, blue: 0.36, alpha: 1)
        case .privacy: return NSColor(srgbRed: 0.96, green: 0.54, blue: 0.94, alpha: 1)
        }
    }

    var tintColor: NSColor {
        switch self {
        case .live: return NSColor(srgbRed: 0.125, green: 0.155, blue: 0.195, alpha: 1)
        case .paused: return NSColor(srgbRed: 0.215, green: 0.160, blue: 0.085, alpha: 1)
        case .reconnecting: return NSColor(srgbRed: 0.125, green: 0.165, blue: 0.235, alpha: 1)
        case .privacy: return NSColor(srgbRed: 0.205, green: 0.105, blue: 0.235, alpha: 1)
        }
    }
}

final class V11StateController: NSObject {
    weak var probe: Probe?
    var state: ConnectionState = .live
    var autoCycle = false
    var weights = SIMD4<Float>(1, 0, 0, 0)
    var stateItems: [ConnectionState: NSMenuItem] = [:]
    weak var cycleItem: NSMenuItem?
    private var cycleElapsed: TimeInterval = 0
    private let cycleInterval: TimeInterval = 4.5

    func setState(_ next: ConnectionState, stopAutoCycle: Bool = true) {
        if stopAutoCycle { autoCycle = false }
        state = next
        cycleElapsed = 0
        applyBannerUI()
        syncMenu()
        log("STATE \(next.cliName) autoCycle=\(autoCycle)")
    }

    @objc func selectStateMenu(_ sender: NSMenuItem) {
        guard let next = ConnectionState(rawValue: sender.tag) else { return }
        setState(next, stopAutoCycle: true)
    }

    @objc func toggleAutoCycle() {
        autoCycle.toggle()
        cycleElapsed = 0
        syncMenu()
        log("AUTOCYCLE \(autoCycle)")
    }

    @objc func toggleFoldState() {
        guard let probe else { return }
        let collapsed = probe.bannerView.foldProgress < 0.5
        probe.forceBannerFolded(!collapsed)
    }

    func advanceFromBannerClick() {
        let nextRaw = (state.rawValue + 1) % ConnectionState.allCases.count
        setState(ConnectionState(rawValue: nextRaw)!, stopAutoCycle: true)
    }

    func applyBannerUI() {
        probe?.bannerView.applySemanticAppearance(
            subtitle: state.subtitleText,
            status: state.expandedStatusText,
            compact: state.compactStatusText,
            accentColor: state.accentColor,
            tintColor: state.tintColor
        )
    }

    func syncMenu() {
        for (s, item) in stateItems { item.state = (s == state) ? .on : .off }
        cycleItem?.state = autoCycle ? .on : .off
    }

    func step(dt: TimeInterval) -> SIMD4<Float> {
        if autoCycle {
            cycleElapsed += dt
            if cycleElapsed >= cycleInterval {
                let nextRaw = (state.rawValue + 1) % ConnectionState.allCases.count
                setState(ConnectionState(rawValue: nextRaw)!, stopAutoCycle: false)
            }
        }
        let target = SIMD4<Float>(
            state == .live ? 1 : 0,
            state == .paused ? 1 : 0,
            state == .reconnecting ? 1 : 0,
            state == .privacy ? 1 : 0
        )
        let alpha = min(1.0, Float(dt) * 5.2)
        weights += (target - weights) * alpha
        return weights
    }
}

private let v11Controller = V11StateController()

let v11ShaderFragment = """
fragment float4 overlayFragment(VOut in [[stage_in]], constant Uniforms& U [[buffer(0)]]) {
    float2 size = U.size;
    float2 p = in.position.xy / max(U.scale, 1.0);
    float d = insideDistance(p, size, U.radius);
    float coverage = clamp(d * U.scale + 0.5, 0.0, 1.0);
    if (coverage <= 0.0 || U.presence <= 0.0) { return float4(0.0); }

    float t = U.time;
    float k = clamp(U.intensity, 0.4, 1.8);
    float styleT = clamp((k - 0.75) / 0.57, 0.0, 1.0);
    float2 uv = p / size;
    float ang = perimeterAngle(p, size);

    // Smoothed live semantic weights: x=Live, y=Paused, z=Reconnecting, w=Privacy
    float4 sw = max(U.custom, float4(0.0));
    float sumW = max(sw.x + sw.y + sw.z + sw.w, 1e-4);
    sw /= sumW;

    // Collapsible pill avoidance so HUD text stays crisp in every state
    float4 br = U.bannerRect;
    float hasBanner = step(10.0, br.z);
    float fold = clamp(U.bannerFold, 0.0, 1.0);
    float2 bCenter = br.xy + br.zw * 0.5;
    float2 bHalf = max(br.zw * 0.5, float2(1.0));
    float bRadius = mix(16.0, 20.0, fold);
    float sdBanner = roundedBoxSDF(p, bCenter, bHalf, min(bRadius, min(bHalf.x, bHalf.y)));
    float behindSuppression = hasBanner * (1.0 - smoothstep(-2.0, 14.0, sdBanner));

    float edgeSpan = clamp(min(size.x, size.y) * 0.16, 36.0, 112.0);
    float edgeW = smoothEdgeProximity(p, size, edgeSpan);
    float tightRim = exp(-pow(max(d - 1.4, 0.0) / mix(1.3, 1.9, styleT), 2.0));

    // ----- State 0: Streaming Live (cyan / cobalt / mint calm aurora) -----
    float liveWave = fract(ang / (2.0 * M_PI_F) + 0.5 - t * 0.075);
    float3 liveColLight = mix(
        mix(float3(0.00, 0.68, 0.90), float3(0.14, 0.46, 0.98), smoothstep(0.0, 0.5, liveWave)),
        float3(0.08, 0.80, 0.66),
        smoothstep(0.5, 1.0, liveWave)
    );
    float3 liveColDark = mix(liveColLight, float3(0.45, 0.92, 1.00), 0.35);
    float3 liveCol = mix(liveColLight, liveColDark, U.dark);
    float liveBreath = 0.82 + 0.18 * sin(t * 1.55);
    float liveEdgeA = pow(edgeW, 1.45) * mix(0.42, 0.72, styleT) * liveBreath + tightRim * mix(0.48, 0.82, styleT);
    float liveCenterA = mix(0.015, 0.032, styleT);

    // ----- State 1: Paused (calm warm amber frosted border hold) -----
    float pauseSigh = 0.86 + 0.14 * sin(t * 0.80);
    float amberGrad = 0.5 + 0.5 * sin(uv.x * 2.4 + uv.y * 1.8);
    float3 pausedColLight = mix(float3(0.94, 0.52, 0.06), float3(0.98, 0.70, 0.16), amberGrad);
    float3 pausedColDark  = mix(float3(1.00, 0.64, 0.18), float3(1.00, 0.82, 0.34), amberGrad);
    float3 pausedCol = mix(pausedColLight, pausedColDark, U.dark);
    // Noticeably thicker static bevel border visually signals "frozen / paused"
    float pausedRim = exp(-pow(max(d - 2.0, 0.0) / mix(2.1, 3.0, styleT), 2.0));
    float pausedEdgeA = pow(edgeW, 1.15) * mix(0.52, 0.82, styleT) * pauseSigh + pausedRim * mix(0.62, 0.92, styleT);
    float pausedCenterA = mix(0.045, 0.095, styleT) * pauseSigh;

    // ----- State 2: Reconnecting (dual fast cyan/coral radar search arcs) -----
    float arc1 = pow(max(0.5 + 0.5 * cos(ang - t * 3.4), 0.0), 4.5);
    float arc2 = pow(max(0.5 + 0.5 * cos(ang - t * 3.4 + M_PI_F), 0.0), 4.5);
    float sonarReach = max(edgeSpan * 0.36, 12.0);
    float sonar = pow(max(sin(d * 0.11 - t * 4.6), 0.0), 3.0)
                * exp(-d / sonarReach)
                * (1.0 - smoothstep(edgeSpan * 0.45, edgeSpan * 0.85, d));
    float3 reconCyan  = mix(float3(0.00, 0.72, 0.96), float3(0.28, 0.90, 1.00), U.dark);
    float3 reconCoral = mix(float3(0.98, 0.34, 0.14), float3(1.00, 0.52, 0.28), U.dark);
    float3 reconCol = mix(reconCyan, reconCoral, clamp(arc2 * 1.15 + arc1 * 0.25, 0.0, 1.0));
    float reconSweep = clamp(arc1 + arc2 * 0.95, 0.0, 1.25);
    float reconEdgeA = pow(edgeW, 1.35) * mix(0.32, 0.60, styleT)
                     + (reconSweep * smoothEdgeProximity(p, size, edgeSpan * 0.55) + sonar * 0.55) * mix(0.42, 0.80, styleT)
                     + tightRim * (0.45 + 0.60 * reconSweep) * mix(0.55, 0.92, styleT);
    float reconCenterA = mix(0.020, 0.045, styleT);

    // ----- State 3: Privacy Shield (deep indigo-crimson diagonal encrypted curtain) -----
    float3 privColLight = mix(float3(0.46, 0.16, 0.90), float3(0.88, 0.16, 0.48), 0.5 + 0.5 * sin(uv.x * 3.1 - uv.y * 2.6 + t * 0.5));
    float3 privColDark  = mix(float3(0.62, 0.34, 1.00), float3(1.00, 0.36, 0.66), 0.5 + 0.5 * sin(uv.x * 3.1 - uv.y * 2.6 + t * 0.5));
    float3 privCol = mix(privColLight, privColDark, U.dark);
    // Encrypted 45-deg security micro-weave across entire interior
    float stripeA = 0.5 + 0.5 * sin((p.x + p.y) * 0.48 - t * 1.35);
    float stripeB = 0.5 + 0.5 * sin((p.x - p.y) * 0.48 + t * 0.90);
    float weave = 0.65 + 0.35 * (stripeA * 0.70 + stripeB * 0.30);
    float privEdgeA = pow(edgeW, 1.20) * mix(0.58, 0.88, styleT) + tightRim * mix(0.65, 0.95, styleT);
    float privCenterA = mix(0.18, 0.36, styleT) * weave;

    // Blend color & edge/center alphas smoothly across active state weights
    float3 baseTint = liveCol * sw.x + pausedCol * sw.y + reconCol * sw.z + privCol * sw.w;
    float edgeA = liveEdgeA * sw.x + pausedEdgeA * sw.y + reconEdgeA * sw.z + privEdgeA * sw.w;
    float centerA = liveCenterA * sw.x + pausedCenterA * sw.y + reconCenterA * sw.z + privCenterA * sw.w;
    centerA *= (1.0 - 0.75 * behindSuppression);

    // Pill anchor aura synced to current state hue
    float haloSpread = mix(22.0, 36.0, fold);
    float anchorHalo = hasBanner * smoothstep(-3.0, 3.0, sdBanner) * exp(-max(sdBanner, 0.0) / haloSpread) * mix(0.24, 0.36, fold) * k;
    float haloRimCatch = hasBanner * exp(-pow(abs(sdBanner - 1.8) / 3.0, 2.0)) * mix(0.20, 0.32, fold);

    float washA = clamp(max(centerA, edgeA) + anchorHalo + haloRimCatch, 0.0, 0.92);
    float3 rimSpecular = mix(baseTint, float3(1.0), clamp(tightRim * (0.28 + 0.25 * sw.z) + haloRimCatch * 0.7, 0.0, 0.65));
    float3 col = rimSpecular * washA;

    // Subtle crisp peripheral dot shimmer (accentuated in Live & Reconnecting, muted in Paused)
    const float spacing = 9.0;
    float2 cell = floor(p / spacing);
    float2 f = (fract(p / spacing) - 0.5) * spacing;
    float r2 = dot(f, f);
    float dotKernel = exp(-r2 / (2.0 * 0.44 * 0.44));
    float speedMul = 1.0 * sw.x + 0.2 * sw.y + 2.2 * sw.z + 0.8 * sw.w;
    float ph = fract(t * (0.35 * speedMul + 0.15) + hash21(cell + 17.3) * 19.0);
    float gate = hash21(cell + floor(t * 0.5 + 1.0) * 3.17);
    float spark = (gate > 0.945 ? 1.0 : 0.0) * smoothstep(0.0, 0.15, ph) * (1.0 - smoothstep(0.15, 0.55, ph));
    float dotPresence = (0.25 * edgeW + 0.75 * spark * max(edgeW, 0.15)) * (1.0 - behindSuppression * 0.90)
                      * clamp(sw.x + 0.15 * sw.y + 1.25 * sw.z + 0.60 * sw.w, 0.0, 1.3);
    float dotA = clamp(dotKernel * dotPresence * mix(0.45, 0.85, styleT), 0.0, 0.85);

    col = float3(1.0) * dotA + col * (1.0 - dotA);
    float a = dotA + washA * (1.0 - dotA);

    float grain = (hash21(in.position.xy) - 0.5) * (1.5 / 255.0);
    col = clamp(col + grain * a, 0.0, a);
    return float4(col, a) * (coverage * U.presence);
}
"""

@main
enum V11ProbeEntry {
    static func main() {
        let args = CommandLine.arguments
        func option(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }

        let startCollapsed = args.contains("--collapsed")
        let alwaysExpanded = args.contains("--always-expanded")
        let cycle = args.contains("--cycle")
        let initialState: ConnectionState
        if let rawState = option("--state") {
            guard let parsed = ConnectionState(cliValue: rawState) else {
                fputs("--state must be live, paused, reconnecting, or privacy.\n", stderr)
                exit(1)
            }
            initialState = parsed
        } else {
            initialState = .live
        }

        v11Controller.state = initialState
        v11Controller.autoCycle = cycle
        v11Controller.weights = SIMD4<Float>(
            initialState == .live ? 1 : 0,
            initialState == .paused ? 1 : 0,
            initialState == .reconnecting ? 1 : 0,
            initialState == .privacy ? 1 : 0
        )

        let effect = ProbeEffect(
            versionTag: "V11",
            subtitleTag: initialState.subtitleText,
            shaderFragmentSource: v11ShaderFragment,
            bannerMode: .smartCollapsible(
                startCollapsed: startCollapsed,
                autoCollapseDelay: alwaysExpanded ? 86400 : 4.0
            ),
            updateUniforms: { uniforms, _, step, _ in
                uniforms.custom = v11Controller.step(dt: step)
                uniforms.param0 = Float(v11Controller.state.rawValue)
            },
            setupExtraMenuItems: { menu, probe in
                v11Controller.probe = probe
                if alwaysExpanded {
                    probe.setBannerPinned(true)
                }
                v11Controller.applyBannerUI()
                probe.bannerView.onBannerClicked = {
                    v11Controller.advanceFromBannerClick()
                }
                menu.addItem(.separator())
                for candidate in ConnectionState.allCases {
                    let item = NSMenuItem(
                        title: candidate.menuTitle,
                        action: #selector(V11StateController.selectStateMenu(_:)),
                        keyEquivalent: "\(candidate.rawValue + 1)"
                    )
                    item.tag = candidate.rawValue
                    item.target = v11Controller
                    v11Controller.stateItems[candidate] = item
                    menu.addItem(item)
                }
                let cycleMenu = NSMenuItem(
                    title: "四态自动轮播 (每 4.5 秒)",
                    action: #selector(V11StateController.toggleAutoCycle),
                    keyEquivalent: ""
                )
                cycleMenu.target = v11Controller
                v11Controller.cycleItem = cycleMenu
                menu.addItem(cycleMenu)
                let foldMenu = NSMenuItem(
                    title: "展开 / 折叠控制条",
                    action: #selector(V11StateController.toggleFoldState),
                    keyEquivalent: "f"
                )
                foldMenu.target = v11Controller
                menu.addItem(foldMenu)
                v11Controller.syncMenu()
            }
        )

        runProbeMain(effect: effect, extraUsage: "[--state live|paused|reconnecting|privacy] [--cycle] [--collapsed | --always-expanded]")
    }
}
