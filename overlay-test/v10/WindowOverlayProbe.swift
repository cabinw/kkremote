import AppKit

// V10: Ego Lite × V6 Fusion — combines V5's 120fps-calibrated Ego Lite optical system
// (9.0 pt stationary pinpoint dot matrix, ~1.55 s right-to-left sweeping veil & curtain sparkles,
// ~1.77 s / 3.53 s cornflower opposition edge breath, frosted inner rim) with V6's praised
// smart collapsible control pill (426×74 ↔ 112×32) and synced pill aura / sparkle linkage.
private let v10FragmentShader = """
fragment float4 overlayFragment(VOut in [[stage_in]], constant Uniforms& U [[buffer(0)]]) {
    float2 size = U.size;
    float2 p = in.position.xy / U.scale;
    float t = U.time;
    float d = insideDistance(p, size, U.radius);
    float coverage = clamp(d * U.scale + 0.5, 0.0, 1.0);
    if (coverage <= 0.0 || U.presence <= 0.0) { return float4(0.0); }

    float k = U.intensity;
    float styleT = clamp((k - 0.75) / 0.57, 0.0, 1.0); // 0=柔和, ~0.44=标准, 1=鲜明
    float2 uv = p / size;
    float minDim = min(size.x, size.y);

    // Live collapsible pill SDF (in window top-left points)
    float4 br = U.bannerRect;
    float hasBanner = step(10.0, br.z);
    float fold = clamp(U.bannerFold, 0.0, 1.0);
    float2 bCenter = br.xy + br.zw * 0.5;
    float2 bHalf = max(br.zw * 0.5, float2(1.0));
    float bRadius = mix(16.0, 20.0, fold);
    float sdBanner = roundedBoxSDF(p, bCenter, bHalf, min(bRadius, min(bHalf.x, bHalf.y)));
    float behindSuppression = hasBanner * (1.0 - smoothstep(-2.0, 14.0, sdBanner));

    // 1) Ego Lite ~1.77s opposition perimeter breath + ~3.53s harmonic envelope
    float2 c = uv - 0.5;
    float cLen2 = dot(c, c) + 1e-4;
    float midSideMask = smoothstep(0.18, 0.88, (c.x * c.x - c.y * c.y) / cLen2)
                      * smoothstep(0.46, 0.06, abs(c.y));

    const float omegaFast = 3.55; // 2*pi / 1.77s
    const float omegaSlow = 1.78; // 2*pi / 3.53s
    float slowEnv = 0.72 + 0.28 * sin(t * omegaSlow + 0.4 + c.x * 0.65);
    float tbWave = (0.5 + 0.5 * cos(t * omegaFast + c.x * 0.85)) * slowEnv;
    float lrWave = (0.5 + 0.5 * cos(t * omegaFast + M_PI_F + c.y * 0.85)) * (1.06 - 0.16 * sin(t * omegaSlow));
    float sideBreath = mix(tbWave, lrWave, midSideMask);

    float ang = perimeterAngle(p, size);
    float cloudA = pow(max(0.5 + 0.5 * cos(ang - t * 0.92), 0.0), 2.0);
    float cloudB = pow(max(0.5 + 0.5 * cos(ang + t * 0.64 + 1.4), 0.0), 2.4) * 0.55;
    float haloEnergy = clamp(0.18 + 0.78 * sideBreath + 0.30 * (cloudA + cloudB - 0.55), 0.14, 1.34);

    // 2) Signature Cornflower / Periwinkle / Sky-Mist Palette with gentle lavender iris accent near pill
    float3 lightCoreBlue = float3(0.24, 0.48, 0.99);
    float3 lightSoftBlue = float3(0.44, 0.58, 1.00);
    float3 lightMistTint = float3(0.68, 0.80, 0.99);

    float3 darkCoreBlue  = float3(0.26, 0.54, 1.00);
    float3 darkSoftBlue  = float3(0.48, 0.48, 1.00);
    float3 darkMistTint  = float3(0.56, 0.76, 1.00);

    float3 colCore = mix(lightCoreBlue, darkCoreBlue, U.dark);
    float3 colSoft = mix(lightSoftBlue, darkSoftBlue, U.dark);
    float3 colMist = mix(lightMistTint, darkMistTint, U.dark);

    float haloSpan = clamp(minDim * mix(0.18, 0.25, styleT), 88.0, 170.0);
    float cornerFactor = smoothstep(0.12, 0.48, abs(c.x)) * smoothstep(0.12, 0.48, abs(c.y));
    float localSpan = haloSpan * (1.0 + 0.24 * cornerFactor);

    float edgeOuter = exp(-pow(max(d - 1.5, 0.0) / (localSpan * 0.45), 1.38));
    float edgeInner = exp(-pow(max(d - 1.5, 0.0) / (localSpan * 0.96), 1.68)) * 0.46;
    float haloField = clamp(edgeOuter * 0.84 + edgeInner, 0.0, 1.0);

    // Sweeping right-to-left soft translucent veil / wave band (~1.55s period)
    const float waveOmega = 4.05; // 2*pi / 1.55s
    float waveCoord = uv.x + 0.14 * uv.y;
    float wavePhase = waveCoord * 3.8 + t * waveOmega;
    float waveCrest = pow(max(0.5 + 0.5 * sin(wavePhase), 0.0), 2.8);
    float secondaryRipple = 0.5 + 0.5 * sin(uv.x * 2.2 - t * 1.35 + uv.y * 1.6);

    // Synchronized wave response at pill horizontal center so passing sweep breathes through pill aura
    float2 bUv = bCenter / max(size, float2(1.0));
    float pillWaveHit = pow(max(0.5 + 0.5 * sin((bUv.x + 0.14 * bUv.y) * 3.8 + t * waveOmega), 0.0), 2.4);

    // V6 anchor halo around the collapsible pill contour (tighter when folded, broader when expanded)
    float haloSpread = mix(20.0, 34.0, fold);
    float anchorHalo = hasBanner
                     * smoothstep(-3.0, 3.0, sdBanner)
                     * exp(-max(sdBanner, 0.0) / haloSpread)
                     * mix(0.24, 0.36, fold) * (0.78 + 0.28 * pillWaveHit) * k;
    float haloRimCatch = hasBanner
                       * exp(-pow(abs(sdBanner - 1.8) / 3.0, 2.0))
                       * mix(0.20, 0.30, fold) * (0.80 + 0.24 * pillWaveHit);

    float centerAtmos = (mix(0.015, 0.036, styleT) + waveCrest * mix(0.018, 0.040, styleT))
                      * (1.0 - 0.72 * behindSuppression);
    float edgePeakA = mix(0.46, 0.78, styleT) * mix(1.0, 0.88, U.dark);
    float washA = clamp(centerAtmos + haloField * edgePeakA * haloEnergy + anchorHalo + haloRimCatch, 0.0, 0.86);

    float tintMix = 0.5 + 0.5 * sin(ang * 1.5 - t * 0.65);
    float3 perimCol = mix(colCore, colSoft, 0.45 * tintMix);
    float3 baseVeilCol = mix(float3(0.91, 0.94, 0.99), float3(0.16, 0.24, 0.42), U.dark);
    float3 haloCol = mix(baseVeilCol, mix(colMist, perimCol, smoothstep(0.06, 0.68, edgeOuter)), smoothstep(0.02, 0.35, haloField));
    float3 pillIrisCol = mix(float3(0.40, 0.56, 1.00), float3(0.62, 0.48, 1.00), 0.45 + 0.35 * sin(t * 0.9 + p.x * 0.015));
    haloCol = mix(haloCol, pillIrisCol, clamp(anchorHalo * 1.6 + haloRimCatch * 1.1, 0.0, 0.85));

    // Soft frosted rim highlight hugging the continuous n=2.85 squircle edge
    float rimLine = exp(-pow(max(d - 1.10, 0.0) / 0.95, 2.0));
    float rimBloom = exp(-pow(max(d - 1.8, 0.0) / 5.5, 2.0));
    float rimA = clamp((rimLine * 0.62 + rimBloom * 0.14) * mix(0.65, 1.05, styleT)
                       * (0.72 + 0.28 * haloEnergy) * mix(1.0, 0.60, U.dark), 0.0, 0.76);

    // 3) Ego Lite stationary 9.0 pt pinpoint dot matrix (suppressed behind glass pill, sparkling in pill aura!)
    const float dotSpacing = 9.0;
    float2 cell = floor(p / dotSpacing);
    float2 local = (fract(p / dotSpacing) - 0.5) * dotSpacing;
    float dist2 = dot(local, local);
    float dotKernel = exp(-dist2 / (2.0 * 0.46 * 0.46));

    float pillSparkZone = hasBanner * exp(-max(sdBanner, 0.0) / mix(22.0, 32.0, fold)) * smoothstep(0.0, 7.0, sdBanner);

    float baseCenterDot = mix(0.060, 0.140, styleT);
    float baseEdgeDot = mix(0.20, 0.36, styleT) * haloField * (0.65 + 0.35 * haloEnergy);
    float waveDotLift = waveCrest * mix(0.18, 0.40, styleT) * (0.48 + 0.52 * haloField + 0.25 * secondaryRipple);
    float pillDotBoost = pillSparkZone * mix(0.10, 0.22, styleT) * (0.65 + 0.35 * pillWaveHit);

    float2 worldCellPos = (cell + 0.5) * dotSpacing;
    float curtainNoise = valueNoise(worldCellPos * 0.022 + float2(t * 0.85, -t * 0.32));
    float subNoise = valueNoise(worldCellPos * 0.055 - float2(t * 0.45, t * 0.28));
    float patchGate = smoothstep(0.58, 0.82, curtainNoise * 0.68 + subNoise * 0.32);

    float dSeed = hash21(cell + 17.3);
    float twkClk = t * (0.55 + 0.45 * dSeed) + dSeed * 31.0;
    float twkPh = fract(twkClk);
    float twkHash = hash21(cell + floor(twkClk) * 4.19);
    float twkEnv = smoothstep(0.0, 0.18, twkPh) * (1.0 - smoothstep(0.18, 0.58, twkPh));

    float curtainSpark = patchGate * smoothstep(0.38, 0.92, waveCrest) * step(0.42, hash21(cell + floor(twkClk * 0.5) * 2.17))
                       * (0.45 + 0.55 * twkEnv) * mix(0.42, 0.82, styleT);
    float pinSpark = (twkHash > 0.970 ? twkEnv : 0.0) * (0.40 + 0.60 * max(waveCrest, pillSparkZone)) * mix(0.45, 0.85, styleT);

    float dotA = clamp(dotKernel
                       * (baseCenterDot + baseEdgeDot + waveDotLift + pillDotBoost + curtainSpark + pinSpark)
                       * (1.0 - behindSuppression * 0.90), 0.0, 0.94);

    // 4) Premultiplied Porter-Duff compositing
    float3 col = haloCol * washA;
    float a = washA;

    float3 veilStreakCol = mix(float3(0.95, 0.97, 1.00), float3(0.62, 0.78, 1.00), U.dark);
    float streakA = clamp(waveCrest * (0.025 + 0.035 * haloField) * mix(0.55, 1.15, styleT)
                        * mix(1.0, 0.48, U.dark) * (1.0 - behindSuppression * 0.85), 0.0, 0.12);
    col = veilStreakCol * streakA + col * (1.0 - streakA);
    a = streakA + a * (1.0 - streakA);

    float3 dotCol = mix(float3(1.00, 1.00, 1.00), float3(0.90, 0.96, 1.00), U.dark);
    col = dotCol * dotA + col * (1.0 - dotA);
    a = dotA + a * (1.0 - dotA);

    float3 rimCol = mix(float3(0.96, 0.98, 1.00), float3(0.76, 0.88, 1.00), U.dark);
    col = rimCol * rimA + col * (1.0 - rimA);
    a = rimA + a * (1.0 - rimA);

    float grain = (hash21(in.position.xy) - 0.5) * (1.5 / 255.0);
    col = clamp(col + grain * a, 0.0, a);
    return float4(col, a) * (coverage * U.presence);
}
"""

