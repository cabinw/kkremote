import AppKit
import CoreGraphics

// V4: Full-Window Liquid Glass Sheet — real WindowServer frosted glass covering the entire
// window (subtle optical frost across center for crisp legibility, thicker frosted bevel at rim),
// paired with cool mineral glass absorption, crisp diagonal studio reflections, 3D chamfer bevel,
// and razor-sharp prismatic meniscus dispersion.

private let v4FragmentShader = """
static float3 glassPrism(float s, float darkMode) {
    float3 lightG = linearRamp5(s,
        float3(0.28, 0.76, 1.00), // Ice Quartz Cyan
        float3(0.48, 0.54, 1.00), // Crystal Sapphire-Violet
        float3(0.86, 0.48, 0.98), // Opal Magenta
        float3(0.98, 0.62, 0.56), // Rose Quartz
        float3(0.62, 0.90, 1.00)  // Glacial Aqua
    );
    float3 darkG = linearRamp5(s,
        float3(0.36, 0.86, 1.00),
        float3(0.54, 0.60, 1.00),
        float3(0.94, 0.50, 0.98),
        float3(1.00, 0.62, 0.54),
        float3(0.66, 0.92, 1.00)
    );
    return mix(lightG, darkG, darkMode);
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
    float2 uv = p / size;
    float ang = perimeterAngle(p, size);

    // Sweeping studio reflections across the glass bevel & pane.
    float specularA = pow(max(0.5 + 0.5 * cos(ang - t * 0.55 + 0.45), 0.0), 3.4);
    float specularB = pow(max(0.5 + 0.5 * cos(ang - t * 0.55 + M_PI_F + 0.25), 0.0), 4.0) * 0.62;
    float cornerCatch = pow(max(sin(ang * 2.0), 0.0), 2.0) * 0.34;
    float lightCatch = clamp(specularA + specularB + cornerCatch * 0.45, 0.0, 1.28);

    // Top-left studio key light direction for convincing 3D glass slab relief.
    float2 nVec = normalize((p - size * 0.5) + float2(1e-4));
    float dirBias = clamp(-dot(nVec, normalize(float2(0.66, 0.84))), -1.0, 1.0);

    float diagPhase = dot(uv - 0.5, float2(cos(t * 0.22), sin(t * 0.22)));
    float surfPhase = fract(ang / (M_PI_F * 2.0) - t * 0.07 + diagPhase * 0.15);
    float3 glassTint = glassPrism(abs(surfPhase * 2.0 - 1.0), U.dark);

    // 1) Whole-window glass plate body: subtle mineral-quartz absorption so crisp white
    // diagonal studio reflections and 3D beveled edges clearly read as physical glass on light & dark windows.
    float3 plateBaseCol = mix(
        mix(float3(0.54, 0.66, 0.82), glassTint * 0.24 + float3(0.50, 0.60, 0.76), 0.25),
        mix(float3(0.20, 0.32, 0.52), glassTint * 0.35 + float3(0.14, 0.20, 0.34), 0.35),
        U.dark
    );
    float plateAlpha = mix(0.075, 0.150, styleT) * mix(1.0, 1.12, U.dark);

    // Crisp architectural diagonal studio glare stripes sweeping gently across the pane.
    float sheenCoord = dot(uv - 0.5, normalize(float2(0.78, 0.62)));
    float drift = 0.18 * sin(t * 0.42);
    float mainBand = smoothstep(0.32, 0.02, abs(sheenCoord - (-0.10 + drift)));
    float crispBand = exp(-pow((sheenCoord - (-0.18 + drift * 0.85)) / 0.045, 2.0));
    float hairlineGlint = exp(-pow((sheenCoord - (0.19 - drift * 0.55)) / 0.022, 2.0)) * 0.85;
    float topWash = smoothstep(0.58, 0.0, uv.y) * 0.44;

    float glareIntensity = mainBand * mix(0.15, 0.30, styleT)
                         + crispBand * mix(0.20, 0.42, styleT)
                         + hairlineGlint * mix(0.14, 0.32, styleT)
                         + topWash * mix(0.06, 0.14, styleT);
    float sheenA = clamp(glareIntensity * mix(1.0, 0.80, U.dark), 0.0, 0.48);
    float3 sheenCol = mix(float3(1.00, 1.00, 1.00), mix(float3(0.84, 0.94, 1.00), glassTint * 0.35 + 0.65, 0.30), U.dark);

    // Subtle internal frosted micro-grain & crystalline dust glints caught inside reflections.
    float microTex = (valueNoise(p * 0.34 + t * 0.10) - 0.5) * mix(0.020, 0.040, styleT);
    float2 gCell = floor(p / 13.0);
    float2 gLoc = (fract(p / 13.0) - 0.5) * 13.0;
    float gSeed = hash21(gCell + 31.7);
    float gClk = t * (0.26 + 0.22 * gSeed) + gSeed * 19.0;
    float gPh = fract(gClk);
    float gGate = hash21(gCell + floor(gClk) * 3.13);
    float gSpark = (gGate > 0.962 ? smoothstep(0.0, 0.14, gPh) * (1.0 - smoothstep(0.14, 0.46, gPh)) : 0.0)
                 * exp(-dot(gLoc, gLoc) / (2.0 * 0.52 * 0.52));
    float glassDustA = gSpark * (0.14 + 0.58 * max(crispBand + hairlineGlint, smoothEdgeProximity(p, size, 32.0))) * mix(0.40, 0.88, styleT);

    // 2) 3D Machined Glass Bevel & Inner Chamfer Shoulder around the perimeter.
    float bevelWidth = mix(15.0, 22.0, styleT);
    float meniscusPos = bevelWidth * 0.78;
    float bevelBody = smoothstep(0.0, 2.2, d) * (1.0 - smoothstep(meniscusPos - 1.5, bevelWidth + 4.5, d));

    // Directional 3D bevel: icy bright catchlight on top-left facing edge, cool depth on bottom-right.
    float3 bevelLightCol = mix(float3(0.96, 0.99, 1.00), min(glassTint * 0.45 + 0.58, float3(1.0)), 0.36);
    float3 bevelShadeCol = mix(float3(0.42, 0.54, 0.72), float3(0.16, 0.24, 0.38), U.dark);
    float3 bevelCol = mix(bevelShadeCol, bevelLightCol, smoothstep(-0.65, 0.75, dirBias + 0.25 * lightCatch));
    float bevelAlpha = bevelBody * mix(0.16, 0.30, styleT) * (0.64 + 0.40 * lightCatch);

    // Subtle crisp inner chamfer ridge tracing the transition from bevel to flat pane.
    float chamferLine = exp(-pow((d - meniscusPos) / 1.15, 2.0));
    float chamferLightA = clamp(chamferLine * max(0.25, 0.55 + 0.55 * dirBias) * mix(0.24, 0.48, styleT), 0.0, 0.56);
    float chamferShadow = exp(-pow((d - (meniscusPos + 1.3)) / 1.0, 2.0)) * clamp(0.45 - 0.55 * dirBias, 0.0, 0.65) * mix(0.16, 0.28, styleT) * mix(1.0, 0.45, U.dark);

    // Tight optical RGB meniscus dispersion localized cleanly along the bevel shoulder.
    float dispC = exp(-pow((d - (meniscusPos - 1.2)) / 1.35, 2.0));
    float dispM = exp(-pow((d - meniscusPos) / 1.45, 2.0));
    float dispA = exp(-pow((d - (meniscusPos + 1.2)) / 1.35, 2.0));
    float3 dispRGB = clamp(
        float3(0.28, 0.78, 1.00) * dispC * 0.65
      + float3(0.88, 0.54, 1.00) * dispM * 0.62
      + float3(1.00, 0.72, 0.44) * dispA * 0.48,
      0.0, 1.0);
    float meniscusA = clamp(dispM * mix(0.16, 0.38, styleT) * (0.48 + 0.65 * lightCatch), 0.0, 0.64);

    // Crisp outer glass edge Fresnel highlight + micro depth contrast shadow.
    float outerShadow = exp(-pow(max(d - 0.55, 0.0) / 0.80, 2.0)) * mix(0.24, 0.08, U.dark) * clamp(0.60 - 0.40 * dirBias, 0.15, 1.0);
    float outerLip = exp(-pow(max(d - 1.30, 0.0) / mix(1.15, 1.75, styleT), 2.0));
    float lipA = clamp(outerLip * mix(0.62, 0.94, styleT) * (0.50 + 0.46 * lightCatch + 0.22 * dirBias), 0.0, 0.96);
    float3 lipCol = mix(float3(0.99, 1.00, 1.00), min(glassTint * 0.50 + 0.55, float3(1.0)), 0.32);

    // Premultiplied Porter-Duff compositing from back to front.
    float3 baseTintCol = clamp(plateBaseCol + microTex, 0.0, 1.0);
    float3 col = baseTintCol * plateAlpha;
    float a = plateAlpha;

    col = sheenCol * sheenA + col * (1.0 - sheenA);
    a = sheenA + a * (1.0 - sheenA);

    col = bevelCol * bevelAlpha + col * (1.0 - bevelAlpha);
    a = bevelAlpha + a * (1.0 - bevelAlpha);

    col = float3(0.20, 0.26, 0.38) * chamferShadow + col * (1.0 - chamferShadow);
    a = chamferShadow + a * (1.0 - chamferShadow);

    col = dispRGB * meniscusA + col * (1.0 - meniscusA);
    a = meniscusA + a * (1.0 - meniscusA);

    col = float3(1.0) * chamferLightA + col * (1.0 - chamferLightA);
    a = chamferLightA + a * (1.0 - chamferLightA);

    float3 dCol = float3(0.14, 0.18, 0.26);
    col = dCol * outerShadow + col * (1.0 - outerShadow);
    a = outerShadow + a * (1.0 - outerShadow);

    col = lipCol * lipA + col * (1.0 - lipA);
    a = lipA + a * (1.0 - lipA);

    float dustClamp = clamp(glassDustA, 0.0, 0.78);
    col = float3(1.0) * dustClamp + col * (1.0 - dustClamp);
    a = dustClamp + a * (1.0 - dustClamp);

    float grain = (hash21(in.position.xy) - 0.5) * (1.5 / 255.0);
    col = clamp(col + grain * a, 0.0, a);
    return float4(col, a) * (coverage * U.presence);
}
"""

