import AppKit

// V2: Minimal Perimeter Prism Ribbon — 100% clear interior for zero reading fatigue,
// with a seamless 6-stop iridescent edge hairline + tight inward feather and traveling caustics.

private let v2FragmentShader = """
static float3 cyclicPrism6(float phase, float darkMode) {
    float u = fract(phase) * 6.0;
    int idx = int(floor(u)) % 6;
    float f = smoothstep(0.0, 1.0, fract(u));

    float3 lightPalette[6] = {
        float3(0.22, 0.46, 1.00), // Deep Sapphire
        float3(0.58, 0.24, 1.00), // Rich Electric Violet
        float3(0.98, 0.20, 0.66), // Vivid Rose Magenta
        float3(1.00, 0.38, 0.16), // Bold Coral Tangerine
        float3(1.00, 0.72, 0.12), // Rich Amber Gold
        float3(0.84, 0.44, 0.96)  // Radiant Orchid (bridges cleanly back to Sapphire)
    };
    float3 darkPalette[6] = {
        float3(0.40, 0.66, 1.00),
        float3(0.70, 0.42, 1.00),
        float3(1.00, 0.38, 0.78),
        float3(1.00, 0.52, 0.30),
        float3(1.00, 0.84, 0.36),
        float3(0.84, 0.60, 1.00)
    };
    int nextIdx = (idx + 1) % 6;
    float3 lCol = mix(lightPalette[idx], lightPalette[nextIdx], f);
    float3 dCol = mix(darkPalette[idx], darkPalette[nextIdx], f);
    return mix(lCol, dCol, darkMode);
}

fragment float4 overlayFragment(VOut in [[stage_in]], constant Uniforms& U [[buffer(0)]]) {
    float2 size = U.size;
    float2 p = in.position.xy / U.scale;
    float t = U.time;
    float d = insideDistance(p, size, U.radius);
    float coverage = clamp(d * U.scale + 0.5, 0.0, 1.0);
    if (coverage <= 0.0 || U.presence <= 0.0) { return float4(0.0); }

    float k = U.intensity;
    float styleT = clamp((k - 0.75) / 0.57, 0.0, 1.0); // 0=柔和, ~0.44=标准, 1=鲜明
    float maxReach = mix(110.0, 195.0, styleT);
    if (d > maxReach) { return float4(0.0); }

    float ang = perimeterAngle(p, size);
    // Counter-paced caustic wave packets gliding clockwise along the perimeter.
    float packet1 = pow(max(0.5 + 0.5 * cos(ang - t * 1.15), 0.0), 3.0);
    float packet2 = pow(max(0.5 + 0.5 * cos(2.0 * (ang + t * 0.48) - 1.1), 0.0), 3.6) * 0.70;
    float packet3 = pow(max(0.5 + 0.5 * cos(ang - t * 1.15 + M_PI_F), 0.0), 4.2) * 0.58;
    float caustic = clamp(packet1 + packet2 + packet3, 0.0, 1.35);

    // Chromatic dispersion across the beveled prism band.
    float phaseBase = ang / (M_PI_F * 2.0) - t * 0.14;
    float disp = (d - 3.0) * 0.0026;
    float3 colOuter = cyclicPrism6(phaseBase + disp, U.dark);
    float3 colInner = cyclicPrism6(phaseBase - disp, U.dark);
    float3 prismCol = mix(colOuter, colInner, smoothstep(0.0, 22.0, d));

    // 1) Rich glowing perimeter rim band (clearly visible in all 3 modes, bold in Vivid).
    float rimWidth = mix(2.2, 4.4, styleT) + 1.35 * caustic;
    float rimCore = exp(-pow(max(d - 1.6, 0.0) / rimWidth, 2.0));
    float innerRimCatch = exp(-pow(abs(d - mix(4.0, 7.0, styleT)) / mix(3.2, 5.2, styleT), 2.0)) * 0.48;

    // 2) Generous inward prism ribbon tapering smoothly well before center text.
    float featherWidth = mix(22.0, 44.0, styleT) * (0.86 + 0.34 * caustic);
    float feather = exp(-max(d - 1.4, 0.0) / featherWidth) * smoothstep(maxReach, 8.0, d);

    // Keep Light mode deeply saturated (no white-wash); only add luminous specular crest in Dark mode or intense caustic peak.
    float crestPeak = pow(clamp(caustic, 0.0, 1.0), 2.4);
    float3 rimColor = mix(prismCol, min(prismCol * 1.20 + 0.22, float3(1.0)), U.dark * 0.45 + 0.24 * crestPeak);

    float lineAlpha = clamp((rimCore + innerRimCatch * 0.65) * mix(0.76, 0.96, styleT) * (0.70 + 0.30 * min(caustic, 1.0)), 0.0, 0.96);
    float washAlpha = clamp(feather * mix(0.30, 0.62, styleT) * mix(0.88, 1.0, U.dark) * (0.64 + 0.48 * caustic), 0.0, 0.88);

    // Premultiplied Porter-Duff compositing: rim over wash.
    float3 finalRGB = prismCol * washAlpha;
    float finalA = washAlpha;
    finalRGB = rimColor * lineAlpha + finalRGB * (1.0 - lineAlpha);
    finalA = lineAlpha + finalA * (1.0 - lineAlpha);

    // Sparkling prism glints nestled inside the glowing band.
    float2 dustCell = floor(p / 8.5);
    float2 dustLocal = (fract(p / 8.5) - 0.5) * 8.5;
    float seed = hash21(dustCell + 17.3);
    float phaseClock = t * (0.36 + 0.28 * seed) + seed * 13.0;
    float ph = fract(phaseClock);
    float gate = hash21(dustCell + floor(phaseClock) * 2.13);
    float env = smoothstep(0.0, 0.15, ph) * (1.0 - smoothstep(0.15, 0.46, ph));
    float spark = gate > 0.86 ? env : 0.0;
    float dotShape = exp(-dot(dustLocal, dustLocal) / (2.0 * (0.48 + 0.30 * spark) * (0.48 + 0.30 * spark)))
                   + (0.14 + 0.24 * spark) * exp(-dot(dustLocal, dustLocal) / (2.0 * 1.4 * 1.4));
    float glintZone = exp(-d / mix(22.0, 38.0, styleT));
    float glintAlpha = clamp(dotShape * (0.10 + 0.78 * spark) * glintZone * (0.45 + 0.55 * min(caustic, 1.0)) * mix(0.65, 1.25, styleT), 0.0, 0.90);

    float3 glintCol = mix(min(prismCol * 0.85 + 0.35, float3(1.0)), float3(1.0), 0.55);
    finalRGB = glintCol * glintAlpha + finalRGB * (1.0 - glintAlpha);
    finalA = glintAlpha + finalA * (1.0 - glintAlpha);

    float grain = (hash21(in.position.xy) - 0.5) * (2.0 / 255.0);
    finalRGB = clamp(finalRGB + grain * finalA, 0.0, finalA);
    return float4(finalRGB, finalA) * (coverage * U.presence);
}
"""

@main
enum V2ProbeEntry {
    static func main() {
        let effect = ProbeEffect(
            versionTag: "V2 棱镜光带",
            subtitleTag: "样式预览 · V2 极简棱镜光带",
            shaderFragmentSource: v2FragmentShader
        )
        runProbeMain(effect: effect)
    }
}
