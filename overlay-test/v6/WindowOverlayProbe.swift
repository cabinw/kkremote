import AppKit

// V6: Smart Collapsible Control Pill + Aura-Linked Overlay.
// Auto-folds into an unobtrusive 112x32 mini-pill after idle delay (expanding smoothly on hover)
// while the overlay shader dynamically anchors a soft luminous aura around the live pill bounds.

private let v6FragmentShader = """
static float3 v6Spectrum(float s, float darkMode) {
    float3 lightC = linearRamp5(s,
        float3(0.46, 0.64, 1.00),
        float3(0.72, 0.48, 1.00),
        float3(1.00, 0.46, 0.80),
        float3(1.00, 0.58, 0.38),
        float3(1.00, 0.82, 0.42));
    float3 darkC = linearRamp5(s,
        float3(0.42, 0.64, 1.00),
        float3(0.70, 0.42, 1.00),
        float3(1.00, 0.42, 0.78),
        float3(1.00, 0.52, 0.36),
        float3(1.00, 0.82, 0.34));
    return mix(lightC, darkC, darkMode);
}

fragment float4 overlayFragment(VOut in [[stage_in]], constant Uniforms& U [[buffer(0)]]) {
    float2 size = U.size;
    float2 p = in.position.xy / U.scale;
    float t = U.time;
    float d = insideDistance(p, size, U.radius);
    float coverage = clamp(d * U.scale + 0.5, 0.0, 1.0);
    if (coverage <= 0.0 || U.presence <= 0.0) { return float4(0.0); }

    float k = U.intensity;
    float2 uv = p / size;
    float edgeWidth = clamp(min(size.x, size.y) * 0.15, 30.0, 108.0);
    float edge = smoothEdgeProximity(p, size, edgeWidth);
    float rim = smoothEdgeProximity(p, size, edgeWidth * 0.38);

    float theta = t * 0.68;
    float2 dir = float2(cos(theta), sin(theta));
    float2 ortho = float2(-dir.y, dir.x);
    float2 pNorm = (uv - 0.5) * 2.0;
    float s = clamp(0.50 + 0.38 * dot(pNorm, dir) + 0.05 * sin(dot(pNorm, ortho) * 1.6 - t * 0.8), 0.0, 1.0);
    float3 color = v6Spectrum(s, U.dark);

    float ang = perimeterAngle(p, size);
    float arc = pow(max(0.5 + 0.5 * cos(2.0 * (ang - t * 0.88)), 0.0), 2.8);
    float hairline = exp(-pow(max(d - 1.35, 0.0) / 1.45, 2.0));

    // Live banner capsule distance field (in window top-left points).
    float4 br = U.bannerRect;
    float hasBanner = step(10.0, br.z);
    float fold = clamp(U.bannerFold, 0.0, 1.0);
    float2 bCenter = br.xy + br.zw * 0.5;
    float2 bHalf = max(br.zw * 0.5, float2(1.0));
    float bRadius = mix(17.0, 20.0, fold);
    float sdBanner = roundedBoxSDF(p, bCenter, bHalf, min(bRadius, min(bHalf.x, bHalf.y)));

    // 1) Soft clearing immediately behind & inside the floating pill so glass stays pristine.
    float behindSuppression = hasBanner * (1.0 - smoothstep(-2.0, 14.0, sdBanner));

    // 2) Luminous anchor halo hugging the banner contour (tighter/lighter when folded into mini-pill).
    float haloSpread = mix(22.0, 38.0, fold);
    float anchorHalo = hasBanner
                     * smoothstep(-4.0, 4.0, sdBanner)
                     * exp(-max(sdBanner, 0.0) / haloSpread)
                     * mix(0.24, 0.36, fold) * k;
    float haloRimCatch = hasBanner * exp(-pow(abs(sdBanner - 2.0) / 3.2, 2.0)) * mix(0.18, 0.28, fold);

    float centerAlpha = mix(0.032, 0.038, U.dark) * k * (1.0 - 0.65 * behindSuppression);
    float edgeAlpha = min(0.84, 0.68 * (0.72 + 0.28 * k));
    float colorAlpha = clamp(mix(centerAlpha, edgeAlpha, pow(max(edge, 0.0), 1.42))
                             + (0.16 * hairline + 0.07 * arc * rim) * k
                             + anchorHalo + haloRimCatch, 0.0, 0.90);

    float3 haloColor = min(color * 1.15 + 0.18, float3(1.0));
    float3 finalRGB = mix(color, haloColor, clamp(anchorHalo * 1.5 + haloRimCatch, 0.0, 0.85));
    float4 outc = float4(finalRGB * colorAlpha, colorAlpha);

    // Restrained perimeter shimmer dots + tiny halo sparkles around the floating pill (muted directly behind glass).
    const float spacing = 8.5;
    float2 g = p / spacing;
    float2 cell = floor(g);
    float2 f = (fract(g) - 0.5) * spacing;
    float r2 = dot(f, f);

    float seed = hash21(cell + 43.1);
    float rate = 0.28 + 0.32 * hash21(cell + 13.7);
    float phaseClock = t * rate + seed * 17.0;
    float cycle = floor(phaseClock);
    float ph = fract(phaseClock);
    float gate = hash21(cell + float2(cycle * 3.17, 11.4));
    float env = smoothstep(0.0, 0.14, ph) * (1.0 - smoothstep(0.14, 0.48, ph));
    float spark = gate > 0.945 ? env : 0.0;

    float pillSparkZone = hasBanner * exp(-max(sdBanner, 0.0) / 34.0) * smoothstep(0.0, 8.0, sdBanner);
    float edgeDots = pow(max(edge, 0.0), 1.45);
    float baseDot = (mix(0.016, 0.24, edgeDots) + 0.10 * pillSparkZone) * (1.0 - behindSuppression * 0.90);
    float twinkle = (0.85 * spark) * (0.24 + 0.76 * max(edge, pillSparkZone)) * (1.0 - behindSuppression * 0.90);

    float sigma = 0.40 + 0.34 * spark;
    float haloW = 0.06 + 0.28 * spark;
    float dotShape = exp(-r2 / (2.0 * sigma * sigma)) + haloW * exp(-r2 / (2.0 * 1.42 * 1.42));
    float dotAlpha = clamp(dotShape * (baseDot + 0.10 * arc * rim + twinkle), 0.0, 0.92);
    outc = float4(float3(dotAlpha), dotAlpha) + outc * (1.0 - dotAlpha);

    float grain = (hash21(in.position.xy) - 0.5) * (2.0 / 255.0);
    outc.rgb = clamp(outc.rgb + grain * outc.a, 0.0, outc.a);
    return outc * (coverage * U.presence);
}
"""

