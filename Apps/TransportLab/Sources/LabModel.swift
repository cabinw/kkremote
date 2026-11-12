import Foundation
import WebRTC
import Combine

struct LabReport: Codable {
    let schemaVersion: Int
    let appVersion: String
    let build: String
    let backend: String
    let os: String
    let mode: String
    let networkLabel: String
    let actualOverlayPath: String
    let pacing: PacingMode
    let pacingParameters: String
    let bridgeReceiveDepth: Int
    let bridgeTransport: BridgeTransportKind
    let mediaRoute: MediaRoute
    let preset: LabPreset
    let notes: [String]
    let samples: [LabSample]
}

final class LabModel: ObservableObject {
    @Published var host = ""
    @Published var port = "45990"
    @Published var pairingKey = ""
    @Published var networkLabel = "Surge Ponte"
    @Published var mediaRoute = MediaRoute.ponteUDP
    @Published var mediaPort = "45991"
    @Published var resolution = "1920×1080"
    @Published var fps = 60
    @Published var megabits = 25
    @Published var pattern = PatternKind.grid
    var bridgeReceiveDepth = 16
    @Published var bridgeTransport = BridgeTransportKind.network
    @Published var running = false
    @Published var status = "准备连接"
    @Published var error: String?
    @Published var sample = LabSample()
    @Published var track: RTCVideoTrack?
    @Published var exportedReport: URL?
    @Published var mode = "viewer"
    private var signal: SignalTransport?
    private var engine: PeerEngine?
    private var demoHost: LabModel?
    private var samples: [LabSample] = []
    private var activePreset = LabPreset()
    private var activeRoute = MediaRoute.ponteUDP
    private var activeBridgeTransport = BridgeTransportKind.network
    private var activeReceiveDepth = 16
    private var generation = UUID()
    var decodedFrames: Int { engine?.frameCounter.received ?? 0 }

    var preset: LabPreset {
        let size = resolution.split(separator: "×").compactMap { Int($0) }
        return LabPreset(width: size.first ?? 1920, height: size.last ?? 1080, fps: fps, megabits: megabits, pattern: pattern)
    }

    func startHost() { start(isHost: true) }
    func connect() { start(isHost: false) }

    private func start(isHost: Bool) {
        stop(); error = nil; samples.removeAll(); sample = LabSample(); exportedReport = nil
        guard let portNumber = UInt16(port), portNumber > 0 else { error = "端口应为 1–65535"; return }
        guard let mediaPortNumber = UInt16(mediaPort), mediaPortNumber > 0 else { error = "媒体端口应为 1–65535"; return }
        activePreset = preset; activeRoute = mediaRoute
        activeBridgeTransport = bridgeTransport; activeReceiveDepth = bridgeReceiveDepth
        mode = isHost ? "host" : "viewer"
        let token = UUID(); generation = token
        do {
            if isHost { pairingKey = try SignalTransport.newPairingKey() }
            let signal = SignalTransport()
            let engine = try PeerEngine(isHost: isHost, preset: activePreset, route: activeRoute, endpointHost: host, mediaPort: mediaPortNumber, receiveDepth: bridgeReceiveDepth, bridgeTransport: bridgeTransport)
            self.signal = signal; self.engine = engine
            engine.onSignal = { [weak signal] message in signal?.send(message) }
            signal.onMessage = { [weak engine] message in engine?.receive(message) }
            signal.onReady = { [weak engine] in if isHost { engine?.startOffer() } }
            let setStatus: (String) -> Void = { [weak self] value in
                guard let self, self.generation == token else { return }; self.status = value
            }
            signal.onStatus = setStatus; engine.onStatus = setStatus
            let failure: (String) -> Void = { [weak self] value in
                guard let self, self.generation == token else { return }
                self.stop(); self.error = value; self.status = "连接已结束"
            }
            signal.onFailure = failure; engine.onFailure = failure
            engine.onTrack = { [weak self] track in
                guard let self, self.generation == token else { return }; self.track = track
            }
            engine.onSample = { [weak self] value in
                guard let self, self.generation == token else { return }
                self.sample = value; self.samples.append(value)
                // At 1 Hz this retains one hour, with bounded memory on long tests.
                if self.samples.count > 3600 { self.samples.removeFirst() }
            }
            if isHost { try signal.listen(key: pairingKey, port: portNumber) }
            else { try signal.connect(host: host, key: pairingKey, port: portNumber) }
            running = true; status = isHost ? "正在启动测试源" : "连接配对信令…"
        } catch { stop(); self.error = error.localizedDescription }
    }

