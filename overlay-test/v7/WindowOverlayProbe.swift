import Cocoa

// V7: Out-of-Frame Halo — expands the Metal panel beyond the window frame to project an
// Ambilight-style breathing aurora glow into the exterior shadow perimeter while keeping
// the controlled window interior >99% untouched (only a crisp ~1.4 pt inner bezel rim
// + collapsible V6 smart pill).
final class V7MenuHelper: NSObject {
    weak var probe: Probe?
    @objc func expandAndPin() { probe?.forceBannerFolded(false) }
    @objc func collapseNow() { probe?.forceBannerFolded(true) }
}

private let v7MenuHelper = V7MenuHelper()

let v7ShaderFragment = """
fragment float4 overlayFragment(VOut in [[stage_in]], constant Uniforms& U [[buffer(0)]]) {
    float2 p = in.position.xy / max(U.scale, 1.0);
    // U.custom = (padLeft, padTop, targetWinW, targetWinH); U.param0 = outerPadding
    float2 winSize = max(U.custom.zw, float2(1.0));
    float2 pWin = p - U.custom.xy;
    float d = insideDistance(pWin, winSize, U.radius);
    float theta = perimeterAngle(pWin, winSize);

    float k = clamp(U.intensity, 0.4, 1.8);
    float styleT = clamp((k - 0.75) / 0.57, 0.0, 1.0);
    float outPad = max(U.param0, 1.0);

    // 4-anchor C1-seamless aurora loop with gentle multi-harmonic drift.
    float wave = 0.045 * sin(theta * 2.0 + U.time * 0.75)
               + 0.025 * cos(theta * 3.0 - U.time * 0.55);
    float flow = fract(theta / (2.0 * M_PI_F) + 0.5 - U.time * 0.045 + wave);

    float3 lightC0 = float3(0.02, 0.62, 0.96); // Sky cyan-blue
    float3 lightC1 = float3(0.18, 0.36, 0.98); // Electric cobalt
    float3 lightC2 = float3(0.54, 0.20, 0.95); // Vivid violet
    float3 lightC3 = float3(0.92, 0.22, 0.54); // Orchid rose

    float3 darkC0  = float3(0.22, 0.84, 1.00);
    float3 darkC1  = float3(0.38, 0.56, 1.00);
    float3 darkC2  = float3(0.72, 0.42, 1.00);
    float3 darkC3  = float3(1.00, 0.46, 0.72);

    float3 haloCol = mix(
        linearRamp5(flow, lightC0, lightC1, lightC2, lightC3, lightC0),
        linearRamp5(flow, darkC0, darkC1, darkC2, darkC3, darkC0),
        U.dark
    );

    // Outward Ambilight zone (d < 0 -> outD > 0)
    float outD = max(0.0, -d);
    float breath = 0.5 + 0.5 * sin(U.time * 1.45 - outD * 0.085 + 0.4 * cos(theta * 2.0));
    float shimmer = 0.90 + 0.10 * sin(theta * 3.0 - U.time * 1.15);

    float maxReach = mix(26.0, outPad - 2.0, styleT);
    float edgeClamp = 1.0 - smoothstep(maxReach * 0.42, maxReach, outD);
    float outsideMask = smoothstep(-0.85, 0.35, -d);

    float coronaSigma = mix(5.2, 9.2, styleT) + 1.5 * breath;
    float outerCorona = exp(-pow(outD / coronaSigma, 1.25)) * outsideMask * edgeClamp;

    float mistSigma = mix(10.5, 19.0, styleT) + 2.6 * breath;
    float outerMist = exp(-outD / mistSigma) * outsideMask * edgeClamp;

    float outerAlpha = (outerCorona * mix(0.30, 0.62, styleT)
                      + outerMist * mix(0.13, 0.32, styleT))
                     * shimmer * (0.86 + 0.14 * breath);

    // Knife-sharp 1.3 pt inner bezel rim (strictly zero past d = 3.6 pt -> clean interior)
    float rimWidth = mix(0.95, 1.32, styleT);
    float innerRim = exp(-pow((d - 0.55) / rimWidth, 2.0))
                   * smoothstep(-1.1, -0.1, d)
                   * smoothstep(3.6, 1.0, d);
    float cornerBoost = 1.0 + 0.18 * pow(abs(sin(2.0 * theta)), 2.2);
    float rimAlpha = innerRim * cornerBoost * mix(0.42, 0.84, styleT) * (0.90 + 0.10 * breath);

    // Smart pill beacon linkage: subtle under-pill aura + outer bottom-edge emphasis aligned below pill
    float pillAuraAlpha = 0.0;
    float3 pillCol = mix(haloCol, float3(0.45, 0.52, 1.00), 0.35);
    if (U.bannerRect.z > 1.0 && U.bannerRect.w > 1.0) {
        float2 bCenter = U.bannerRect.xy + U.bannerRect.zw * 0.5;
        float2 bHalf = U.bannerRect.zw * 0.5;
        float bCorner = mix(16.0, 20.0, U.bannerFold);
        float dPill = roundedBoxSDF(p, bCenter, bHalf, bCorner);

        float pillTight = exp(-max(dPill, 0.0) / mix(7.0, 11.5, U.bannerFold))
                        * smoothstep(-1.5, 1.0, dPill);
        pillAuraAlpha = pillTight * mix(0.12, 0.22, styleT) * (0.65 + 0.35 * U.bannerFold);

        // Soft outer anchor spotlight aligned underneath the pill along bottom bezel
        float bottomEdge = smoothstep(winSize.y - 10.0, winSize.y + 4.0, pWin.y);
        float xSpan = max(bHalf.x + 28.0, 56.0);
        float xAlign = exp(-pow((p.x - bCenter.x) / xSpan, 2.0));
        float anchorGlow = outerCorona * bottomEdge * xAlign * mix(0.16, 0.30, styleT);
        outerAlpha = clamp(outerAlpha + anchorGlow, 0.0, 0.88);
    }

    // Keep crisp chromatic saturation on white light-mode titlebars; lift luminance in dark mode.
    float specularMix = innerRim * (0.14 + 0.24 * U.dark);
    float3 rimCol = mix(haloCol, float3(1.0), specularMix);
    float sumW = outerAlpha + rimAlpha + pillAuraAlpha + 1e-5;
    float3 finalRGB = (haloCol * outerAlpha + rimCol * rimAlpha + pillCol * pillAuraAlpha) / sumW;

    float alpha = 1.0 - (1.0 - clamp(outerAlpha, 0.0, 0.88))
                      * (1.0 - clamp(rimAlpha, 0.0, 0.90))
                      * (1.0 - clamp(pillAuraAlpha, 0.0, 0.45));
    alpha = clamp(alpha, 0.0, 0.92) * U.presence;
    return float4(finalRGB * alpha, alpha);
}
"""

