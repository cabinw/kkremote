import AppKit

// V3: Event-Reactive Living Telemetry — calm & nearly invisible when idle,
// awakening local dot-matrix luminescence, comet trail & click ripples only around live actions.

private let v3FragmentShader = """
static float segmentDistance(float2 p, float2 a, float2 b) {
    float2 pa = p - a, ba = b - a;
    float denom = max(dot(ba, ba), 1e-4);
    float h = clamp(dot(pa, ba) / denom, 0.0, 1.0);
    return length(pa - ba * h);
}

static float3 telemetrySpectrum(float s, float darkMode) {
    float3 lightC = linearRamp5(s,
        float3(0.20, 0.46, 1.00), // Deep Sapphire
        float3(0.58, 0.24, 1.00), // Rich Electric Violet
        float3(0.98, 0.20, 0.66), // Vivid Rose Magenta
        float3(1.00, 0.38, 0.16), // Bold Coral Tangerine
        float3(1.00, 0.72, 0.14)); // Rich Amber Gold
    float3 darkC = linearRamp5(s,
        float3(0.42, 0.70, 1.00),
        float3(0.72, 0.44, 1.00),
        float3(1.00, 0.40, 0.80),
        float3(1.00, 0.54, 0.32),
        float3(1.00, 0.84, 0.38));
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
    float styleT = clamp((k - 0.75) / 0.57, 0.0, 1.0); // 0=柔和, ~0.44=标准, 1=鲜明
    float act = clamp(U.activity, 0.0, 1.0);
    float ang = perimeterAngle(p, size);

    // 1) Standby perimeter ribbon (calm during idle, clearly glowing across active control, bold in Vivid).
    float edgeWidth = clamp(min(size.x, size.y) * mix(0.11, 0.19, styleT), 24.0, 128.0);
    float edge = smoothEdgeProximity(p, size, edgeWidth);
    float rimWidth = mix(1.45, 3.65, styleT) + mix(0.55, 1.25, styleT) * act;
    float hairline = exp(-pow(max(d - 1.5, 0.0) / rimWidth, 2.0));
    float sweep = pow(max(0.5 + 0.5 * cos(ang - t * 0.95), 0.0), 2.4);
    float s = fract(ang / (M_PI_F * 2.0) - t * 0.12 + length(p - U.cursor) * 0.0009);
    float3 rimColor = telemetrySpectrum(abs(s * 2.0 - 1.0), U.dark);

    float idleEdge = mix(0.06, 0.16, styleT);
    float activeEdge = mix(0.28, 0.58, styleT);
    float rimFill = pow(max(edge, 0.0), mix(1.85, 1.45, styleT)) * mix(idleEdge, activeEdge * (0.65 + 0.45 * sweep), act);
    float hairlineA = hairline * mix(mix(0.32, 0.62, styleT), mix(0.68, 0.96, styleT), act);
    float rimAlpha = clamp(hairlineA + rimFill * (1.0 - hairlineA), 0.0, 0.96);

    // 2) Active pointer trail & spotlight wake.
    float2 cur = U.cursor;
    float2 prevCur = U.custom.xy;
    float curDist = length(p - cur);
    float trailDist = segmentDistance(p, prevCur, cur);
    float spotR = mix(46.0, 74.0, styleT);
    float trailR = mix(18.0, 30.0, styleT);
    float spotlight = exp(-(curDist * curDist) / (2.0 * spotR * spotR));
    float trailGlow = exp(-(trailDist * trailDist) / (2.0 * trailR * trailR));
    float wakeField = clamp((0.68 * spotlight + 0.58 * trailGlow) * (0.20 + 0.80 * act), 0.0, 1.0);

    // 3) Expanding click / keystroke ripple wave (restrained, airy wavefront).
    float pulseStrength = U.custom.w;
    float age = U.clickAge;
    float ringFade = smoothstep(0.0, 0.05, age) * (1.0 - smoothstep(0.22, 1.15, age)) * pulseStrength;
    float clickDist = length(p - U.clickOrigin);
    float ringRadius = age * 265.0;
    float ringBandW = mix(11.0, 18.0, styleT) + age * 10.0;
    float ringBand = exp(-pow((clickDist - ringRadius) / ringBandW, 2.0));
    float originFlash = exp(-(clickDist * clickDist) / (2.0 * mix(16.0, 24.0, styleT) * mix(16.0, 24.0, styleT)))
                      * (1.0 - smoothstep(0.0, 0.30, age)) * pulseStrength;
    float rippleWake = clamp((ringBand * 0.92 + originFlash * 0.72) * ringFade, 0.0, 1.05);

    // Restrained translucent color tint around cursor & ripple so center text stays crystal clear.
    float3 curCol = telemetrySpectrum(clamp(0.22 + 0.62 * sin(t * 0.8 + clickDist * 0.011), 0.0, 1.0), U.dark);
    float localColorAlpha = clamp((mix(0.05, 0.13, styleT) * spotlight + mix(0.04, 0.10, styleT) * trailGlow) * act
                                + mix(0.08, 0.19, styleT) * ringBand * ringFade
                                + mix(0.06, 0.14, styleT) * originFlash,
                                0.0, mix(0.14, 0.24, styleT));

    float4 outc = float4(rimColor * rimAlpha, rimAlpha);
    outc = float4(curCol * localColorAlpha, localColorAlpha) + outc * (1.0 - localColorAlpha);

    // 4) Dormant micro-dot matrix: awakens crisply in gem tones (light) / luminous glow (dark).
    const float spacing = 8.5;
    float2 g = p / spacing;
    float2 cell = floor(g);
    float2 f = (fract(g) - 0.5) * spacing;
    float r2 = dot(f, f);

    float seed = hash21(cell + 19.3);
    float phaseClock = t * (0.45 + 0.35 * seed) + seed * 17.0;
    float ph = fract(phaseClock);
    float gate = hash21(cell + floor(phaseClock) * 3.71);
    float twinkleEnv = smoothstep(0.0, 0.15, ph) * (1.0 - smoothstep(0.15, 0.48, ph));
    float spark = gate > 0.84 ? twinkleEnv : 0.0;

    float perimeterAwake = pow(max(edge, 0.0), mix(1.85, 1.45, styleT)) * (mix(0.05, 0.16, styleT) + mix(0.22, 0.48, styleT) * act);
    float eventAwake = clamp(wakeField * mix(0.68, 0.95, styleT) + rippleWake * mix(0.85, 1.15, styleT), 0.0, 1.20);
    float dotAwake = clamp(perimeterAwake + eventAwake, 0.0, 1.25);

    if (dotAwake > 0.004) {
        float sparkBoost = spark * clamp(eventAwake, 0.0, 1.0);
        float sigma = mix(0.34, 0.41, styleT) + mix(0.08, 0.15, styleT) * clamp(rippleWake, 0.0, 1.0) + 0.22 * sparkBoost;
        float halo = mix(0.05, 0.10, styleT) + mix(0.12, 0.20, styleT) * clamp(rippleWake, 0.0, 1.0) + 0.24 * sparkBoost;
        float dotShape = exp(-r2 / (2.0 * sigma * sigma)) + halo * exp(-r2 / (2.0 * 1.40 * 1.40));
        float dotBright = (0.18 * perimeterAwake + 0.28 * wakeField + 0.40 * rippleWake + 0.50 * sparkBoost) * mix(0.76, 1.12, styleT);
        float maxDotA = clamp(mix(0.42, 0.56, styleT) + 0.24 * sparkBoost, 0.0, 0.84);
        float dotAlpha = clamp(dotShape * dotBright, 0.0, maxDotA);
        float3 dotTint = mix(mix(curCol, min(curCol * 1.25 + 0.25, float3(1.0)), 0.35 * sparkBoost),
                             min(curCol * 1.16 + 0.26, float3(1.0)), U.dark);
        outc = float4(dotTint * dotAlpha, dotAlpha) + outc * (1.0 - dotAlpha);
    }

    // Crisp, restrained focus ring right at pointer & click shockwave wavefront.
    float pointerHalo = exp(-pow(abs(curDist - 8.5) / mix(1.3, 1.9, styleT), 2.0)) * mix(0.22, 0.46, styleT) * act;
    float burstRing = exp(-pow(abs(clickDist - ringRadius) / mix(1.35, 2.05, styleT), 2.0)) * mix(0.26, 0.52, styleT) * ringFade;
    float ringSpark = clamp(pointerHalo + burstRing, 0.0, mix(0.36, 0.62, styleT));
    float3 ringTint = mix(curCol, min(curCol * 1.15 + 0.30, float3(1.0)), U.dark * 0.6 + 0.18);
    outc = float4(ringTint * ringSpark, ringSpark) + outc * (1.0 - ringSpark);

    float grain = (hash21(in.position.xy) - 0.5) * (2.0 / 255.0);
    outc.rgb = clamp(outc.rgb + grain * outc.a, 0.0, outc.a);
    return outc * (coverage * U.presence);
}
"""