    func startLocalDemo(endpoint: String = "127.0.0.1", useCurrentPreset: Bool = false) {
        stop()
        let local = LabModel()
        local.bridgeTransport = bridgeTransport
        local.bridgeReceiveDepth = bridgeReceiveDepth
        local.mediaRoute = mediaRoute
        local.resolution = useCurrentPreset ? resolution : "1280×720"
        local.fps = useCurrentPreset ? fps : 30; local.megabits = useCurrentPreset ? megabits : 8
        local.pattern = useCurrentPreset ? pattern : .grid
        local.port = String(UInt16.random(in: 49000...59000))
        local.mediaPort = String(UInt16.random(in: 49000...59000))
        local.startHost()
        guard local.running else { error = local.error; return }
        host = endpoint; port = local.port; pairingKey = local.pairingKey; mediaPort = local.mediaPort
        resolution = local.resolution; fps = local.fps; megabits = local.megabits; pattern = local.pattern
        connect()
        demoHost = local; mode = "local-loopback"
        networkLabel = "本机回环（不代表远程网络）"
    }
    var localHostError: String? { demoHost?.error }
    func exportLocalHostReport(to destination: URL) {
        demoHost?.exportReport(to: destination)
        if let error = demoHost?.error { self.error = error }
    }

    func stop() {
        generation = UUID()
        engine?.stop(); engine = nil; signal?.stop(); signal = nil
        demoHost?.stop(); demoHost = nil
        track = nil; running = false; status = "已停止"
    }

    func exportReport(to destination: URL? = nil) {
        let report = LabReport(schemaVersion: 4,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            backend: "libwebrtc M157 / H.264 SDR", os: ProcessInfo.processInfo.operatingSystemVersionString,
            mode: mode, networkLabel: networkLabel, actualOverlayPath: "unknown", pacing: WebRTCRuntime.mode,
            pacingParameters: WebRTCRuntime.mode.screenShareSettings, bridgeReceiveDepth: activeReceiveDepth, bridgeTransport: activeBridgeTransport, mediaRoute: activeRoute, preset: activePreset,
            notes: [activeRoute != .directICE ? "Fixed UDP carries ICE/DTLS/SRTP/SCTP through the configured endpoint. The outer Ponte channel is not observed." : "Direct ICE can use any reachable adapter; the network label does not constrain it.",
                    "Control RTT is an echoed DataChannel round trip, not input-to-photon latency.",
                    "Send/decode/jitter-buffer delays are means over each stats interval; their P95 is not a per-frame P95. Encoder callback timing includes submission-to-callback work.",
                    "Pacing queue time is a drain target, not a hard packet lifetime. A full-size UDP probe proves delivery at setup, not the path IP MTU or sustained capacity.",
                    "Socket scope alone cannot prove physical topology: a remote overlay proxy can present a loopback endpoint. Local-demo mode is always a single-device test.",
                    "Socket transport is IPv4-only. Bridge sequence holes can include sender discards or reordering; they are not automatically permanent network loss. Frame gaps measure renderer callbacks, not display photons.",
                    "Queue age only covers the application adapter, not OS/overlay/encoder queues. P95 covers the latest 120 successful echoes; probe counters expose expiration.",
                    "Candidate host/UDP does not prove Tailscale direct or a Ponte channel type.",
                    "This is a synthetic H.264 SDR baseline, not HEVC/HDR or window-capture qualification.",
                    "Report excludes pairing key, SDP, endpoint addresses, user input and video content."], samples: samples)
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let path = destination ?? FileManager.default.temporaryDirectory.appendingPathComponent("KKRemote-Lab-\(UUID().uuidString.prefix(8)).json")
            try encoder.encode(report).write(to: path, options: .atomic)
            exportedReport = path
        } catch { self.error = "导出失败：\(error.localizedDescription)" }
    }
}