@main
enum V7ProbeApp {
    static func main() {
        let args = CommandLine.arguments
        let startCollapsed = args.contains("--collapsed")
        let alwaysExpanded = args.contains("--always-expanded")

        let v7Effect = ProbeEffect(
            versionTag: "V7",
            subtitleTag: "外溢环境光（零内容遮挡）",
            shaderFragmentSource: v7ShaderFragment,
            bannerMode: .smartCollapsible(
                startCollapsed: startCollapsed,
                autoCollapseDelay: alwaysExpanded ? 86400 : 4.0
            ),
            outerPadding: 40,
            setupExtraMenuItems: { menu, probe in
                v7MenuHelper.probe = probe
                let expandItem = NSMenuItem(title: "常驻展开控制胶囊", action: #selector(V7MenuHelper.expandAndPin), keyEquivalent: "")
                expandItem.target = v7MenuHelper
                menu.addItem(expandItem)
                let collapseItem = NSMenuItem(title: "立即收纳控制胶囊", action: #selector(V7MenuHelper.collapseNow), keyEquivalent: "")
                collapseItem.target = v7MenuHelper
                menu.addItem(collapseItem)
            }
        )

        runProbeMain(effect: v7Effect, extraUsage: "[--collapsed | --always-expanded]")
    }
}
