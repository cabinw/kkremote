#if os(macOS)
import AppKit
import CoreGraphics
import Metal
import QuartzCore

enum ControlledOverlayTheme: Int, CaseIterable {
    case aurora = 0
    case prism = 1
    case matrix = 2
    case ambilight = 3
    case silk = 4

    var cliKey: String {
        switch self {
        case .aurora: return "aurora"
        case .prism: return "prism"
        case .matrix: return "matrix"
        case .ambilight: return "ambilight"
        case .silk: return "silk"
        }
    }

    var shortTitle: String {
        switch self {
        case .aurora: return "星点极光"
        case .prism: return "棱镜光带"
        case .matrix: return "柔光点阵"
        case .ambilight: return "外溢光环"
        case .silk: return "丝绸流光"
        }
    }

    var menuTitle: String {
        switch self {
        case .aurora: return "星点极光 · 五色渐变与随机星闪 (V1)"
        case .prism: return "棱镜光带 · 清透中心六色流光边 (V2)"
        case .matrix: return "柔光点阵 · 呼吸光晕与扫光浪 (V5)"
        case .ambilight: return "外溢光环 · 窗外 40pt 呼吸氛围光 (V7)"
        case .silk: return "丝绸流光 · 薄膜干涉波动极光边 (V9)"
        }
    }

    var outerPadding: CGFloat {
        switch self {
        case .ambilight: return 40
        default: return 0
        }
    }

    static func fromCLI(_ raw: String) -> ControlledOverlayTheme? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch key {
        case "v1", "aurora", "星点极光": return .aurora
        case "v2", "prism", "棱镜光带": return .prism
        case "v5", "matrix", "ego", "柔光点阵": return .matrix
        case "v7", "ambilight", "halo", "外溢光环", "外溢环境光": return .ambilight
        case "v9", "silk", "丝绸流光", "丝绸极光边": return .silk
        default: return nil
        }
    }
}

enum ControlledOverlayStyle: Int, CaseIterable {
    case subtle = 0
    case standard = 1
    case vivid = 2

    var title: String { ["柔和", "标准", "鲜明"][rawValue] }
    var intensity: Double { [0.75, 1.0, 1.32][rawValue] }
}

private struct OverlayWindowSnapshot {
    let id: CGWindowID
    let pid: pid_t
    let owner: String
    let title: String
    let frame: CGRect
    let layer: Int

    static func visible() -> [OverlayWindowSnapshot] {
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let id = row[kCGWindowNumber as String] as? UInt32,
                  let pid = row[kCGWindowOwnerPID as String] as? Int32,
                  let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  (row[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { return nil }
            return OverlayWindowSnapshot(
                id: id,
                pid: pid,
                owner: row[kCGWindowOwnerName as String] as? String ?? "",
                title: row[kCGWindowName as String] as? String ?? "",
                frame: frame,
                layer: row[kCGWindowLayer as String] as? Int ?? 0
            )
        }
    }

    var appKitFrame: NSRect {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        return NSRect(x: frame.minX, y: primaryTop - frame.maxY, width: frame.width, height: frame.height)
    }
}

private final class ControlledOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(interactive: Bool) {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        ignoresMouseEvents = !interactive
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        level = .normal
        animationBehavior = .none
    }
}

// MARK: - Multi-Style Metal Shader & Canvas (V1 / V2 / V5 / V7 / V9)

private let multiOverlayShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 size;       // panel size in points
    float2 winSize;    // controlled window size in points
    float scale;       // pixels per point
    float time;        // seconds
    float radius;      // window corner radius, points
    float intensity;   // style multiplier (0.75 / 1.0 / 1.32)
    float dark;        // 0 light ... 1 dark
    float presence;    // fade-in 0 ... 1
    float outerPad;    // exterior padding around window, points
    int themeIndex;    // 0=aurora, 1=prism, 2=matrix, 3=ambilight, 4=silk
};

struct VOut { float4 position [[position]]; };