final class V10MenuHelper: NSObject {
    weak var probe: Probe?

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
enum V10ProbeEntry {
    private static var menuHelper: V10MenuHelper?

    static func main() {
        let startCollapsed = CommandLine.arguments.contains("--collapsed")
        let alwaysExpanded = CommandLine.arguments.contains("--always-expanded")
        let autoDelay: TimeInterval = alwaysExpanded ? 999_999 : 4.0

        let effect = ProbeEffect(
            versionTag: "V10 融合态",
            subtitleTag: "Ego Lite × V6 智能折叠",
            shaderFragmentSource: v10FragmentShader,
            bannerMode: .smartCollapsible(startCollapsed: startCollapsed, autoCollapseDelay: autoDelay),
            setupExtraMenuItems: { menu, probe in
                if alwaysExpanded {
                    probe.setBannerPinned(true)
                }
                let helper = V10MenuHelper(probe: probe)
                menuHelper = helper
                menu.addItem(.separator())
                let fold = NSMenuItem(title: "展开 / 折叠控制条", action: #selector(V10MenuHelper.toggleFoldState), keyEquivalent: "f")
                fold.target = helper
                menu.addItem(fold)
            }
        )
        runProbeMain(effect: effect, extraUsage: "[--collapsed | --always-expanded]")
    }
}
