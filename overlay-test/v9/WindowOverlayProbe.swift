import Cocoa

// V9: Silk Aurora Ribbon — undulating multi-harmonic perimeter silk curtains with thin-film
// optical interference caustics sliding along crisp high-saturation edges, keeping document center untouched.
final class V9MenuHelper: NSObject {
    weak var probe: Probe?
    @objc func expandAndPin() { probe?.forceBannerFolded(false) }
    @objc func collapseNow() { probe?.forceBannerFolded(true) }
}

private let v9MenuHelper = V9MenuHelper()

let v9ShaderFragment = """
static float3 interferencePalette(float t, float dark) {
    float s = fract(t);
    // Rich high-chroma jewel stops for crisp light-mode visibility; lifted luminance in dark mode
    float3 l0 = float3(0.00, 0.64, 0.92); // Deep cyan-teal
    float3 l1 = float3(0.14, 0.36, 0.98); // Electric sapphire
    float3 l2 = float3(0.56, 0.18, 0.94); // Royal amethyst
    float3 l3 = float3(0.92, 0.18, 0.54); // Vivid orchid rose
    float3 l4 = float3(0.95, 0.44, 0.22); // Warm tangerine-coral iridescent glint

    float3 d0 = float3(0.24, 0.88, 1.00);
    float3 d1 = float3(0.38, 0.58, 1.00);
    float3 d2 = float3(0.76, 0.40, 1.00);
    float3 d3 = float3(1.00, 0.42, 0.74);
    float3 d4 = float3(1.00, 0.66, 0.38);

    // Periodic C1 seamless 5-stop wrap (6th anchor returns to stop 0 cleanly)
    float u = s * 5.0;
    float3 lightC = l0;
    lightC = mix(lightC, l1, smoothstep(0.0, 1.0, u));
    lightC = mix(lightC, l2, smoothstep(1.0, 2.0, u));
    lightC = mix(lightC, l3, smoothstep(2.0, 3.0, u));
    lightC = mix(lightC, l4, smoothstep(3.0, 4.0, u));
    lightC = mix(lightC, l0, smoothstep(4.0, 5.0, u));

    float3 darkC = d0;
    darkC = mix(darkC, d1, smoothstep(0.0, 1.0, u));
    darkC = mix(darkC, d2, smoothstep(1.0, 2.0, u));
    darkC = mix(darkC, d3, smoothstep(2.0, 3.0, u));
    darkC = mix(darkC, d4, smoothstep(3.0, 4.0, u));
    darkC = mix(darkC, d0, smoothstep(4.0, 5.0, u));

    return mix(lightC, darkC, dark);
}

fragment float4 overlayFragment(VOut in [[stage_in]], constant Uniforms& U [[buffer(0)]]) {
    float2 p = in.position.xy / max(U.scale, 1.0);
    float d = insideDistance(p, U.size, U.radius);
    if (d < -0.5) { return float4(0.0); }

    float theta = perimeterAngle(p, U.size);
    float k = clamp(U.intensity, 0.4, 1.8);
    float styleT = clamp((k - 0.75) / 0.57, 0.0, 1.0);

    // Multi-harmonic counter-drifting silk waves create fluid crescent swells around perimeter
    float waveA = sin(theta * 2.0 - U.time * 0.90);
    float waveB = sin(theta * 3.0 + U.time * 1.25);
    float waveC = cos(theta * 5.0 - U.time * 0.65);

    // Corner boost gently widens the silk folds near squircle corners
    float cornerFactor = pow(abs(sin(2.0 * theta)), 1.8);
    float reachBase = mix(14.0, 25.0, styleT) + cornerFactor * mix(5.0, 9.0, styleT);
    float ribbonReach = max(6.0, reachBase + waveA * mix(4.5, 8.5, styleT) + waveB * 3.0);

    // Zero center clutter: silk curtain decays to strict 0 past ~38 pt
    if (d > ribbonReach * 1.38 + 6.0 && U.bannerRect.z <= 1.0) { return float4(0.0); }

    // Thin-film optical path phase shifts hue subtly with depth & angle like pleated silk organza
    float filmShift = d * 0.011 + 0.065 * waveA + 0.04 * waveC;
    float basePhase = theta / (2.0 * M_PI_F) + 0.5 - U.time * 0.055 + filmShift;
    float3 silkCol = interferencePalette(basePhase, U.dark);
    float3 shiftCol = interferencePalette(basePhase + 0.16, U.dark);

    // Traveling caustic fold crests gliding across the width of the ribbon
    float foldCoord = d * 0.23 - U.time * 1.65 + theta * 2.0 + 1.2 * waveA;
    float caustic1 = pow(0.5 + 0.5 * sin(foldCoord), 4.0);
    float caustic2 = pow(0.5 + 0.5 * sin(foldCoord * 1.65 + 1.4 - theta), 5.0);
    float sheen = clamp(caustic1 * 0.75 + caustic2 * 0.55, 0.0, 1.15);

    // Layer 1: Bold crisp satin outer bezel spine (~2.5-3.8 pt thick so unmistakable on #FFFFFF)
    float edgeMask = smoothstep(-0.15, 0.35, d);
    float spineW = mix(1.35, 2.25, styleT) * (0.90 + 0.18 * (0.5 + 0.5 * waveA));
    float spine = exp(-pow((d - 1.35) / spineW, 2.0)) * edgeMask;

    // Double crisp inner pearl reflection thread (~1 pt inside main spine)
    float innerThread = exp(-pow((d - 3.6 - 1.4 * waveB) / 0.85, 2.0))
                      * smoothstep(14.0, 3.0, d) * (0.45 + 0.55 * caustic1);

    // Layer 2: Flowing translucent silk curtain depth fill (decays strictly to 0 by 1.32*ribbonReach)
    float curtain = exp(-max(d, 0.0) / max(ribbonReach * 0.52, 1.0))
                  * (1.0 - smoothstep(ribbonReach * 0.65, ribbonReach * 1.32, d))
                  * edgeMask;

    float spineAlpha = spine * mix(0.58, 0.94, styleT);
    float threadAlpha = innerThread * mix(0.24, 0.54, styleT);
    float curtainAlpha = curtain * mix(0.18, 0.44, styleT) * (0.72 + 0.38 * sheen);

    // Subtle banner aura linkage around collapsible pill
    float pillAlpha = 0.0;
    float3 pillCol = silkCol;
    if (U.bannerRect.z > 1.0 && U.bannerRect.w > 1.0) {
        float2 bCenter = U.bannerRect.xy + U.bannerRect.zw * 0.5;
        float2 bHalf = U.bannerRect.zw * 0.5;
        float bCorner = mix(16.0, 20.0, U.bannerFold);
        float dPill = roundedBoxSDF(p, bCenter, bHalf, bCorner);
        float pillRim = exp(-pow((dPill - 0.5) / 1.15, 2.0))
                      * smoothstep(-0.5, 0.2, dPill) * smoothstep(5.0, 1.0, dPill);
        float pillAura = exp(-max(dPill, 0.0) / mix(7.0, 12.0, U.bannerFold))
                       * smoothstep(-1.0, 1.0, dPill) * smoothstep(20.0, 2.0, dPill);
        float pillWave = 0.80 + 0.20 * sin(U.time * 1.7 + p.x * 0.025);
        pillAlpha = (pillRim * mix(0.38, 0.72, styleT) + pillAura * mix(0.10, 0.22, styleT)) * pillWave;
        pillCol = interferencePalette(basePhase + 0.08, U.dark);
    }

    // Iridescent specular fold sheen blends shifted complementary hue + crisp pearl highlight on crests
    float3 causticCol = mix(silkCol, shiftCol, 0.55);
    causticCol = mix(causticCol, float3(1.0), (0.28 + 0.22 * U.dark) * clamp(caustic1, 0.0, 1.0));
    float3 curtainCol = mix(silkCol, causticCol, clamp(sheen * 0.85, 0.0, 1.0));
    float3 threadCol = mix(shiftCol, float3(1.0), 0.48);
    // Keep outer bezel deeply chromatic in light mode so white chrome frames crisply
    float3 spineCol = mix(silkCol, float3(1.0), (0.14 + 0.25 * U.dark) * spine);

    float wSum = spineAlpha + threadAlpha + curtainAlpha + pillAlpha + 1e-5;
    float3 finalRGB = (spineCol * spineAlpha
                     + threadCol * threadAlpha
                     + curtainCol * curtainAlpha
                     + pillCol * pillAlpha) / wSum;

    float alpha = 1.0 - (1.0 - clamp(spineAlpha, 0.0, 0.95))
                      * (1.0 - clamp(threadAlpha, 0.0, 0.70))
                      * (1.0 - clamp(curtainAlpha, 0.0, 0.72))
                      * (1.0 - clamp(pillAlpha, 0.0, 0.80));
    alpha = clamp(alpha, 0.0, 0.95) * U.presence;
    return float4(finalRGB * alpha, alpha);
}
"""

@main
enum V9ProbeApp {
    static func main() {
        let args = CommandLine.arguments
        let startCollapsed = args.contains("--collapsed")
        let alwaysExpanded = args.contains("--always-expanded")

        let v9Effect = ProbeEffect(
            versionTag: "V9",
            subtitleTag: "丝绸干涉极光边",
            shaderFragmentSource: v9ShaderFragment,
            bannerMode: .smartCollapsible(
                startCollapsed: startCollapsed,
                autoCollapseDelay: alwaysExpanded ? 86400 : 4.0
            ),
            setupExtraMenuItems: { menu, probe in
                v9MenuHelper.probe = probe
                let expandItem = NSMenuItem(title: "常驻展开控制胶囊", action: #selector(V9MenuHelper.expandAndPin), keyEquivalent: "")
                expandItem.target = v9MenuHelper
                menu.addItem(expandItem)
                let collapseItem = NSMenuItem(title: "立即收纳控制胶囊", action: #selector(V9MenuHelper.collapseNow), keyEquivalent: "")
                collapseItem.target = v9MenuHelper
                menu.addItem(collapseItem)
            }
        )

        runProbeMain(effect: v9Effect, extraUsage: "[--collapsed | --always-expanded]")
    }
}
