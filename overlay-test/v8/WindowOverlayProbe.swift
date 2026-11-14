import Cocoa

// V8: Tether Pulse — anchors visual presence to a bidirectional optical dock underneath the
// collapsible control pill, splitting via a luminous Y-tether into twin symmetric waveguides
// with asymmetric comet-tail signal pulses climbing the perimeter and whispering across the top.
final class V8MenuHelper: NSObject {
    weak var probe: Probe?
    @objc func expandAndPin() { probe?.forceBannerFolded(false) }
    @objc func collapseNow() { probe?.forceBannerFolded(true) }
}

private let v8MenuHelper = V8MenuHelper()

let v8ShaderFragment = """
static float asymmetricPacket(float uSym, float headPos, float aheadSigma, float behindSigma) {
    float ahead = fract(uSym - headPos);
    float behind = fract(headPos - uSym);
    float decay = (ahead < 0.5)
        ? exp(-ahead / aheadSigma) * (1.0 - smoothstep(0.28, 0.46, ahead))
        : exp(-behind / behindSigma) * (1.0 - smoothstep(0.32, 0.48, behind));
    return decay;
}

fragment float4 overlayFragment(VOut in [[stage_in]], constant Uniforms& U [[buffer(0)]]) {
    float2 p = in.position.xy / max(U.scale, 1.0);
    float d = insideDistance(p, U.size, U.radius);
    if (d < -0.5) { return float4(0.0); }

    float k = clamp(U.intensity, 0.4, 1.8);
    float styleT = clamp((k - 0.75) / 0.57, 0.0, 1.0);

    // True symmetric perimeter arc coordinate uSym in [0 (bottom dock) .. 1 (top apex)]
    float halfW = U.size.x * 0.5;
    float wx = pow(max(U.size.x, 1.0), 0.55);
    float wy = pow(max(U.size.y, 1.0), 0.55);
    float uSym = atan2(abs(p.x - halfW) / wx, (p.y - U.size.y * 0.5) / wy) / M_PI_F;

    // Smooth bilateral blend (-1 left, +1 right) with zero centerline seam
    float sideMix = 0.5 + 0.5 * tanh((p.x - halfW) / 52.0);
    float shimmerT = 0.5 + 0.5 * sin(U.time * 1.1 + uSym * 3.14159);

    float3 leftLight  = mix(float3(0.00, 0.66, 0.95), float3(0.08, 0.78, 0.80), shimmerT * 0.45);
    float3 rightLight = mix(float3(0.18, 0.40, 0.98), float3(0.54, 0.22, 0.95), shimmerT * 0.50);
    float3 leftDark   = mix(float3(0.24, 0.86, 1.00), float3(0.32, 0.94, 0.86), shimmerT * 0.45);
    float3 rightDark  = mix(float3(0.36, 0.58, 1.00), float3(0.72, 0.40, 1.00), shimmerT * 0.50);

    float3 baseCol = mix(
        mix(leftLight, rightLight, sideMix),
        mix(leftDark, rightDark, sideMix),
        U.dark
    );
    float3 echoCol = mix(float3(0.92, 0.26, 0.58), float3(1.00, 0.48, 0.76), U.dark);

    // Bottom dock cradle weight: strongest along bottom rim & lower corners, tapers to crisp hairline on top
    float cradleWeight = exp(-pow(uSym / 0.38, 1.85));
    float apexWhisper  = mix(0.30, 0.48, styleT);
    float baseTrackWeight = mix(apexWhisper, 1.0, cradleWeight);

    // Directional kinetic telemetry packets climbing upward (uSym: 0 -> 1) + soft downward echo
    float head1 = U.time * 0.32;
    float head2 = head1 + 0.50;
    float headEcho = -U.time * 0.24 + 0.22;

    float pkt1 = asymmetricPacket(uSym, head1, 0.012, 0.105);
    float pkt2 = asymmetricPacket(uSym, head2, 0.012, 0.095) * 0.82;
    float echo1 = asymmetricPacket(1.0 - uSym, fract(1.0 - headEcho), 0.014, 0.085) * 0.48;

    float pulseDrive = clamp(pkt1 + pkt2, 0.0, 1.35);
    float combinedPulse = clamp(pulseDrive + echo1, 0.0, 1.45);

    // Dynamic waveguide width & inner optical bloom anchored cleanly along inside bezel (d = 0.9 pt)
    float coreWidth = mix(1.15, 1.85, styleT) * (0.85 + 0.35 * cradleWeight) * (1.0 + 0.72 * combinedPulse);
    float insideEdge = smoothstep(-0.20, 0.30, d);
    float outerReach = mix(9.0, 16.5, max(cradleWeight, 0.55 * combinedPulse)) * mix(0.82, 1.15, styleT);
    float trackCutoff = smoothstep(outerReach, 1.2, d);

    float wireCore = exp(-pow((d - 0.90) / coreWidth, 2.0)) * insideEdge;
    float wireHalo = exp(-max(d, 0.0) / mix(3.4, 7.2, max(cradleWeight, 0.65 * combinedPulse) * (0.55 + 0.45 * styleT)))
                   * insideEdge * trackCutoff;

    float trackAlpha = wireCore * (0.48 * baseTrackWeight + 0.72 * combinedPulse) * mix(0.62, 0.96, styleT)
                     + wireHalo * (0.16 * cradleWeight + 0.38 * combinedPulse) * mix(0.45, 0.84, styleT);

    // Highlight color blends bright glacial core on climbing pulses and warm orchid on descending echo
    float3 pulseTint = mix(baseCol, echoCol, clamp(echo1 / max(combinedPulse, 1e-4), 0.0, 0.80));
    float whitePeak = clamp(pow(pulseDrive, 1.45) * 0.72 * wireCore, 0.0, 0.82);
    float3 trackCol = mix(pulseTint, mix(float3(0.92, 0.98, 1.0), float3(1.0), U.dark), whitePeak);

    // Optical Dock Bridge (ONLY draws inside bottom 22 pt margin when collapsed / retracting into bottom socket)
    float tetherAlpha = 0.0;
    float3 tetherCol = baseCol;
    float pillRimAlpha = 0.0;

    float dockBeat = 0.66 + 0.34 * (exp(-pow(fract(head1) * 4.5, 2.0)) + exp(-pow(fract(head2) * 4.5, 2.0)));
    if (U.bannerRect.z > 1.0 && U.bannerRect.w > 1.0) {
        float2 bCenter = U.bannerRect.xy + U.bannerRect.zw * 0.5;
        float2 bHalf = U.bannerRect.zw * 0.5;
        float bCorner = mix(16.0, 20.0, U.bannerFold);
        float dPill = roundedBoxSDF(p, bCenter, bHalf, bCorner);

        // Tight optical connector rim around the pill capsule
        float pillRim = exp(-pow((dPill - 0.50) / mix(0.95, 1.25, styleT), 2.0))
                      * smoothstep(-0.5, 0.15, dPill)
                      * smoothstep(5.5, 1.2, dPill);
        float pillHalo = exp(-max(dPill, 0.0) / mix(4.5, 7.8, styleT))
                       * smoothstep(-0.3, 0.6, dPill)
                       * smoothstep(13.0, 2.0, dPill);
        pillRimAlpha = (pillRim * mix(0.42, 0.78, styleT) + pillHalo * mix(0.10, 0.22, styleT)) * dockBeat;

        // Sculpted concave optical Y-plug inside bottom 14..22 pt ONLY when collapsed (retracts cleanly on expand!)
        float collapseVis = clamp(1.0 - U.bannerFold * 1.65, 0.0, 1.0);
        float bBottom = U.bannerRect.y + U.bannerRect.w;
        float neckTop = max(bBottom - 1.5, U.size.y - 22.0);
        if (collapseVis > 0.01 && p.y >= neckTop && p.y <= U.size.y + 0.5) {
            float span = max(U.size.y - neckTop, 2.0);
            float vT = clamp((p.y - neckTop) / span, 0.0, 1.0);
            float dxCenter = abs(p.x - bCenter.x);
            // Smooth MagSafe-style concave fillet profile flaring into bottom rail
            float curveHalfW = 11.0 + pow(vT, 2.0) * mix(34.0, 50.0, styleT);
            float dNeck = dxCenter - curveHalfW;

            float neckFill = smoothstep(2.0, -2.5, dNeck);
            float neckBevel = exp(-pow(dNeck / 1.25, 2.0));
            float fiberSpine = exp(-pow(dxCenter / mix(1.5, 2.2, styleT), 2.0));
            float surge1 = exp(-pow((fract(vT - U.time * 0.95) - 0.25) / 0.18, 2.0));

            float dockGlow = neckFill * (0.28 + 0.30 * pow(vT, 1.3)) * mix(0.55, 0.90, styleT)
                           + neckBevel * mix(0.48, 0.85, styleT) * (0.55 + 0.45 * vT)
                           + fiberSpine * (0.40 + 0.55 * surge1) * mix(0.55, 0.92, styleT);
            tetherAlpha = clamp(dockGlow * collapseVis * dockBeat, 0.0, 0.90)
                        * smoothstep(neckTop - 1.0, neckTop + 2.5, p.y);
            float spec = clamp(neckBevel * 0.45 + fiberSpine * (0.35 + 0.45 * surge1), 0.0, 0.85);
            tetherCol = mix(baseCol, float3(0.90, 0.98, 1.0), spec);
        } else if (U.bannerFold > 0.05 && p.y >= U.size.y - 16.0) {
            // Subtle illuminated bottom floor dock socket when expanded bar floats above
            float dxCenter = abs(p.x - bCenter.x);
            float sockR = length(float2(dxCenter * 0.42, max(U.size.y - p.y, 0.0)));
            float floorSocket = exp(-pow(sockR / 10.0, 1.8)) * clamp(U.bannerFold * 1.4, 0.0, 1.0);
            tetherAlpha = clamp(floorSocket * dockBeat * mix(0.42, 0.78, styleT), 0.0, 0.80);
            tetherCol = mix(baseCol, float3(0.88, 0.97, 1.0), floorSocket * 0.55);
        }
    }

    float aTrack  = clamp(trackAlpha, 0.0, 0.94);
    float aTether = clamp(tetherAlpha, 0.0, 0.88);
    float aPill   = clamp(pillRimAlpha, 0.0, 0.85);

    float wSum = aTrack + aTether + aPill + 1e-5;
    float3 finalRGB = (trackCol * aTrack + tetherCol * aTether + baseCol * aPill) / wSum;
    float alpha = 1.0 - (1.0 - aTrack) * (1.0 - aTether) * (1.0 - aPill);
    alpha = clamp(alpha, 0.0, 0.94) * U.presence;
    return float4(finalRGB * alpha, alpha);
}
"""

@main
enum V8ProbeApp {
    static func main() {
        let args = CommandLine.arguments
        let startCollapsed = args.contains("--collapsed")
        let alwaysExpanded = args.contains("--always-expanded")

        let v8Effect = ProbeEffect(
            versionTag: "V8",
            subtitleTag: "接驳脉冲丝带",
            shaderFragmentSource: v8ShaderFragment,
            bannerMode: .smartCollapsible(
                startCollapsed: startCollapsed,
                autoCollapseDelay: alwaysExpanded ? 86400 : 4.0
            ),
            setupExtraMenuItems: { menu, probe in
                v8MenuHelper.probe = probe
                let expandItem = NSMenuItem(title: "常驻展开控制胶囊", action: #selector(V8MenuHelper.expandAndPin), keyEquivalent: "")
                expandItem.target = v8MenuHelper
                menu.addItem(expandItem)
                let collapseItem = NSMenuItem(title: "立即收纳控制胶囊", action: #selector(V8MenuHelper.collapseNow), keyEquivalent: "")
                collapseItem.target = v8MenuHelper
                menu.addItem(collapseItem)
            }
        )

        runProbeMain(effect: v8Effect, extraUsage: "[--collapsed | --always-expanded]")
    }
}