final class V3TelemetryController {
    var autoDemo = true
    private var simTime: Double = 0
    private var cursor = SIMD2<Float>(240, 260)
    private var trailCursor = SIMD2<Float>(220, 250)
    private var clickOrigin = SIMD2<Float>(240, 260)
    private var clickAge: Float = 0.25
    private var pulseStrength: Float = 1.0
    private var activity: Float = 0.90
    private var lastPulseBucket: Int = -1
    private var lastMouseScreen: NSPoint = .zero
    private var manualMouseActiveUntil: TimeInterval = 0

    func triggerPulse(in size: SIMD2<Float>) {
        clickOrigin = cursor
        clickAge = 0
        pulseStrength = 1.0
        activity = 1.0
    }

    func update(uniforms: inout OverlayUniforms, overlayWindowFrame: CGRect, step: TimeInterval) {
        let size = uniforms.size
        simTime += step
        clickAge += Float(step)
        let now = CACurrentMediaTime()

        // Passive pointer observation (no AX / input monitoring permission):
        // if user moves mouse inside the target window, spotlight follows pointer directly.
        let mouseScreen = NSEvent.mouseLocation
        let mouseMoved = hypot(mouseScreen.x - lastMouseScreen.x, mouseScreen.y - lastMouseScreen.y) > 2.0
        lastMouseScreen = mouseScreen
        if overlayWindowFrame.contains(mouseScreen) && mouseMoved {
            manualMouseActiveUntil = now + 2.5
        }

        var targetPos = cursor
        var targetActivity: Float = 0.16
        if now < manualMouseActiveUntil && overlayWindowFrame.contains(mouseScreen) {
            targetPos = SIMD2(Float(mouseScreen.x - overlayWindowFrame.minX),
                              Float(overlayWindowFrame.maxY - mouseScreen.y))
            targetActivity = 1.0
        } else if autoDemo {
            // Smooth scripted remote interaction: ~8.5s active control + ~2.5s calm idle breath.
            let cycle = simTime.truncatingRemainder(dividingBy: 11.0)
            if cycle < 8.5 {
                let waypoints: [SIMD2<Float>] = [
                    SIMD2(0.32, 0.14), SIMD2(0.68, 0.24), SIMD2(0.28, 0.44),
                    SIMD2(0.64, 0.58), SIMD2(0.38, 0.76), SIMD2(0.56, 0.36)
                ]
                let scaled = (cycle / 8.5) * Double(waypoints.count - 1)
                let i = min(Int(scaled), waypoints.count - 2)
                let u = Float(scaled - Double(i))
                let smooth = u * u * (3 - 2 * u)
                let norm = waypoints[i] + (waypoints[i + 1] - waypoints[i]) * smooth
                targetPos = SIMD2(norm.x * size.x, norm.y * size.y)
                targetActivity = 0.96

                // Periodic remote click ripple every ~2.1s inside active phase.
                let bucket = Int(simTime / 2.15)
                if bucket != lastPulseBucket {
                    lastPulseBucket = bucket
                    clickOrigin = targetPos
                    clickAge = 0
                    pulseStrength = 1.0
                }
            } else {
                targetActivity = 0.16
            }
        }

        let lerpPos = min(1, Float(step) * 8.5)
        trailCursor += (cursor - trailCursor) * min(1, Float(step) * 3.8)
        cursor += (targetPos - cursor) * lerpPos
        let lerpAct = targetActivity > activity ? min(1, Float(step) * 6.0) : min(1, Float(step) * 1.6)
        activity += (targetActivity - activity) * lerpAct

        uniforms.cursor = cursor
        uniforms.clickOrigin = clickOrigin
        uniforms.clickAge = clickAge
        uniforms.activity = activity
        uniforms.custom = SIMD4(trailCursor.x, trailCursor.y, 0, pulseStrength)
    }
}