final class LiquidGlassSheetView: NSVisualEffectView {
    private var cachedBounds = CGSize.zero
    private var cachedRadius: CGFloat = -1
    private var cachedStyleT: Double = -1
    private var cachedDark: Bool = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        blendingMode = .behindWindow
        state = .active
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(bounds: CGRect, cornerRadius: CGFloat, dark: Bool, reduceTransparency: Bool, intensity: Double) {
        isHidden = reduceTransparency
        if reduceTransparency || bounds.width <= 0 || bounds.height <= 0 { return }

        let styleT = min(1.0, max(0.0, (intensity - 0.75) / 0.57))
        if cachedDark != dark || appearance == nil {
            cachedDark = dark
            material = dark ? .hudWindow : .popover
            appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        }

        let size = bounds.size
        guard cachedBounds != size || abs(cachedRadius - cornerRadius) > 0.25 || abs(cachedStyleT - styleT) > 0.02 else {
            return
        }
        cachedBounds = size
        cachedRadius = cornerRadius
        cachedStyleT = styleT
        maskImage = Self.buildSheetMask(size: size, cornerRadius: cornerRadius, styleT: styleT)
    }

    // Whole-window glass frost mask: light crisp frost across center (0.10..0.24 by style),
    // curving up smoothly to a thicker frosted bevel (0.78..0.92) around the perimeter.
    private static func buildSheetMask(size: CGSize, cornerRadius: CGFloat, styleT: Double) -> NSImage? {
        let w = max(1, Int(ceil(size.width)))
        let h = max(1, Int(ceil(size.height)))
        let centerFrost = Float(0.10 + 0.14 * styleT) // 柔和 ~0.10, 标准 ~0.16, 鲜明 ~0.24
        let edgeFrost = Float(0.78 + 0.14 * styleT)   // 柔和 ~0.78, 标准 ~0.84, 鲜明 ~0.92
        let centerByte = UInt8(min(255, max(0, Int(centerFrost * 255.0))))

        var bytes = [UInt8](repeating: centerByte, count: w * h * 4)

        let fw = Float(size.width)
        let fh = Float(size.height)
        let hx = fw * 0.5
        let hy = fh * 0.5
        let R = min(Float(cornerRadius), min(hx, hy))
        let bevelSpan: Float = Float(18.0 + 7.0 * styleT)
        let innerStop = bevelSpan + 6.0
        let n: Float = 2.85

        for y in 0..<h {
            let py = Float(y) + 0.5
            let dy = abs(py - hy) - (hy - R)
            for x in 0..<w {
                let px = Float(x) + 0.5
                let edgeDx = min(px, fw - px)
                let edgeDy = min(py, fh - py)
                // Interior already holds centerFrost in all RGBA channels.
                if edgeDx > R + innerStop && edgeDy > R + innerStop { continue }

                let dx = abs(px - hx) - (hx - R)
                let d: Float
                if R <= 0.001 {
                    d = -max(dx, dy)
                } else if dx > 0 && dy > 0 {
                    let tx = dx / R
                    let ty = dy / R
                    let F = powf(tx, n) + powf(ty, n)
                    let s = powf(F, 1.0 / n)
                    let gx = powf(tx, n - 1.0)
                    let gy = powf(ty, n - 1.0)
                    let grad = hypotf(gx, gy) * powf(max(F, 1e-6), (1.0 - n) / n)
                    d = R * (1.0 - s) / max(grad, 0.5)
                } else {
                    d = R - max(dx, dy)
                }

                let a: Float
                if d <= 0 {
                    a = 0
                } else if d >= innerStop {
                    a = centerFrost
                } else {
                    let outerAA = min(1.0, max(0.0, d / 1.15))
                    let t = min(1.0, max(0.0, d / innerStop))
                    let smooth = t * t * (3.0 - 2.0 * t)
                    a = outerAA * (edgeFrost + (centerFrost - edgeFrost) * smooth)
                }
                let byteVal = UInt8(min(255, max(0, Int(a * 255.0))))
                let base = (y * w + x) * 4
                bytes[base] = byteVal
                bytes[base + 1] = byteVal
                bytes[base + 2] = byteVal
                bytes[base + 3] = byteVal
            }
        }

        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cgMask = CGImage(
                  width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              ) else {
            return nil
        }
        return NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.draw(cgMask, in: rect)
            return true
        }
    }
}

@main
enum V4ProbeEntry {
    static func main() {
        let effect = ProbeEffect(
            versionTag: "V4 整窗液态玻璃",
            subtitleTag: "样式预览 · V4 全窗玻璃面板",
            shaderFragmentSource: v4FragmentShader,
            makeUnderlayView: { LiquidGlassSheetView(frame: .zero) },
            layoutUnderlayView: { view, bounds, cornerRadius, dark, reduceTransparency, intensity in
                guard let sheet = view as? LiquidGlassSheetView else { return }
                sheet.update(bounds: bounds, cornerRadius: cornerRadius, dark: dark,
                             reduceTransparency: reduceTransparency, intensity: intensity)
            }
        )
        runProbeMain(effect: effect)
    }
}