vertex VOut overlayVertex(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    VOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

static float perimeterAngle(float2 p, float2 size) {
    float2 c = p - size * 0.5;
    float2 asp = float2(1.0, size.x / max(size.y, 1.0));
    return atan2(c.y * asp.y, c.x * asp.x);
}

static float3 linearRamp5(float s, float3 c0, float3 c1, float3 c2, float3 c3, float3 c4) {
    float u = clamp(s, 0.0, 1.0) * 4.0;
    float3 a = mix(c0, c1, smoothstep(0.0, 1.0, u));
    a = mix(a, c2, smoothstep(1.0, 2.0, u));
    a = mix(a, c3, smoothstep(2.0, 3.0, u));
    return mix(a, c4, smoothstep(3.0, 4.0, u));
}

static float insideDistance(float2 p, float2 size, float r) {
    float2 h = size * 0.5;
    float R = clamp(r, 0.0, min(h.x, h.y));
    float2 q = abs(p - h) - (h - R);
    if (R <= 0.001) {
        return -max(q.x, q.y);
    }
    if (q.x > 0.0 && q.y > 0.0) {
        const float n = 2.85;
        float2 t = q / R;
        float F = pow(t.x, n) + pow(t.y, n);
        float s = pow(F, 1.0 / n);
        float gx = pow(t.x, n - 1.0);
        float gy = pow(t.y, n - 1.0);
        float grad = length(float2(gx, gy)) * pow(max(F, 1e-6), (1.0 - n) / n);
        return R * (1.0 - s) / max(grad, 0.5);
    }
    return R - max(q.x, q.y);
}

static float smoothEdgeProximity(float2 p, float2 size, float width) {
    float dx = max(min(p.x, size.x - p.x), 0.0);
    float dy = max(min(p.y, size.y - p.y), 0.0);
    float ex = exp(-dx / width);
    float ey = exp(-dy / width);
    return 1.0 - (1.0 - ex) * (1.0 - ey);
}

// --- Theme 0: V1 Aurora + Star Matrix ---
static float4 renderV1Aurora(float2 p, float2 size, float2 fragPos, constant Uniforms& U) {
    float t = U.time;
    float d = insideDistance(p, size, U.radius);
    float coverage = clamp(d * U.scale + 0.5, 0.0, 1.0);
    if (coverage <= 0.0) { return float4(0.0); }

    float2 uv = p / size;
    float unit = clamp(min(size.x, size.y), 320.0, 900.0);
    float2 pn = (p - size * 0.5) / unit;
    float2 asp = float2(size.x / size.y, 1.0);

    float edgeWidth = clamp(min(size.x, size.y) * 0.18, 36.0, 125.0);
    float edge = smoothEdgeProximity(p, size, edgeWidth);
    float rim = smoothEdgeProximity(p, size, edgeWidth * 0.38);
    float k = U.intensity;

    float theta = t * 0.72;
    float2 dir = float2(cos(theta), sin(theta));
    float2 ortho = float2(-dir.y, dir.x);
    float2 pNorm = (uv - 0.5) * 2.0;
    float gentleCurve = 0.055 * sin(dot(pNorm, ortho) * 1.6 - t * 0.85);
    float s = clamp(0.50 + 0.38 * dot(pNorm, dir) + gentleCurve, 0.0, 1.0);

    float3 pastel = linearRamp5(s, float3(0.56, 0.68, 1.00), float3(0.74, 0.54, 1.00), float3(1.00, 0.54, 0.84), float3(1.00, 0.60, 0.46), float3(1.00, 0.84, 0.44));
    float3 richGlow = linearRamp5(s, float3(0.38, 0.54, 1.00), float3(0.64, 0.36, 1.00), float3(1.00, 0.34, 0.74), float3(1.00, 0.44, 0.26), float3(1.00, 0.78, 0.22));
    float3 darkCool = linearRamp5(s, float3(0.44, 0.62, 1.00), float3(0.66, 0.42, 1.00), float3(1.00, 0.44, 0.80), float3(0.84, 0.52, 0.96), float3(0.72, 0.58, 1.00));
    float3 darkEdge = linearRamp5(s, float3(0.42, 0.58, 1.00), float3(0.68, 0.38, 1.00), float3(1.00, 0.38, 0.78), float3(1.00, 0.48, 0.34), float3(1.00, 0.80, 0.30));

    float3 lightCol = mix(pastel, richGlow, smoothstep(0.0, 0.88, edge) * 0.95);
    float3 darkCol = mix(darkCool, darkEdge, smoothstep(0.22, 0.80, edge));
    float3 color = mix(lightCol, darkCol, U.dark);

    float angle = atan2((uv.y - 0.5) * asp.y, (uv.x - 0.5) * asp.x);
    float arc = pow(max(0.5 + 0.5 * cos(2.0 * (angle - t * 0.95)), 0.0), 2.8);
    float crest = pow(max(0.5 + 0.5 * cos(angle - theta), 0.0), 2.2) * 0.70
                + pow(max(0.5 + 0.5 * cos(angle - theta + M_PI_F), 0.0), 3.0) * 0.35;
    float highlight = clamp(0.15 * arc * rim + 0.05 * crest * edge, 0.0, 1.0);
    color = mix(color, min(color * 1.15 + 0.12, float3(1.0)), highlight);

    float centerAlpha = mix(0.075, 0.070, U.dark) * k;
    float edgeAlpha = min(0.90, 0.76 * (0.72 + 0.28 * k));
    float colorAlpha = clamp(mix(centerAlpha, edgeAlpha, pow(max(edge, 0.0), 1.32))
                             + (0.07 * arc * rim + 0.025 * crest * edge) * k, 0.0, 0.92);

    float3 fogColor = mix(float3(0.95, 0.94, 1.00), float3(0.28, 0.24, 0.56), U.dark);
    float fogAlpha = mix(0.025, 0.038, U.dark) * (0.65 + 0.35 * k) * (1.0 - 0.72 * edge);

    float4 outc = float4(fogColor * fogAlpha, fogAlpha);
    outc = float4(color * colorAlpha, colorAlpha) + outc * (1.0 - colorAlpha);

    const float spacing = 8.5;
    float2 g = p / spacing;
    float2 cell = floor(g);
    float2 f = (fract(g) - 0.5) * spacing;
    float r2 = dot(f, f);

    float seed = hash21(cell + 31.7);
    float rate = 0.26 + 0.32 * hash21(cell + 9.1);
    float phaseClock = t * rate + seed * 19.0;
    float cycle = floor(phaseClock);
    float ph = fract(phaseClock);
    float gate = hash21(cell + float2(cycle * 3.17, 11.4));
    float env = smoothstep(0.0, 0.14, ph) * (1.0 - smoothstep(0.14, 0.48, ph));
    float sparkMain = gate > 0.952 ? env : 0.0;
    float sparkSoft = (gate > 0.875 && gate <= 0.952) ? env : 0.0;

    float sigma = 0.42 + 0.36 * sparkMain + 0.15 * sparkSoft;
    float haloWeight = 0.07 + 0.30 * sparkMain + 0.09 * sparkSoft;
    float dotShape = exp(-r2 / (2.0 * sigma * sigma)) + haloWeight * exp(-r2 / (2.0 * 1.45 * 1.45));

    float edgeDots = pow(max(edge, 0.0), 1.35);
    float baseDot = mix(mix(0.028, 0.30, edgeDots), mix(0.018, 0.26, edgeDots), U.dark);
    float radialPulse = 0.5 + 0.5 * sin(length(pn) * 6.0 - t * 2.2);
    float waveDot = (0.14 * crest + 0.04 * radialPulse) * (0.18 + 0.82 * edge);
    float twinkle = (0.90 * sparkMain + 0.36 * sparkSoft) * (0.34 + 0.66 * edge);
    float dotLevel = baseDot + waveDot + 0.12 * arc * rim + twinkle;
    float dotAlpha = clamp(dotShape * dotLevel, 0.0, 0.95) * mix(0.94, 0.90, U.dark);
    outc = float4(float3(dotAlpha), dotAlpha) + outc * (1.0 - dotAlpha);

    float grain = (hash21(fragPos) - 0.5) * (2.5 / 255.0);
    outc.rgb = clamp(outc.rgb + grain * outc.a, 0.0, outc.a);
    return outc * (coverage * U.presence);
}

// --- Theme 1: V2 Minimal Perimeter Prism Ribbon ---
static float3 cyclicPrism6(float phase, float darkMode) {
    float u = fract(phase) * 6.0;
    int idx = int(floor(u)) % 6;
    float f = smoothstep(0.0, 1.0, fract(u));
    float3 lightPalette[6] = {
        float3(0.22, 0.46, 1.00), float3(0.58, 0.24, 1.00), float3(0.98, 0.20, 0.66),
        float3(1.00, 0.38, 0.16), float3(1.00, 0.72, 0.12), float3(0.84, 0.44, 0.96)
    };
    float3 darkPalette[6] = {
        float3(0.40, 0.66, 1.00), float3(0.70, 0.42, 1.00), float3(1.00, 0.38, 0.78),
        float3(1.00, 0.52, 0.30), float3(1.00, 0.84, 0.36), float3(0.84, 0.60, 1.00)
    };
    int nextIdx = (idx + 1) % 6;
    return mix(mix(lightPalette[idx], lightPalette[nextIdx], f),
               mix(darkPalette[idx], darkPalette[nextIdx], f), darkMode);
}

static float4 renderV2Prism(float2 p, float2 size, float2 fragPos, constant Uniforms& U) {
    float d = insideDistance(p, size, U.radius);
    float coverage = clamp(d * U.scale + 0.5, 0.0, 1.0);
    if (coverage <= 0.0) { return float4(0.0); }
    float styleT = clamp((U.intensity - 0.75) / 0.57, 0.0, 1.0);
    float maxReach = mix(110.0, 195.0, styleT);
    if (d > maxReach) { return float4(0.0); }

    float t = U.time;
    float ang = perimeterAngle(p, size);
    float packet1 = pow(max(0.5 + 0.5 * cos(ang - t * 1.15), 0.0), 3.0);
    float packet2 = pow(max(0.5 + 0.5 * cos(2.0 * (ang + t * 0.48) - 1.1), 0.0), 3.6) * 0.70;
    float packet3 = pow(max(0.5 + 0.5 * cos(ang - t * 1.15 + M_PI_F), 0.0), 4.2) * 0.58;
    float caustic = clamp(packet1 + packet2 + packet3, 0.0, 1.35);

    float phaseBase = ang / (M_PI_F * 2.0) - t * 0.14;
    float disp = (d - 3.0) * 0.0026;
    float3 prismCol = mix(cyclicPrism6(phaseBase + disp, U.dark),
                          cyclicPrism6(phaseBase - disp, U.dark),
                          smoothstep(0.0, 22.0, d));

    float rimWidth = mix(2.2, 4.4, styleT) + 1.35 * caustic;
    float rimCore = exp(-pow(max(d - 1.6, 0.0) / rimWidth, 2.0));
    float innerRimCatch = exp(-pow(abs(d - mix(4.0, 7.0, styleT)) / mix(3.2, 5.2, styleT), 2.0)) * 0.48;
    float featherWidth = mix(22.0, 44.0, styleT) * (0.86 + 0.34 * caustic);
    float feather = exp(-max(d - 1.4, 0.0) / featherWidth) * smoothstep(maxReach, 8.0, d);

    float crestPeak = pow(clamp(caustic, 0.0, 1.0), 2.4);
    float3 rimColor = mix(prismCol, min(prismCol * 1.20 + 0.22, float3(1.0)), U.dark * 0.45 + 0.24 * crestPeak);
    float lineAlpha = clamp((rimCore + innerRimCatch * 0.65) * mix(0.76, 0.96, styleT) * (0.70 + 0.30 * min(caustic, 1.0)), 0.0, 0.96);
    float washAlpha = clamp(feather * mix(0.30, 0.62, styleT) * mix(0.88, 1.0, U.dark) * (0.64 + 0.48 * caustic), 0.0, 0.88);

    float3 finalRGB = prismCol * washAlpha;
    float finalA = washAlpha;
    finalRGB = rimColor * lineAlpha + finalRGB * (1.0 - lineAlpha);
    finalA = lineAlpha + finalA * (1.0 - lineAlpha);

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

    float grain = (hash21(fragPos) - 0.5) * (2.0 / 255.0);
    finalRGB = clamp(finalRGB + grain * finalA, 0.0, finalA);
    return float4(finalRGB, finalA) * (coverage * U.presence);
}

// --- Theme 2: V5 Soft Matrix + Sweeping Veil ---
static float4 renderV5Matrix(float2 p, float2 size, float2 fragPos, constant Uniforms& U) {
    float d = insideDistance(p, size, U.radius);
    float coverage = clamp(d * U.scale + 0.5, 0.0, 1.0);
    if (coverage <= 0.0) { return float4(0.0); }
    float t = U.time;
    float styleT = clamp((U.intensity - 0.75) / 0.57, 0.0, 1.0);
    float2 uv = p / size;
    float minDim = min(size.x, size.y);

    float2 c = uv - 0.5;
    float cLen2 = dot(c, c) + 1e-4;
    float midSideMask = smoothstep(0.18, 0.88, (c.x * c.x - c.y * c.y) / cLen2)
                      * smoothstep(0.46, 0.06, abs(c.y));
    const float omegaFast = 3.55;
    const float omegaSlow = 1.78;
    float slowEnv = 0.72 + 0.28 * sin(t * omegaSlow + 0.4 + c.x * 0.65);
    float tbWave = (0.5 + 0.5 * cos(t * omegaFast + c.x * 0.85)) * slowEnv;
    float lrWave = (0.5 + 0.5 * cos(t * omegaFast + M_PI_F + c.y * 0.85)) * (1.06 - 0.16 * sin(t * omegaSlow));
    float sideBreath = mix(tbWave, lrWave, midSideMask);

    float ang = perimeterAngle(p, size);
    float cloudA = pow(max(0.5 + 0.5 * cos(ang - t * 0.92), 0.0), 2.0);
    float cloudB = pow(max(0.5 + 0.5 * cos(ang + t * 0.64 + 1.4), 0.0), 2.4) * 0.55;
    float haloEnergy = clamp(0.14 + 0.78 * sideBreath + 0.30 * (cloudA + cloudB - 0.55), 0.10, 1.32);

    float3 colCore = mix(float3(0.25, 0.49, 0.99), float3(0.26, 0.54, 1.00), U.dark);
    float3 colSoft = mix(float3(0.42, 0.62, 0.99), float3(0.44, 0.50, 1.00), U.dark);
    float3 colMist = mix(float3(0.68, 0.80, 0.99), float3(0.56, 0.76, 1.00), U.dark);

    float haloSpan = clamp(minDim * mix(0.18, 0.25, styleT), 88.0, 170.0);
    float cornerFactor = smoothstep(0.12, 0.48, abs(c.x)) * smoothstep(0.12, 0.48, abs(c.y));
    float localSpan = haloSpan * (1.0 + 0.24 * cornerFactor);
    float edgeOuter = exp(-pow(max(d - 1.5, 0.0) / (localSpan * 0.45), 1.38));
    float edgeInner = exp(-pow(max(d - 1.5, 0.0) / (localSpan * 0.96), 1.68)) * 0.46;
    float haloField = clamp(edgeOuter * 0.84 + edgeInner, 0.0, 1.0);

    const float waveOmega = 4.05;
    float wavePhase = (uv.x + 0.14 * uv.y) * 3.8 + t * waveOmega;
    float waveCrest = pow(max(0.5 + 0.5 * sin(wavePhase), 0.0), 2.8);
    float secondaryRipple = 0.5 + 0.5 * sin(uv.x * 2.2 - t * 1.35 + uv.y * 1.6);

    float centerAtmos = mix(0.015, 0.036, styleT) + waveCrest * mix(0.018, 0.040, styleT);
    float edgePeakA = mix(0.44, 0.76, styleT) * mix(1.0, 0.88, U.dark);
    float washA = clamp(centerAtmos + haloField * edgePeakA * haloEnergy, 0.0, 0.78);

    float tintMix = 0.5 + 0.5 * sin(ang * 1.5 - t * 0.65);
    float3 perimCol = mix(colCore, colSoft, 0.45 * tintMix);
    float3 baseVeilCol = mix(float3(0.91, 0.94, 0.99), float3(0.16, 0.24, 0.42), U.dark);
    float3 haloCol = mix(baseVeilCol, mix(colMist, perimCol, smoothstep(0.06, 0.68, edgeOuter)), smoothstep(0.02, 0.35, haloField));

    float rimLine = exp(-pow(max(d - 1.10, 0.0) / 0.95, 2.0));
    float rimBloom = exp(-pow(max(d - 1.8, 0.0) / 5.5, 2.0));
    float rimA = clamp((rimLine * 0.62 + rimBloom * 0.14) * mix(0.65, 1.05, styleT) * (0.72 + 0.28 * haloEnergy) * mix(1.0, 0.60, U.dark), 0.0, 0.76);

    const float dotSpacing = 9.0;
    float2 cell = floor(p / dotSpacing);
    float2 local = (fract(p / dotSpacing) - 0.5) * dotSpacing;
    float dotKernel = exp(-dot(local, local) / (2.0 * 0.46 * 0.46));

    float baseCenterDot = mix(0.065, 0.145, styleT);
    float baseEdgeDot = mix(0.20, 0.36, styleT) * haloField * (0.65 + 0.35 * haloEnergy);
    float waveDotLift = waveCrest * mix(0.18, 0.40, styleT) * (0.48 + 0.52 * haloField + 0.25 * secondaryRipple);

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
    float pinSpark = (twkHash > 0.972 ? twkEnv : 0.0) * (0.42 + 0.58 * waveCrest) * mix(0.45, 0.85, styleT);
    float dotA = clamp(dotKernel * (baseCenterDot + baseEdgeDot + waveDotLift + curtainSpark + pinSpark), 0.0, 0.94);

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

    float grain = (hash21(fragPos) - 0.5) * (1.5 / 255.0);
    col = clamp(col + grain * a, 0.0, a);
    return float4(col, a) * (coverage * U.presence);
}

// --- Theme 3: V7 Out-of-Frame Ambilight Halo ---
static float4 renderV7Ambilight(float2 pPanel, float2 winSize, constant Uniforms& U) {
    float2 pWin = pPanel - float2(U.outerPad, U.outerPad);
    float d = insideDistance(pWin, winSize, U.radius);
    if (d > 4.0) { return float4(0.0); }
    float theta = perimeterAngle(pWin, winSize);
    float styleT = clamp((U.intensity - 0.75) / 0.57, 0.0, 1.0);
    float outPad = max(U.outerPad, 1.0);

    float wave = 0.045 * sin(theta * 2.0 + U.time * 0.75)
               + 0.025 * cos(theta * 3.0 - U.time * 0.55);
    float flow = fract(theta / (2.0 * M_PI_F) + 0.5 - U.time * 0.045 + wave);

    float3 haloCol = mix(
        linearRamp5(flow, float3(0.02, 0.62, 0.96), float3(0.18, 0.36, 0.98), float3(0.54, 0.20, 0.95), float3(0.92, 0.22, 0.54), float3(0.02, 0.62, 0.96)),
        linearRamp5(flow, float3(0.22, 0.84, 1.00), float3(0.38, 0.56, 1.00), float3(0.72, 0.42, 1.00), float3(1.00, 0.46, 0.72), float3(0.22, 0.84, 1.00)),
        U.dark
    );

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

    float rimWidth = mix(0.95, 1.32, styleT);
    float innerRim = exp(-pow((d - 0.55) / rimWidth, 2.0))
                   * smoothstep(-1.1, -0.1, d)
                   * smoothstep(3.6, 1.0, d);
    float cornerBoost = 1.0 + 0.18 * pow(abs(sin(2.0 * theta)), 2.2);
    float rimAlpha = innerRim * cornerBoost * mix(0.42, 0.84, styleT) * (0.90 + 0.10 * breath);

    float specularMix = innerRim * (0.14 + 0.24 * U.dark);
    float3 rimCol = mix(haloCol, float3(1.0), specularMix);
    float sumW = outerAlpha + rimAlpha + 1e-5;
    float3 finalRGB = (haloCol * outerAlpha + rimCol * rimAlpha) / sumW;
    float alpha = 1.0 - (1.0 - clamp(outerAlpha, 0.0, 0.88)) * (1.0 - clamp(rimAlpha, 0.0, 0.90));
    alpha = clamp(alpha, 0.0, 0.92) * U.presence;
    return float4(finalRGB * alpha, alpha);
}

// --- Theme 4: V9 Silk Interference Aurora Ribbon ---
static float3 interferencePalette(float t, float dark) {
    float u = fract(t) * 5.0;
    float3 l0 = float3(0.00, 0.64, 0.92), l1 = float3(0.14, 0.36, 0.98), l2 = float3(0.56, 0.18, 0.94), l3 = float3(0.92, 0.18, 0.54), l4 = float3(0.95, 0.44, 0.22);
    float3 d0 = float3(0.24, 0.88, 1.00), d1 = float3(0.38, 0.58, 1.00), d2 = float3(0.76, 0.40, 1.00), d3 = float3(1.00, 0.42, 0.74), d4 = float3(1.00, 0.66, 0.38);
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

static float4 renderV9Silk(float2 p, float2 size, constant Uniforms& U) {
    float d = insideDistance(p, size, U.radius);
    if (d < -0.5) { return float4(0.0); }
    float theta = perimeterAngle(p, size);
    float styleT = clamp((U.intensity - 0.75) / 0.57, 0.0, 1.0);
    float waveA = sin(theta * 2.0 - U.time * 0.90);
    float waveB = sin(theta * 3.0 + U.time * 1.25);
    float waveC = cos(theta * 5.0 - U.time * 0.65);

    float cornerFactor = pow(abs(sin(2.0 * theta)), 1.8);
    float reachBase = mix(14.0, 25.0, styleT) + cornerFactor * mix(5.0, 9.0, styleT);
    float ribbonReach = max(6.0, reachBase + waveA * mix(4.5, 8.5, styleT) + waveB * 3.0);
    if (d > ribbonReach * 1.38 + 6.0) { return float4(0.0); }

    float filmShift = d * 0.011 + 0.065 * waveA + 0.04 * waveC;
    float basePhase = theta / (2.0 * M_PI_F) + 0.5 - U.time * 0.055 + filmShift;
    float3 silkCol = interferencePalette(basePhase, U.dark);
    float3 shiftCol = interferencePalette(basePhase + 0.16, U.dark);

    float foldCoord = d * 0.23 - U.time * 1.65 + theta * 2.0 + 1.2 * waveA;
    float caustic1 = pow(0.5 + 0.5 * sin(foldCoord), 4.0);
    float caustic2 = pow(0.5 + 0.5 * sin(foldCoord * 1.65 + 1.4 - theta), 5.0);
    float sheen = clamp(caustic1 * 0.75 + caustic2 * 0.55, 0.0, 1.15);

    float edgeMask = smoothstep(-0.15, 0.35, d);
    float spineW = mix(1.35, 2.25, styleT) * (0.90 + 0.18 * (0.5 + 0.5 * waveA));
    float spine = exp(-pow((d - 1.35) / spineW, 2.0)) * edgeMask;
    float innerThread = exp(-pow((d - 3.6 - 1.4 * waveB) / 0.85, 2.0))
                      * smoothstep(14.0, 3.0, d) * (0.45 + 0.55 * caustic1);
    float curtain = exp(-max(d, 0.0) / max(ribbonReach * 0.52, 1.0))
                  * (1.0 - smoothstep(ribbonReach * 0.65, ribbonReach * 1.32, d))
                  * edgeMask;

    float spineAlpha = spine * mix(0.58, 0.94, styleT);
    float threadAlpha = innerThread * mix(0.24, 0.54, styleT);
    float curtainAlpha = curtain * mix(0.18, 0.44, styleT) * (0.72 + 0.38 * sheen);

    float3 causticCol = mix(silkCol, shiftCol, 0.55);
    causticCol = mix(causticCol, float3(1.0), (0.28 + 0.22 * U.dark) * clamp(caustic1, 0.0, 1.0));
    float3 curtainCol = mix(silkCol, causticCol, clamp(sheen * 0.85, 0.0, 1.0));
    float3 threadCol = mix(shiftCol, float3(1.0), 0.48);
    float3 spineCol = mix(silkCol, float3(1.0), (0.14 + 0.25 * U.dark) * spine);

    float wSum = spineAlpha + threadAlpha + curtainAlpha + 1e-5;
    float3 finalRGB = (spineCol * spineAlpha + threadCol * threadAlpha + curtainCol * curtainAlpha) / wSum;
    float alpha = 1.0 - (1.0 - clamp(spineAlpha, 0.0, 0.95))
                      * (1.0 - clamp(threadAlpha, 0.0, 0.70))
                      * (1.0 - clamp(curtainAlpha, 0.0, 0.72));
    alpha = clamp(alpha, 0.0, 0.95) * U.presence;
    return float4(finalRGB * alpha, alpha);
}

fragment float4 overlayFragment(VOut in [[stage_in]], constant Uniforms& U [[buffer(0)]]) {
    if (U.presence <= 0.001) { return float4(0.0); }
    float2 pPanel = in.position.xy / max(U.scale, 1.0);
    float2 winSize = max(U.winSize, float2(1.0));
    switch (U.themeIndex) {
        case 1: return renderV2Prism(pPanel - float2(U.outerPad), winSize, in.position.xy, U);
        case 2: return renderV5Matrix(pPanel - float2(U.outerPad), winSize, in.position.xy, U);
        case 3: return renderV7Ambilight(pPanel, winSize, U);
        case 4: return renderV9Silk(pPanel - float2(U.outerPad), winSize, U);
        default: return renderV1Aurora(pPanel - float2(U.outerPad), winSize, in.position.xy, U);
    }
}
"""

private struct MultiOverlayUniforms {
    var size: SIMD2<Float>
    var winSize: SIMD2<Float>
    var scale: Float
    var time: Float
    var radius: Float
    var intensity: Float
    var dark: Float
    var presence: Float
    var outerPad: Float
    var themeIndex: Int32
}

private final class MultiStyleOverlayCanvas: NSView {
    var theme: ControlledOverlayTheme = .aurora { didSet { if active { renderFrame() } } }
    var style: ControlledOverlayStyle = .standard { didSet { if active { renderFrame() } } }
    var prefersDark = false
    var cornerRadius: CGFloat = 22
    var outerPad: CGFloat = 0
    var reduceMotion = false
    private let metalLayer = CAMetalLayer()
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var timer: Timer?
    private var active = false
    private var lastFrameTime = CACurrentMediaTime()
    private var shownAt = CACurrentMediaTime()
    private var animTime: Double = 0
    private var intensity: Float = 1
    private var dark: Float = 0

    init?(prefersDark: Bool) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            return nil
        }
        do {
            let library = try device.makeLibrary(source: multiOverlayShaderSource, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "overlayVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "overlayFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            print("OVERLAY_SHADER_ERROR \(error)")
            fflush(stdout)
            return nil
        }
        self.device = device
        commandQueue = queue
        self.prefersDark = prefersDark
        dark = prefersDark ? 1 : 0
        super.init(frame: .zero)
        wantsLayer = true
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.isOpaque = false
        metalLayer.framebufferOnly = true
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer = metalLayer
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func makeBackingLayer() -> CALayer { metalLayer }
    override var wantsUpdateLayer: Bool { false }

    override func layout() {
        super.layout()
        syncDrawableSize()
        if active { renderFrame() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncDrawableSize()
    }

    private func syncDrawableSize() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        let w = max(1, round(bounds.width * scale))
        let h = max(1, round(bounds.height * scale))
        if metalLayer.drawableSize.width != w || metalLayer.drawableSize.height != h {
            metalLayer.drawableSize = CGSize(width: w, height: h)
        }
    }

    func setActive(_ isActive: Bool) {
        guard isActive != active else { return }
        active = isActive
        if isActive {
            shownAt = CACurrentMediaTime()
            lastFrameTime = shownAt
            syncDrawableSize()
            renderFrame()
            let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                self?.renderFrame()
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    private func renderFrame() {
        guard active, bounds.width > 0, bounds.height > 0 else { return }
        syncDrawableSize()
        guard let drawable = metalLayer.nextDrawable(),
              let buffer = commandQueue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        let now = CACurrentMediaTime()
        let step = min(0.1, max(0, now - lastFrameTime))
        lastFrameTime = now
        if !reduceMotion { animTime += step }
        let stepF = Float(step)
        intensity += (Float(style.intensity) - intensity) * min(1, stepF * 6)
        dark += ((prefersDark ? 1 : 0) - dark) * min(1, stepF * 4)
        let fadeDuration = reduceMotion ? 0.15 : 0.32
        let fade = Float(min(1, (now - shownAt) / fadeDuration))
        let scale = Float(metalLayer.contentsScale > 0 ? metalLayer.contentsScale : 2)
        let pad = Float(outerPad)
        let winW = max(1, Float(bounds.width) - pad * 2)
        let winH = max(1, Float(bounds.height) - pad * 2)

        var uniforms = MultiOverlayUniforms(
            size: SIMD2(Float(bounds.width), Float(bounds.height)),
            winSize: SIMD2(winW, winH),
            scale: scale,
            time: Float(animTime),
            radius: Float(cornerRadius),
            intensity: intensity,
            dark: dark,
            presence: fade * fade * (3 - 2 * fade),
            outerPad: pad,
            themeIndex: Int32(theme.rawValue)
        )
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MultiOverlayUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}

// MARK: - Interactive Frosted Desktop Control Banner (with Overlay Toggle + Style Menu)

private final class V1ControlLabel: NSTextField {
    override var allowsVibrancy: Bool { false }
}

private final class V1PillButton: NSButton {
    override var allowsVibrancy: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    var uiScale: CGFloat = 1 { didSet { needsDisplay = true } }
    var activeAccent: Bool = false { didSet { needsDisplay = true } }
    private var hovering = false
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        hoverArea = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(hoverArea!)
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let radius = min(11 * uiScale, min(bounds.width, bounds.height) / 2)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        if activeAccent {
            let fillAlpha: CGFloat = isHighlighted ? 0.34 : (hovering ? 0.48 : 0.38)
            NSColor(srgbRed: 0.32, green: 0.52, blue: 1.00, alpha: fillAlpha).setFill()
            path.fill()
            NSColor(srgbRed: 0.58, green: 0.74, blue: 1.00, alpha: 0.42).setStroke()
            path.lineWidth = 0.8
            path.stroke()
        } else {
            NSColor.white.withAlphaComponent(isHighlighted ? 0.06 : hovering ? 0.18 : 0.10).setFill()
            path.fill()
            NSColor.white.withAlphaComponent(0.14).setStroke()
            path.lineWidth = 0.6
            path.stroke()
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5 * uiScale, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.96)
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(
            at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
            withAttributes: attributes
        )
    }
}

private final class V1SpinnerMark: NSView {
    override var allowsVibrancy: Bool { false }
    var reduceMotion = false
    private let epoch = CACurrentMediaTime()

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let s = min(bounds.width, bounds.height) / 24.0
        let count = 8
        let head = reduceMotion ? 0.0 : ((CACurrentMediaTime() - epoch) * 1.15).truncatingRemainder(dividingBy: 1) * Double(count)
        ctx.translateBy(x: bounds.midX, y: bounds.midY)
        ctx.scaleBy(x: s, y: s)
        for i in 0..<count {
            var lag = head - Double(i)
            if lag < 0 { lag += Double(count) }
            let alpha = reduceMotion ? 0.65 : (0.20 + 0.80 * pow(1 - lag / Double(count), 2.2))
            ctx.saveGState()
            ctx.rotate(by: -CGFloat(i) * .pi * 2 / CGFloat(count))
            ctx.setFillColor(NSColor.white.withAlphaComponent(alpha).cgColor)
            ctx.addPath(CGPath(roundedRect: CGRect(x: -1.0, y: 5.8, width: 2.0, height: 4.1),
                               cornerWidth: 1.0, cornerHeight: 1.0, transform: nil))
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.move(to: CGPoint(x: -1.6, y: 3.6))
        ctx.addLine(to: CGPoint(x: -1.6, y: -4.8))
        ctx.addLine(to: CGPoint(x: 0.7, y: -2.7))
        ctx.addLine(to: CGPoint(x: 4.1, y: -2.7))
        ctx.closePath()
        ctx.fillPath()
    }
}

private final class V1ShimmerLabel: NSView {
    override var allowsVibrancy: Bool { false }
    var uiScale: CGFloat = 1 { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var reduceMotion = false
    var text: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    private let epoch = CACurrentMediaTime()
    private static let band: CGImage? = {
        let width = 64
        guard let ctx = CGContext(
            data: nil, width: width, height: 1, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        for x in 0..<width {
            ctx.setFillColor(gray: pow(sin(Double(x) / Double(width - 1) * .pi), 1.6), alpha: 1)
            ctx.fill(CGRect(x: x, y: 0, width: 1, height: 1))
        }
        return ctx.makeImage()
    }()

    init(text: String) {
        self.text = text
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize {
        let font = NSFont.systemFont(ofSize: 11 * uiScale, weight: .semibold)
        let size = (text as NSString).size(withAttributes: [.font: font])
        return NSSize(width: ceil(size.width + 2 * uiScale), height: ceil(size.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        let font = NSFont.systemFont(ofSize: 11 * uiScale, weight: .semibold)
        let base = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: NSColor(srgbRed: 0.83, green: 0.82, blue: 0.96, alpha: 0.92)
        ])
        let size = base.size()
        let inset = 2 * uiScale
        let origin = NSPoint(x: inset, y: (bounds.height - size.height) / 2)
        base.draw(at: origin)
        guard !reduceMotion else { return }
        let cycle = 3.2, sweep = 1.6
        let u = (CACurrentMediaTime() - epoch).truncatingRemainder(dividingBy: cycle) / sweep
        guard u < 1, let band = Self.band, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let eased = CGFloat(u * u * (3 - 2 * u))
        let bandWidth = 48 * uiScale
        let x = inset - bandWidth + (size.width + bandWidth) * eased
        ctx.saveGState()
        ctx.clip(to: CGRect(x: x, y: 0, width: bandWidth, height: bounds.height), mask: band)
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white]).draw(at: origin)
        ctx.restoreGState()
    }
}

private final class V1BannerView: NSVisualEffectView {
    static let baseSize = NSSize(width: 476, height: 74)
    private let baseCornerRadius: CGFloat = 20
    private var maskedSize = NSSize.zero
    private let tintView = NSView()
    private let spinner = V1SpinnerMark()
    let titleField = V1ControlLabel(labelWithString: "")
    let subtitleField = V1ControlLabel(labelWithString: "")
    let statusLabel = V1ShimmerLabel(text: "远程控制中")
    let toggleOverlayButton = V1PillButton()
    let styleMenuButton = V1PillButton()
    let closeButton = V1PillButton()

    var uiScale: CGFloat = 1 {
        didSet {
            if abs(uiScale - oldValue) > 0.001 {
                maskedSize = .zero
                needsLayout = true
            }
        }
    }
    var reduceTransparency = false { didSet { updateTint() } }
    var reduceMotion = false {
        didSet {
            spinner.reduceMotion = reduceMotion
            statusLabel.reduceMotion = reduceMotion
        }
    }

    init(owner: String, target: AnyObject, toggleOverlayAction: Selector, styleMenuAction: Selector, closeAction: Selector) {
        super.init(frame: NSRect(origin: .zero, size: Self.baseSize))
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.cornerRadius = baseCornerRadius
        layer?.masksToBounds = true
        layer?.borderWidth = 0

        tintView.wantsLayer = true
        tintView.layer = CALayer()
        addSubview(tintView)
        updateTint()

        titleField.stringValue = "\(owner) 工作区"
        titleField.textColor = .white.withAlphaComponent(0.96)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        titleField.cell?.truncatesLastVisibleLine = true

        subtitleField.stringValue = "KKRemote 移动设备已连接"
        subtitleField.textColor = .white.withAlphaComponent(0.54)
        subtitleField.lineBreakMode = .byTruncatingTail
        subtitleField.maximumNumberOfLines = 1
        subtitleField.cell?.truncatesLastVisibleLine = true

        toggleOverlayButton.isBordered = false
        toggleOverlayButton.title = "遮罩: 开"
        toggleOverlayButton.activeAccent = true
        toggleOverlayButton.toolTip = "点击开启或关闭桌面窗口视觉遮罩（不影响远程控制）"
        toggleOverlayButton.target = target
        toggleOverlayButton.action = toggleOverlayAction

        styleMenuButton.isBordered = false
        styleMenuButton.title = "星点极光 ▾"
        styleMenuButton.toolTip = "点击选择遮罩视觉样式与浓淡强度"
        styleMenuButton.target = target
        styleMenuButton.action = styleMenuAction

        closeButton.isBordered = false
        closeButton.title = "结束"
        closeButton.toolTip = "结束该窗口的远程控制并恢复原窗口尺寸"
        closeButton.target = target
        closeButton.action = closeAction

        addSubview(spinner)
        addSubview(titleField)
        addSubview(subtitleField)
        addSubview(statusLabel)
        addSubview(toggleOverlayButton)
        addSubview(styleMenuButton)
        addSubview(closeButton)
        updateMaterialMask()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func updateTint() {
        let alpha: CGFloat = reduceTransparency ? 0.96 : 0.78
        tintView.layer?.backgroundColor = NSColor(srgbRed: 0.145, green: 0.148, blue: 0.165, alpha: alpha).cgColor
    }

    override func layout() {
        super.layout()
        let s = uiScale
        let w = bounds.width
        let h = bounds.height
        tintView.frame = bounds
        layer?.cornerRadius = min(baseCornerRadius * s, min(w, h) / 2)

        let padX = 14 * s
        let spinnerSize = 24 * s
        spinner.frame = NSRect(x: padX, y: (h - spinnerSize) / 2, width: spinnerSize, height: spinnerSize)

        let buttonH = 36 * s
        let buttonY = (h - buttonH) / 2
        let closeW = 46 * s
        let styleW = 84 * s
        let toggleW = 68 * s
        let gap = 6 * s
        let closeX = w - padX - closeW
        let styleX = closeX - gap - styleW
        let toggleX = styleX - gap - toggleW

        closeButton.frame = NSRect(x: closeX, y: buttonY, width: closeW, height: buttonH)
        styleMenuButton.frame = NSRect(x: styleX, y: buttonY, width: styleW, height: buttonH)
        toggleOverlayButton.frame = NSRect(x: toggleX, y: buttonY, width: toggleW, height: buttonH)
        closeButton.uiScale = s
        styleMenuButton.uiScale = s
        toggleOverlayButton.uiScale = s

        titleField.font = .systemFont(ofSize: 13.0 * s, weight: .medium)
        subtitleField.font = .systemFont(ofSize: 10.0 * s, weight: .regular)
        statusLabel.uiScale = s

        let textX = padX + spinnerSize + 10 * s
        let textW = max(40, toggleX - 8 * s - textX)
        let h1 = ceil(titleField.fittingSize.height)
        let h2 = ceil(subtitleField.fittingSize.height)
        let h3 = statusLabel.intrinsicContentSize.height
        let lineGap = 2.0 * s
        let totalH = h1 + h2 + h3 + lineGap * 2
        let y3 = round((h - totalH) / 2)
        let y2 = y3 + h3 + lineGap
        let y1 = y2 + h2 + lineGap
        statusLabel.frame = NSRect(x: textX, y: y3, width: textW, height: h3)
        subtitleField.frame = NSRect(x: textX, y: y2, width: textW, height: h2)
        titleField.frame = NSRect(x: textX, y: y1, width: textW, height: h1)

        updateMaterialMask()
    }

    func tickAnimation() {
        spinner.needsDisplay = true
        statusLabel.needsDisplay = true
    }

    private func updateMaterialMask() {
        guard bounds.width > 0, bounds.height > 0, maskedSize != bounds.size else { return }
        maskedSize = bounds.size
        let size = bounds.size
        let radius = min(baseCornerRadius * uiScale, min(size.width, size.height) / 2)
        maskImage = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        window?.invalidateShadow()
    }
}

// MARK: - Live Controlled Window Multi-Style Overlay Controller

@MainActor
final class ControlledWindowOverlay: NSObject {
    static let shared = ControlledWindowOverlay()

    private static let prefEnabledKey = "kkremote.overlay.enabled"
    private static let prefThemeKey = "kkremote.overlay.theme"
    private static let prefIntensityKey = "kkremote.overlay.intensity"

    private let overlayPanel = ControlledOverlayPanel(interactive: false)
    private let bannerPanel = ControlledOverlayPanel(interactive: true)
    private var canvas: MultiStyleOverlayCanvas?
    private var bannerView: V1BannerView?
    private var statusItem: NSStatusItem?
    private var pollTimer: Timer?
    private var uiAnimTimer: Timer?
    private var activeTarget: RemoteWindow?
    private var onStopControl: (() -> Void)?
    private var lastFrame: CGRect = .null
    private var lastOuterPad: CGFloat = -1
    private var lastOrder: CGWindowID?
    private var lastVisibility = ""
    private var remotePointerPassthroughDepth = 0

    private(set) var isOverlayEnabled: Bool
    private(set) var isBannerVisible: Bool = true
    private(set) var theme: ControlledOverlayTheme
    private(set) var style: ControlledOverlayStyle

    private override init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.prefEnabledKey) != nil {
            self.isOverlayEnabled = defaults.bool(forKey: Self.prefEnabledKey)
        } else {
            self.isOverlayEnabled = true
        }
        self.theme = ControlledOverlayTheme(rawValue: defaults.integer(forKey: Self.prefThemeKey)) ?? .aurora
        if defaults.object(forKey: Self.prefIntensityKey) != nil {
            self.style = ControlledOverlayStyle(rawValue: defaults.integer(forKey: Self.prefIntensityKey)) ?? .standard
        } else {
            self.style = .standard
        }
        super.init()
        HostWindowControl.onRemotePointerActivity = { [weak self] active in
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    self?.setRemotePointerPassthrough(active)
                }
            } else {
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        self?.setRemotePointerPassthrough(active)
                    }
                }
            }
        }
    }

    private var prefersDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    func setOverlayEnabled(_ enabled: Bool) {
        isOverlayEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.prefEnabledKey)
        syncBannerControls()
        lastOrder = nil
        if !enabled {
            canvas?.setActive(false)
            if overlayPanel.isVisible { overlayPanel.orderOut(nil) }
        } else {
            lastVisibility = ""
        }
        update()
        print("OVERLAY_STATE enabled=\(isOverlayEnabled) theme=\(theme.cliKey) intensity=\(style.title)")
        fflush(stdout)
    }

    func setTheme(_ newTheme: ControlledOverlayTheme) {
        theme = newTheme
        UserDefaults.standard.set(newTheme.rawValue, forKey: Self.prefThemeKey)
        if !isOverlayEnabled {
            isOverlayEnabled = true
            UserDefaults.standard.set(true, forKey: Self.prefEnabledKey)
        }
        canvas?.theme = newTheme
        canvas?.outerPad = newTheme.outerPadding
        lastFrame = .null
        lastOrder = nil
        syncBannerControls()
        update()
        print("OVERLAY_STATE enabled=\(isOverlayEnabled) theme=\(theme.cliKey) intensity=\(style.title)")
        fflush(stdout)
    }

    func setIntensity(_ newStyle: ControlledOverlayStyle) {
        style = newStyle
        UserDefaults.standard.set(newStyle.rawValue, forKey: Self.prefIntensityKey)
        canvas?.style = newStyle
        syncBannerControls()
        print("OVERLAY_STATE enabled=\(isOverlayEnabled) theme=\(theme.cliKey) intensity=\(style.title)")
        fflush(stdout)
    }

    private func syncBannerControls() {
        guard let bannerView else { return }
        bannerView.toggleOverlayButton.title = isOverlayEnabled ? "遮罩: 开" : "开启遮罩"
        bannerView.toggleOverlayButton.activeAccent = isOverlayEnabled
        bannerView.styleMenuButton.title = "\(theme.shortTitle) ▾"
        bannerView.statusLabel.text = isOverlayEnabled
            ? "远程控制中 · \(theme.shortTitle)"
            : "远程控制中 · 遮罩已关"
        bannerView.toggleOverlayButton.needsDisplay = true
        bannerView.styleMenuButton.needsDisplay = true
        syncStatusBarMenu()
    }

    private func ensureStatusItem() {
        guard statusItem == nil else {
            syncStatusBarMenu()
            return
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if let img = NSImage(systemSymbolName: "sparkles.rectangle.stack", accessibilityDescription: "KKRemote Overlay") {
                img.isTemplate = true
                button.image = img
            } else {
                button.title = "KKRemote"
            }
            button.toolTip = "KKRemote 被控窗口遮罩设置"
        }
        statusItem = item
        syncStatusBarMenu()
    }

    private func buildOptionsMenu(includeBannerVisibilityItem: Bool) -> NSMenu {
        let menu = NSMenu(title: "桌面遮罩设置")
        menu.appearance = NSAppearance(named: .darkAqua)

        let toggleItem = NSMenuItem(
            title: isOverlayEnabled ? "关闭窗口视觉遮罩" : "开启窗口视觉遮罩",
            action: #selector(toggleOverlayFromUI),
            keyEquivalent: ""
        )
        toggleItem.target = self
        toggleItem.state = isOverlayEnabled ? .on : .off
        menu.addItem(toggleItem)

        if includeBannerVisibilityItem {
            let bannerItem = NSMenuItem(
                title: isBannerVisible ? "隐藏窗内悬浮控制条" : "显示窗内悬浮控制条",
                action: #selector(toggleBannerVisibilityFromUI),
                keyEquivalent: ""
            )
            bannerItem.target = self
            bannerItem.state = isBannerVisible ? .on : .off
            menu.addItem(bannerItem)
        }

        menu.addItem(.separator())
        let themeHeader = NSMenuItem(title: "选择遮罩样式", action: nil, keyEquivalent: "")
        themeHeader.isEnabled = false
        menu.addItem(themeHeader)

        for variant in ControlledOverlayTheme.allCases {
            let item = NSMenuItem(title: variant.menuTitle, action: #selector(selectThemeFromMenu(_:)), keyEquivalent: "")
            item.tag = variant.rawValue
            item.target = self
            item.state = (variant == theme) ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let intensityHeader = NSMenuItem(title: "遮罩浓淡强度", action: nil, keyEquivalent: "")
        intensityHeader.isEnabled = false
        menu.addItem(intensityHeader)

        for preset in ControlledOverlayStyle.allCases {
            let item = NSMenuItem(title: "\(preset.title)强度", action: #selector(selectIntensityFromMenu(_:)), keyEquivalent: "")
            item.tag = preset.rawValue
            item.target = self
            item.state = (preset == style) ? .on : .off
            menu.addItem(item)
        }

        if !includeBannerVisibilityItem {
            menu.addItem(.separator())
            let hideBar = NSMenuItem(
                title: "隐藏窗内控制条（可从右上角菜单栏恢复）",
                action: #selector(toggleBannerVisibilityFromUI),
                keyEquivalent: ""
            )
            hideBar.target = self
            menu.addItem(hideBar)
        } else {
            menu.addItem(.separator())
            let stopItem = NSMenuItem(title: "结束当前窗口远程控制", action: #selector(stopFromBanner), keyEquivalent: "")
            stopItem.target = self
            menu.addItem(stopItem)
        }

        return menu
    }

    private func syncStatusBarMenu() {
        guard let statusItem else { return }
        statusItem.menu = buildOptionsMenu(includeBannerVisibilityItem: true)
    }

    private func ensureViewsInitialized(owner: String) -> Bool {
        if canvas == nil {
            guard let created = MultiStyleOverlayCanvas(prefersDark: prefersDark) else {
                print("OVERLAY_V1_UNAVAILABLE reason=no_metal")
                fflush(stdout)
                return false
            }
            created.theme = theme
            created.style = style
            created.outerPad = theme.outerPadding
            overlayPanel.title = "KKRemote Overlay"
            overlayPanel.contentView = created
            canvas = created
        }
        if bannerView == nil {
            let bv = V1BannerView(
                owner: owner,
                target: self,
                toggleOverlayAction: #selector(toggleOverlayFromUI),
                styleMenuAction: #selector(showStylePopupFromBanner(_:)),
                closeAction: #selector(stopFromBanner)
            )
            bannerPanel.title = "KKRemote 控制状态条"
            bannerPanel.contentView = bv
            bannerPanel.hasShadow = true
            bannerView = bv
            syncBannerControls()
        }
        return true
    }

    func attach(target: RemoteWindow, onStopControl: @escaping () -> Void) {
        if NSApplication.shared.activationPolicy() == .prohibited {
            NSApplication.shared.setActivationPolicy(.accessory)
        }
        guard ensureViewsInitialized(owner: target.application) else { return }
        ensureStatusItem()

        let targetChanged = activeTarget?.number != target.number || activeTarget?.processID != target.processID
        activeTarget = target
        self.onStopControl = onStopControl
        isBannerVisible = true
        bannerView?.titleField.stringValue = "\(target.application) 工作区"
        bannerView?.subtitleField.stringValue = "移动设备实时控制 · \(Int(target.widthPoints.rounded()))×\(Int(target.heightPoints.rounded())) pt"
        syncBannerControls()

        if targetChanged {
            lastFrame = .null
            lastOrder = nil
            lastVisibility = ""
            print("OVERLAY_V1_ATTACH window=\(target.number) app=\(target.application) size=\(Int(target.widthPoints))x\(Int(target.heightPoints)) theme=\(theme.cliKey) enabled=\(isOverlayEnabled)")
            fflush(stdout)
        }

        if pollTimer == nil {
            let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.update()
                }
            }
            RunLoop.main.add(t, forMode: .common)
            pollTimer = t
        }
        update()
    }

    func detach() {
        guard activeTarget != nil || pollTimer != nil || overlayPanel.isVisible || bannerPanel.isVisible || statusItem != nil else { return }
        activeTarget = nil
        onStopControl = nil
        pollTimer?.invalidate()
        pollTimer = nil
        setUIAnimationRunning(false)
        canvas?.setActive(false)
        if overlayPanel.isVisible { overlayPanel.orderOut(nil) }
        if bannerPanel.isVisible { bannerPanel.orderOut(nil) }
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
        HostWindowControl.ignoredOverlayWindowIDs.removeAll()
        remotePointerPassthroughDepth = 0
        bannerPanel.ignoresMouseEvents = false
        lastFrame = .null
        lastOuterPad = -1
        lastOrder = nil
        lastVisibility = ""
        print("OVERLAY_V1_DETACH")
        fflush(stdout)
    }

    func setRemotePointerPassthrough(_ active: Bool) {
        if active {
            remotePointerPassthroughDepth += 1
            bannerPanel.ignoresMouseEvents = true
        } else {
            remotePointerPassthroughDepth = max(0, remotePointerPassthroughDepth - 1)
            if remotePointerPassthroughDepth == 0 {
                bannerPanel.ignoresMouseEvents = false
            }
        }
    }

    private func cornerRadius(for rect: NSRect) -> CGFloat {
        if NSScreen.screens.contains(where: { $0.frame == rect }) { return 0 }
        return ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 ? 22 : 12
    }

    private func setUIAnimationRunning(_ running: Bool) {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !running || reduce {
            uiAnimTimer?.invalidate()
            uiAnimTimer = nil
            if running { bannerView?.tickAnimation() }
            return
        }
        guard uiAnimTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.bannerView?.tickAnimation()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        uiAnimTimer = t
    }

    private func syncIgnoredWindowIDs() {
        var ids = Set<UInt32>()
        if overlayPanel.windowNumber > 0 { ids.insert(UInt32(overlayPanel.windowNumber)) }
        if bannerPanel.windowNumber > 0 { ids.insert(UInt32(bannerPanel.windowNumber)) }
        HostWindowControl.ignoredOverlayWindowIDs = ids
    }

    private func update() {
        guard let target = activeTarget,
              let canvas,
              let bannerView else {
            hide("no-target")
            return
        }
        guard NSRunningApplication(processIdentifier: target.processID)?.isTerminated == false else {
            hide("target-terminated")
            return
        }

        let windows = OverlayWindowSnapshot.visible()
        guard let index = windows.firstIndex(where: { $0.id == target.number && $0.pid == target.processID }) else {
            hide("target-not-visible")
            return
        }
        let current = windows[index]
        guard current.frame.width >= 240, current.frame.height >= 140 else {
            hide("too-small")
            return
        }

        let selfPID = ProcessInfo.processInfo.processIdentifier
        let occluder = windows[..<index].first {
            $0.pid != selfPID && $0.layer == 0 &&
            !($0.owner == "ChatGPT Computer Use" && $0.title == "Software Cursor") &&
            !($0.pid == current.pid && $0.frame.width <= 120 && $0.frame.height <= 44 &&
              current.frame.contains($0.frame) && $0.frame.minY < current.frame.minY + 48) &&
            $0.frame.intersects(current.frame)
        }
        if let occluder {
            hide("occluded-by-\(occluder.owner)-\(occluder.id)")
            return
        }

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        canvas.reduceMotion = reduceMotion
        bannerView.reduceMotion = reduceMotion
        bannerView.reduceTransparency = reduceTransparency
        canvas.prefersDark = prefersDark

        let appearing = lastVisibility != "visible"
        let rect = current.appKitFrame
        let pad = theme.outerPadding
        if rect != lastFrame || pad != lastOuterPad {
            let expandedRect = rect.insetBy(dx: -pad, dy: -pad)
            overlayPanel.setFrame(expandedRect, display: true)
            canvas.outerPad = pad
            canvas.cornerRadius = cornerRadius(for: rect)
            bannerView.subtitleField.stringValue = "移动设备实时控制 · \(Int(rect.width.rounded()))×\(Int(rect.height.rounded())) pt"

            let uiScale = min(1.0, max(0.62, (rect.width - 28) / V1BannerView.baseSize.width))
            let panelSize = NSSize(
                width: round(V1BannerView.baseSize.width * uiScale),
                height: round(V1BannerView.baseSize.height * uiScale)
            )
            bannerView.uiScale = uiScale
            let targetY = min(rect.minY + 18 + panelSize.height, rect.maxY - panelSize.height - 12)
            let targetFrame = NSRect(
                x: round(rect.midX - panelSize.width / 2),
                y: round(targetY),
                width: panelSize.width,
                height: panelSize.height
            )
            if appearing {
                bannerPanel.setFrame(targetFrame, display: true)
            } else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    bannerPanel.animator().setFrame(targetFrame, display: true)
                }
            }
            bannerView.needsLayout = true
            bannerView.layoutSubtreeIfNeeded()
            lastFrame = rect
            lastOuterPad = pad
        }

        if appearing {
            if isBannerVisible {
                bannerPanel.alphaValue = 0
                let targetY = bannerPanel.frame.minY
                if !reduceMotion {
                    bannerPanel.setFrameOrigin(NSPoint(x: bannerPanel.frame.minX, y: max(rect.minY + 6, targetY - 8)))
                }
            }
            if isOverlayEnabled {
                canvas.setActive(true)
            }
        }

        if isOverlayEnabled {
            canvas.setActive(true)
            let overlayIndex = windows.firstIndex(where: { $0.id == CGWindowID(overlayPanel.windowNumber) })
            if !overlayPanel.isVisible || overlayIndex == nil || overlayIndex! > index || lastOrder != current.id {
                overlayPanel.order(.above, relativeTo: Int(current.id))
                if isBannerVisible {
                    bannerPanel.order(.above, relativeTo: overlayPanel.windowNumber)
                } else if bannerPanel.isVisible {
                    bannerPanel.orderOut(nil)
                }
                lastOrder = current.id
                syncIgnoredWindowIDs()
            } else if isBannerVisible && !bannerPanel.isVisible {
                bannerPanel.order(.above, relativeTo: overlayPanel.windowNumber)
                syncIgnoredWindowIDs()
            } else if !isBannerVisible && bannerPanel.isVisible {
                bannerPanel.orderOut(nil)
            }
        } else {
            canvas.setActive(false)
            if overlayPanel.isVisible { overlayPanel.orderOut(nil) }
            if isBannerVisible {
                let bannerIndex = windows.firstIndex(where: { $0.id == CGWindowID(bannerPanel.windowNumber) })
                if !bannerPanel.isVisible || bannerIndex == nil || bannerIndex! > index || lastOrder != current.id {
                    bannerPanel.order(.above, relativeTo: Int(current.id))
                    lastOrder = current.id
                    syncIgnoredWindowIDs()
                }
            } else if bannerPanel.isVisible {
                bannerPanel.orderOut(nil)
            }
        }

        if appearing {
            syncIgnoredWindowIDs()
            if isBannerVisible {
                let scale = min(1.0, max(0.62, (rect.width - 28) / V1BannerView.baseSize.width))
                let finalY = round(min(
                    rect.minY + 18 + round(V1BannerView.baseSize.height * scale),
                    rect.maxY - round(V1BannerView.baseSize.height * scale) - 12
                ))
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = reduceMotion ? 0.12 : 0.28
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    bannerPanel.animator().alphaValue = 1
                    bannerPanel.animator().setFrameOrigin(NSPoint(x: bannerPanel.frame.minX, y: finalY))
                }
            }
            setUIAnimationRunning(isBannerVisible)
            print("OVERLAY_V1_VISIBLE window=\(current.id) frame=\(Int(rect.width))x\(Int(rect.height)) theme=\(theme.cliKey) enabled=\(isOverlayEnabled)")
            fflush(stdout)
        }
        lastVisibility = "visible"
    }

    private func hide(_ reason: String) {
        if overlayPanel.isVisible { overlayPanel.orderOut(nil) }
        if bannerPanel.isVisible { bannerPanel.orderOut(nil) }
        canvas?.setActive(false)
        setUIAnimationRunning(false)
        lastOrder = nil
        if lastVisibility != reason {
            lastVisibility = reason
        }
    }

    @objc private func toggleOverlayFromUI() {
        setOverlayEnabled(!isOverlayEnabled)
    }

    @objc private func toggleBannerVisibilityFromUI() {
        isBannerVisible.toggle()
        syncStatusBarMenu()
        if isBannerVisible {
            bannerPanel.alphaValue = 1
            lastOrder = nil
            setUIAnimationRunning(true)
        } else {
            if bannerPanel.isVisible { bannerPanel.orderOut(nil) }
            setUIAnimationRunning(false)
        }
        update()
    }

    @objc private func showStylePopupFromBanner(_ sender: NSButton) {
        let menu = buildOptionsMenu(includeBannerVisibilityItem: false)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 6), in: sender)
    }

    @objc private func selectThemeFromMenu(_ sender: NSMenuItem) {
        if let picked = ControlledOverlayTheme(rawValue: sender.tag) {
            setTheme(picked)
        }
    }

    @objc private func selectIntensityFromMenu(_ sender: NSMenuItem) {
        if let picked = ControlledOverlayStyle(rawValue: sender.tag) {
            setIntensity(picked)
        }
    }

    @objc private func stopFromBanner() {
        let callback = onStopControl
        detach()
        callback?()
    }
}
#endif
