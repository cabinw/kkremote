import AppKit

// V5: Ego Lite (1:1 Frame-Calibrated Reproduction)
// Derived directly from pixel & temporal analysis of Screen_Recording_2026-11-13_at_15.38.14.mov:
// 1) Airbrushed pastel cornflower/periwinkle halo breathing in ~1.77s top+bottom+corners vs
//    left+right middle opposition, modulated by a slower ~3.53s harmonic.
// 2) Full-window stationary 9.0 pt pinpoint dot matrix (sigma ~ 0.46 pt, crisp Retina dot,
//    never blurred polka dots or bent coordinates) gently visible across the entire canvas.
// 3) Sweeping right-to-left diagonal/vertical light veil (~1.55s period) that lifts dot
//    luminance across the whole window and ignites organic curtain sparkles along its crest.
// 4) Soft frosted white inner rim highlight (~1.5 pt) along the continuous n=2.85 squircle edge.

private let v5FragmentShader = """
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

    // 1) Perimeter ~1.77s opposition breath + ~3.53s envelope (corners+top/bot vs left/right mid).
    float2 c = uv - 0.5;
    float cLen2 = dot(c, c) + 1e-4;
    // Left/right middle sides peak when |c.x| dominates and |c.y| is near 0; corners & top/bot behave together.
    float midSideMask = smoothstep(0.18, 0.88, (c.x * c.x - c.y * c.y) / cLen2)
                      * smoothstep(0.46, 0.06, abs(c.y));

    const float omegaFast = 3.55; // 2*pi / 1.77s
    const float omegaSlow = 1.78; // 2*pi / 3.53s
    float slowEnv = 0.72 + 0.28 * sin(t * omegaSlow + 0.4 + c.x * 0.65);
    float tbWave = (0.5 + 0.5 * cos(t * omegaFast + c.x * 0.85)) * slowEnv;
    float lrWave = (0.5 + 0.5 * cos(t * omegaFast + M_PI_F + c.y * 0.85)) * (1.06 - 0.16 * sin(t * omegaSlow));
    float sideBreath = mix(tbWave, lrWave, midSideMask);

    // Gentle moving corner/edge cloud drift so the airbrushed mist never looks geometrically static.
    float ang = perimeterAngle(p, size);
    float cloudA = pow(max(0.5 + 0.5 * cos(ang - t * 0.92), 0.0), 2.0);
    float cloudB = pow(max(0.5 + 0.5 * cos(ang + t * 0.64 + 1.4), 0.0), 2.4) * 0.55;
    float haloEnergy = clamp(0.14 + 0.78 * sideBreath + 0.30 * (cloudA + cloudB - 0.55), 0.10, 1.32);

    // 2) Airbrushed Pastel Cornflower / Periwinkle / Sky-Mist Palette calibrated to Ego measurements.
    // Peak border color on white matches B-R ~ 115..135 at high tide and ~15..26 at trough.
    float3 lightCoreBlue = float3(0.25, 0.49, 0.99);
    float3 lightSoftBlue = float3(0.42, 0.62, 0.99);
    float3 lightMistTint = float3(0.68, 0.80, 0.99);

    float3 darkCoreBlue = float3(0.26, 0.54, 1.00);
    float3 darkSoftBlue = float3(0.44, 0.50, 1.00);
    float3 darkMistTint = float3(0.56, 0.76, 1.00);

    float3 colCore = mix(lightCoreBlue, darkCoreBlue, U.dark);
    float3 colSoft = mix(lightSoftBlue, darkSoftBlue, U.dark);
    float3 colMist = mix(lightMistTint, darkMistTint, U.dark);

    // Wide airbrushed perimeter falloff + subtle corner bloom + whisper-soft whole-window cool atmospheric veil.
    float haloSpan = clamp(minDim * mix(0.18, 0.25, styleT), 88.0, 170.0);
    float cornerFactor = smoothstep(0.12, 0.48, abs(c.x)) * smoothstep(0.12, 0.48, abs(c.y));
    float localSpan = haloSpan * (1.0 + 0.24 * cornerFactor);

    float edgeOuter = exp(-pow(max(d - 1.5, 0.0) / (localSpan * 0.45), 1.38));
    float edgeInner = exp(-pow(max(d - 1.5, 0.0) / (localSpan * 0.96), 1.68)) * 0.46;
    float haloField = clamp(edgeOuter * 0.84 + edgeInner, 0.0, 1.0);

    // Sweeping right-to-left soft translucent veil / wave band (~1.55s period, slight tilt).
    const float waveOmega = 4.05; // 2*pi / 1.55s
    float waveCoord = uv.x + 0.14 * uv.y;
    float wavePhase = waveCoord * 3.8 + t * waveOmega; // travels smoothly from right -> left
    float waveCrest = pow(max(0.5 + 0.5 * sin(wavePhase), 0.0), 2.8);
    float secondaryRipple = 0.5 + 0.5 * sin(uv.x * 2.2 - t * 1.35 + uv.y * 1.6);

    float centerAtmos = mix(0.015, 0.036, styleT) + waveCrest * mix(0.018, 0.040, styleT);
    float edgePeakA = mix(0.44, 0.76, styleT) * mix(1.0, 0.88, U.dark);
    float washA = clamp(centerAtmos + haloField * edgePeakA * haloEnergy, 0.0, 0.78);

    float tintMix = 0.5 + 0.5 * sin(ang * 1.5 - t * 0.65);
    float3 perimCol = mix(colCore, colSoft, 0.45 * tintMix);
    float3 baseVeilCol = mix(float3(0.91, 0.94, 0.99), float3(0.16, 0.24, 0.42), U.dark);
    float3 haloCol = mix(baseVeilCol, mix(colMist, perimCol, smoothstep(0.06, 0.68, edgeOuter)), smoothstep(0.02, 0.35, haloField));

    // Soft bright white frosted rim hugging the rounded window perimeter (1.5 pt highlight + 5 pt bloom).
    float rimLine = exp(-pow(max(d - 1.10, 0.0) / 0.95, 2.0));
    float rimBloom = exp(-pow(max(d - 1.8, 0.0) / 5.5, 2.0));
    float rimA = clamp((rimLine * 0.62 + rimBloom * 0.14) * mix(0.65, 1.05, styleT) * (0.72 + 0.28 * haloEnergy) * mix(1.0, 0.60, U.dark), 0.0, 0.76);

    // 3) Stationary 9.0 pt Orthogonal Pinpoint Dot Matrix covering the ENTIRE window.
    // Measured directly from Ego crop: pitch = 9.0 pt, crisp dot sigma = 0.46 pt (no muddy glow, no bent grid).
    const float dotSpacing = 9.0;
    float2 cell = floor(p / dotSpacing);
    float2 local = (fract(p / dotSpacing) - 0.5) * dotSpacing;
    float dist2 = dot(local, local);
    float dotKernel = exp(-dist2 / (2.0 * 0.46 * 0.46));

    // Quiet base visibility: subtle across entire window center (0.09..0.15) & gently richer in halo (0.24..0.38).
    float baseCenterDot = mix(0.065, 0.145, styleT);
    float baseEdgeDot = mix(0.20, 0.36, styleT) * haloField * (0.65 + 0.35 * haloEnergy);
    // Passing wave gently lifts dot luminosity across the whole window (like GPay & shopPay telemetry).
    float waveDotLift = waveCrest * mix(0.18, 0.40, styleT) * (0.48 + 0.52 * haloField + 0.25 * secondaryRipple);

    // Curtain / Constellation Sparkles along the passing wave crest (organic noise curtain + pinpoint stars).
    float2 worldCellPos = (cell + 0.5) * dotSpacing;
    float curtainNoise = valueNoise(worldCellPos * 0.022 + float2(t * 0.85, -t * 0.32));
    float subNoise = valueNoise(worldCellPos * 0.055 - float2(t * 0.45, t * 0.28));
    float patchGate = smoothstep(0.58, 0.82, curtainNoise * 0.68 + subNoise * 0.32);

    float dSeed = hash21(cell + 17.3);
    float twkClk = t * (0.55 + 0.45 * dSeed) + dSeed * 31.0;
    float twkPh = fract(twkClk);
    float twkHash = hash21(cell + floor(twkClk) * 4.19);
    float twkEnv = smoothstep(0.0, 0.18, twkPh) * (1.0 - smoothstep(0.18, 0.58, twkPh));

    // Curtain-driven bright white dots + subtle random star sparks boosted near the wave crest.
    float curtainSpark = patchGate * smoothstep(0.38, 0.92, waveCrest) * step(0.42, hash21(cell + floor(twkClk * 0.5) * 2.17))
                       * (0.45 + 0.55 * twkEnv) * mix(0.42, 0.82, styleT);
    float pinSpark = (twkHash > 0.972 ? twkEnv : 0.0) * (0.42 + 0.58 * waveCrest) * mix(0.45, 0.85, styleT);

    float dotA = clamp(dotKernel * (baseCenterDot + baseEdgeDot + waveDotLift + curtainSpark + pinSpark), 0.0, 0.94);

    // 4) Premultiplied Porter-Duff compositing.
    float3 col = haloCol * washA;
    float a = washA;

    float3 veilStreakCol = mix(float3(0.95, 0.97, 1.00), float3(0.62, 0.78, 1.00), U.dark);
    float streakA = clamp(waveCrest * (0.025 + 0.035 * haloField) * mix(0.55, 1.15, styleT) * mix(1.0, 0.48, U.dark), 0.0, 0.12);
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

@main
enum V5ProbeEntry {
    static func main() {
        let effect = ProbeEffect(
            versionTag: "V5 Ego Lite",
            subtitleTag: "样式预览 · V5 Ego Lite 柔光点阵",
            shaderFragmentSource: v5FragmentShader
        )
        runProbeMain(effect: effect)
    }
}