final class V3MenuHelper: NSObject {
    let controller: V3TelemetryController
    weak var probe: Probe?
    weak var demoItem: NSMenuItem?

    init(controller: V3TelemetryController, probe: Probe) {
        self.controller = controller
        self.probe = probe
    }

    @objc func firePulse() {
        guard let probe else { return }
        let s = SIMD2<Float>(Float(probe.overlayRoot.bounds.width), Float(probe.overlayRoot.bounds.height))
        controller.triggerPulse(in: s)
    }

    @objc func toggleDemo() {
        controller.autoDemo.toggle()
        demoItem?.state = controller.autoDemo ? .on : .off
    }
}

@main
enum V3ProbeEntry {
    private static var menuHelper: V3MenuHelper?

    static func main() {
        let telemetry = V3TelemetryController()
        let effect = ProbeEffect(
            versionTag: "V3 活体响应",
            subtitleTag: "样式预览 · V3 事件驱动局部微光",
            shaderFragmentSource: v3FragmentShader,
            updateUniforms: { uniforms, frame, step, _ in
                telemetry.update(uniforms: &uniforms, overlayWindowFrame: frame, step: step)
            },
            setupExtraMenuItems: { menu, probe in
                let helper = V3MenuHelper(controller: telemetry, probe: probe)
                menuHelper = helper
                menu.addItem(.separator())
                let pulse = NSMenuItem(title: "立即触发点击波纹", action: #selector(V3MenuHelper.firePulse), keyEquivalent: "p")
                pulse.target = helper
                menu.addItem(pulse)
                let demo = NSMenuItem(title: "演示远端自动轨迹", action: #selector(V3MenuHelper.toggleDemo), keyEquivalent: "")
                demo.target = helper
                demo.state = telemetry.autoDemo ? .on : .off
                helper.demoItem = demo
                menu.addItem(demo)
            }
        )
        runProbeMain(effect: effect)
    }
}