final class V6MenuHelper: NSObject {
    weak var probe: Probe?
    weak var collapseItem: NSMenuItem?

    init(probe: Probe) {
        self.probe = probe
    }

    @objc func toggleFoldState() {
        guard let probe else { return }
        let currentlyCollapsed = probe.bannerView.foldProgress < 0.5
        probe.forceBannerFolded(!currentlyCollapsed)
    }
}

@main
enum V6ProbeEntry {
    private static var menuHelper: V6MenuHelper?

    static func main() {
        let startCollapsed = CommandLine.arguments.contains("--collapsed")
        let alwaysExpanded = CommandLine.arguments.contains("--always-expanded")
        let autoDelay: TimeInterval = alwaysExpanded ? 999_999 : 4.0

        let effect = ProbeEffect(
            versionTag: "V6 智能联动",
            subtitleTag: "样式预览 · V6 自动折叠 + 光环联动",
            shaderFragmentSource: v6FragmentShader,
            bannerMode: .smartCollapsible(startCollapsed: startCollapsed, autoCollapseDelay: autoDelay),
            setupExtraMenuItems: { menu, probe in
                if alwaysExpanded {
                    probe.setBannerPinned(true)
                }
                let helper = V6MenuHelper(probe: probe)
                menuHelper = helper
                menu.addItem(.separator())
                let fold = NSMenuItem(title: "展开 / 折叠控制条", action: #selector(V6MenuHelper.toggleFoldState), keyEquivalent: "f")
                fold.target = helper
                helper.collapseItem = fold
                menu.addItem(fold)
            }
        )
        runProbeMain(effect: effect, extraUsage: "[--collapsed | --always-expanded]")
    }
}
