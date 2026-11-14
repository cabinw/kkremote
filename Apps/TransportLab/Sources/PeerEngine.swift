import Foundation
import WebRTC
#if os(macOS)
import CoreImage
import AppKit
#else
import UIKit
#endif

enum MediaRoute: String, Codable, CaseIterable, Identifiable {
    case directICE = "direct-ice"
    case ponteUDPv1 = "fixed-udp-v1"
    case ponteUDP = "fixed-udp-v2"
    var id: String { rawValue }
    var wireVersion: MediaWireVersion { self == .ponteUDPv1 ? .v1 : .v2 }
    var title: String {
        switch self {
        case .directICE: return "原生 ICE（局域网对照）"
        case .ponteUDPv1: return "固定 UDP v1（旧版对照）"
        case .ponteUDP: return "固定 UDP v2（Ponte）"
        }
    }
}

struct LabSample: Codable {
    var seconds: Double = 0
    var videoMbps: Double = 0
    var fps: Double = 0
    var width: Int = 0
    var height: Int = 0
    var framesDecoded: Int = 0
    var framesEncoded: Int = 0
    var framesSent: Int = 0
    var sourceFrames: Int = 0
    var qualityLimitationReason: String = "unknown"
    var packetsLost: Int = 0
    var nackCount: Int = 0
    var networkRTTMilliseconds: Double? = nil
    var controlRTTMilliseconds: Double? = nil
    var controlP95Milliseconds: Double? = nil
    var controlResponseAgeMilliseconds: Double? = nil
    var jitterMilliseconds: Double? = nil
    var candidatePair: String = "unknown"
    var codec: String = "unknown"
    var codecParameters: String = "unknown"
    var encoderDetails: EncoderSample? = nil
    var receiverDetails: ReceiverSample? = nil
    var captureDetails: CaptureSample? = nil
    var decodedPixelFormat: [String: String]? = nil
    var decoded10BitSamples: [String: Int]? = nil
    var displayHeadroom: Double? = nil
    var potentialDisplayHeadroom: Double? = nil
    var encoder: String = "unknown"
    var decoder: String = "unknown"
    var bridge: BridgeSample? = nil
    var resources: ResourceSample? = nil
    var firstFrameMilliseconds: Double? = nil
    var encodeMilliseconds: Double? = nil
    var decodeMilliseconds: Double? = nil
    var jitterBufferMilliseconds: Double? = nil
    var sendDelayMilliseconds: Double? = nil
    var framesDropped: Int = 0
    var freezeCount: Int = 0
    var packetsReceived: Int?
    var packetsSent: Int?
    var retransmittedPacketsReceived: Int?
    var retransmittedPacketsSent: Int?
    var rtpPayloadBytes: UInt64?
    var rtpHeaderBytes: UInt64?
    var retransmittedPayloadBytes: UInt64?
    var transportBytesSent: UInt64?
    var transportBytesReceived: UInt64?
    var playoutDelayExtensionNegotiated: Bool?
    var pliCount: Int?
    var jitterBufferTargetMilliseconds: Double?
    var jitterBufferMinimumMilliseconds: Double?
    var frameGapP95Milliseconds: Double?
    var frameGapMaxMilliseconds: Double?
    var availableOutgoingMbps: Double? = nil
    var probeSent = 0
    var probeReceived = 0
    var probeExpired = 0
}

final class FrameCounter: NSObject, RTCVideoRenderer {
    var trace: FrameTrace?
    private let lock = NSLock()
    private var count = 0
    private var firstTime: Double?
    private var lastTime: Double?
    private var gaps: [Double] = []
    private var previewEnabled = false
    private var previewFrame: RTCVideoFrame?
    private var pixelFormat: [String: String]?
    private var pixelSamples: [String: Int]?
    var decodedFormat: [String: String]? { lock.lock(); defer { lock.unlock() }; return pixelFormat }
    var decodedSamples: [String: Int]? { lock.lock(); defer { lock.unlock() }; return pixelSamples }
    func enablePreview() { lock.lock(); previewEnabled = true; lock.unlock() }
    #if os(macOS)
    func savePreview(to url: URL) throws {
        lock.lock(); let frame = previewFrame; lock.unlock()
        guard let buffer = frame?.buffer as? RTCCVPixelBuffer else {
            throw LabError.message("没有可导出的原生解码帧")
        }
        let image = CIImage(cvPixelBuffer: buffer.pixelBuffer)
        try CIContext().writePNGRepresentation(of: image, to: url, format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }
    #endif
    var received: Int { lock.lock(); defer { lock.unlock() }; return count }
    var firstReceivedAt: Double? { lock.lock(); defer { lock.unlock() }; return firstTime }
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard frame != nil else { return }
        if let frame { trace?.record(.rendererCallback, ptsNs: frame.timeStampNs, rtp: UInt32(bitPattern: frame.timeStamp)) }
        lock.lock(); count += 1
        if count == 1, let buffer = frame?.buffer as? RTCCVPixelBuffer { pixelFormat = HDRFormat.description(buffer.pixelBuffer) }
        if count % 60 == 1, let buffer = frame?.buffer as? RTCCVPixelBuffer { pixelSamples = HDRFormat.lumaSamples(buffer.pixelBuffer) }
        if previewEnabled { previewFrame = frame }
        let now = ProcessInfo.processInfo.systemUptime
        if firstTime == nil { firstTime = now }
        if let lastTime {
            gaps.append((now - lastTime) * 1000)
            if gaps.count > 600 { gaps.removeFirst(gaps.count - 600) }
        }
        lastTime = now
        lock.unlock()
    }
    func gapSnapshot() -> (Double?, Double?) {
        lock.lock(); defer { lock.unlock() }
        guard !gaps.isEmpty else { return (nil, nil) }
        let sorted = gaps.sorted()
        gaps.removeAll(keepingCapacity: true)
        return (sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1], sorted.last)
    }
}

/// One lab peer. All mutable session state is accessed on the main queue.
final class PeerEngine: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate {
    private let resourceTelemetry = ResourceTelemetry()
    private var factory: RTCPeerConnectionFactory!
    private let encoderTelemetry: EncoderTelemetry
    private let traceDirectory: URL?
    private let receiverTelemetry: ReceiverTelemetry
    private var sdkDropDiagnostics: SDKDropDiagnostics?
    private var peer: RTCPeerConnection!
    private var channel: RTCDataChannel?
    private var source: LabVideoSource?
    private var makeSource: ((Bool) throws -> LabVideoSource)?
    private var requestedHDR = false
    private var negotiatedHDR = false
    private var sdrReceiver = false
    private var timer: Timer?
    private var remoteCandidates: [RTCIceCandidate] = []
    private var remoteReady = false
    private var stopped = false
    private var session: String?
    var sessionID: String? { session }
    private let isHost: Bool
    private let preset: LabPreset
    private let route: MediaRoute
    private let endpointHost: String
    private let mediaPort: UInt16
    private let receiveDepth: Int
    private let bridgeTransport: BridgeTransportKind
    private var bridge: DatagramBridge?
    private var localBridgeCandidate: RTCIceCandidate?
    private var bridgeCandidateAdded = false
    private var negotiatedAt: Double?
    private var firstFrameAt: Double?
    private var observedFreezeCount = 0
    private var previousCounters: [String: (Double, Double)] = [:]
    private var probesSent = 0, probesReceived = 0, probesExpired = 0
    private let started = ProcessInfo.processInfo.systemUptime
    private var previousBytes: [String: (Double, Double)] = [:]
    private var outstandingPings: [String: UInt64] = [:]
    private var rtts: [Double] = []
    private var lastPongAt: Double?
    private var remoteTrack: RTCVideoTrack?
    let frameCounter = FrameCounter()
    var onSignal: ((SignalMessage) -> Void)?
    var onTrack: ((RTCVideoTrack) -> Void)?
    var onStatus: ((String) -> Void)?
    var onSample: ((LabSample) -> Void)?
    var onFailure: ((String) -> Void)?
    var onSourceFailure: ((String) -> Void)?

    init(isHost: Bool, preset: LabPreset, route: MediaRoute = .directICE, endpointHost: String = "", mediaPort: UInt16 = 45991, receiveDepth: Int = 16, bridgeTransport: BridgeTransportKind = .network, captureWindowID: UInt32? = nil, expectedWindowProcessID: Int32? = nil, nativeWindowPixels: Bool = false, windowViewport: WindowViewport? = nil, requiresNativeClientPixels: Bool = false, hdr: Bool = false, sdrReceiver: Bool = false, traceDirectory: URL? = nil) throws {
        self.traceDirectory = traceDirectory
        encoderTelemetry = EncoderTelemetry(trace: traceDirectory != nil ? FrameTrace(role: isHost ? "sender" : "receiver",
            probes: ["sdkDropDiagnostics": WebRTCRuntime.sdkDropDiagnostics, "frameDropperDisabled": WebRTCRuntime.disableFrameDropperForSelfTest],
            settings: ["requestedHEVCKeyframeSeconds": Int(WebRTCRuntime.hevcKeyframeSeconds),
                       "simulatedOutageMilliseconds": DatagramBridge.simulateLossInSelfTest ? DatagramBridge.simulatedOutageMilliseconds : 0]) : nil)
        receiverTelemetry = ReceiverTelemetry(trace: encoderTelemetry.trace)
        self.isHost = isHost; self.preset = preset; self.route = route
        self.endpointHost = endpointHost; self.mediaPort = mediaPort
        self.receiveDepth = receiveDepth; self.bridgeTransport = bridgeTransport
        self.requestedHDR = hdr
        self.sdrReceiver = sdrReceiver
        self.session = isHost ? UUID().uuidString : nil
        super.init()
        frameCounter.trace = encoderTelemetry.trace
        if isHost, WebRTCRuntime.sdkDropDiagnostics, let trace = encoderTelemetry.trace {
            sdkDropDiagnostics = SDKDropDiagnostics(trace: trace)
        }
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.iceServers = []
        configuration.bundlePolicy = .maxBundle
        configuration.rtcpMuxPolicy = .require
        configuration.tcpCandidatePolicy = .disabled
        configuration.continualGatheringPolicy = .gatherOnce
        WebRTCRuntime.initialize(WebRTCRuntime.mode)
        let factory = RTCPeerConnectionFactory(encoderFactory: hdr ? HEVCEncoderFactory(telemetry: encoderTelemetry) : LabH264EncoderFactory(telemetry: encoderTelemetry), decoderFactory: sdrReceiver ? LabH264DecoderFactory(telemetry: receiverTelemetry) : HEVCDecoderFactory(telemetry: receiverTelemetry))
        self.factory = factory
        if route != .directICE {
            let options = RTCPeerConnectionFactoryOptions()
            options.ignoreLoopbackNetworkAdapter = false
            options.ignoreVPNNetworkAdapter = true; options.ignoreWiFiNetworkAdapter = true
            options.ignoreEthernetNetworkAdapter = true; options.ignoreCellularNetworkAdapter = true
            factory.setOptions(options)
        }
        guard let pc = factory.peerConnection(with: configuration,
                constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self) else {
            throw LabError.message("无法创建 WebRTC 会话")
        }
        peer = pc
        if isHost {
            let videoSource = factory.videoSource(forScreenCast: true)
            let track = factory.videoTrack(with: videoSource, trackId: "pattern")
            let transceiver = RTCRtpTransceiverInit()
            transceiver.direction = .sendOnly
            guard let videoTransceiver = pc.addTransceiver(with: track, init: transceiver) else {
                throw LabError.message("无法创建视频轨道")
            }
            enableTraceExtension(videoTransceiver)
            let sender = videoTransceiver.sender
            let parameters = sender.parameters
            // Preserve source dimensions; report real encoded/decoded dimensions as well.
            parameters.degradationPreference = NSNumber(value: RTCDegradationPreference.maintainResolution.rawValue)
            for encoding in parameters.encodings {
                encoding.maxBitrateBps = NSNumber(value: preset.megabits * 1_000_000)
                encoding.maxFramerate = NSNumber(value: preset.fps)
                encoding.scaleResolutionDownBy = 1
            }
            sender.parameters = parameters
            // Start at a modest estimate for desktop detail. This is not a minimum:
            // congestion control may reduce it immediately.
            _ = pc.setBweMinBitrateBps(nil, currentBitrateBps: NSNumber(value: min(4, preset.megabits) * 1_000_000),
                maxBitrateBps: NSNumber(value: preset.megabits * 1_000_000))
            makeSource = { [weak self] hdr in
                let trace = self?.encoderTelemetry.trace
                #if os(macOS)
                if let captureWindowID {
                    return WindowCaptureSource(source: videoSource, preset: preset, windowID: captureWindowID, expectedProcessID: expectedWindowProcessID, hdr: hdr, nativeWindowPixels: nativeWindowPixels, viewport: windowViewport, requiresNativeClientPixels: requiresNativeClientPixels, trace: trace) { [weak self] message in
                        guard let self, !self.stopped else { return }
                        if let onSourceFailure = self.onSourceFailure { onSourceFailure(message) }
                        else { self.onFailure?(message) }
                    }
                }
                #endif
                if hdr { return try HDRTestPattern(source: videoSource, width: preset.width, height: preset.height, fps: preset.fps, trace: trace) }
                return try TestPattern(source: videoSource, preset: preset, trace: trace)
            }
            let settings = RTCDataChannelConfiguration()
            settings.isOrdered = true
            channel = pc.dataChannel(forLabel: "control-probe", configuration: settings)
            channel?.delegate = self
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.poll(); self?.ping()
        }
    }

    func startOffer() {
        guard isHost, !stopped else { return }
        negotiatedAt = ProcessInfo.processInfo.systemUptime
        if route != .directICE {
            do {
                let encoded = try SignalTransport.newPairingKey()
                let bridge = try DatagramBridge(secret: Data(base64Encoded: encoded)!, session: session!, isHost: true, version: route.wireVersion, receiveDepth: receiveDepth, transport: bridgeTransport, trace: encoderTelemetry.trace?.rtp)
                install(bridge)
                bridge.onReady = { [weak self] in
                    guard let self, !self.stopped, let session = self.session else { return }
                    self.onSignal?(SignalMessage(type: "bridge", session: session, bridgeVersion: self.route.wireVersion.rawValue, mediaPort: self.mediaPort, mediaKey: encoded))
                    self.makeOffer()
                }
                try bridge.startHost(port: mediaPort)
            } catch { onFailure?(error.localizedDescription) }
        } else { makeOffer() }
    }

    private func makeOffer() {
        peer.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { [weak self] sdp, error in
            DispatchQueue.main.async {
                guard let self, !self.stopped else { return }
                guard let sdp, error == nil else { self.onFailure?("无法生成 SDP offer"); return }
                self.publish(sdp)
            }
        }
    }

    private func publish(_ sdp: RTCSessionDescription) {
        peer.setLocalDescription(sdp) { [weak self] error in
            DispatchQueue.main.async {
                guard let self, !self.stopped, let session = self.session else { return }
                guard error == nil else { self.onFailure?("无法设置本地 SDP"); return }
                if sdp.type == .answer { self.encoderTelemetry.trace?.rtp.configure(RTPTraceConfiguration.parse(sdp.sdp)) }
                let text = self.route != .directICE ? Self.withoutCandidates(sdp.sdp) : sdp.sdp
                self.onSignal?(SignalMessage(type: sdp.type == .offer ? "offer" : "answer", session: session, sdp: text,
                    videoFormat: self.sdrReceiver ? nil : (HDRFormat.prefersMain10(text) ? "hevc-main10-pq" : "h264-sdr")))
            }
        }
    }

    func receive(_ message: SignalMessage) {
        guard !stopped else { return }
        if session == nil && !isHost { session = message.session }
        guard session == message.session else { onFailure?("信令会话不匹配"); return }
        switch message.type {
        case "bridge":
            guard !isHost, route != .directICE, bridge == nil, message.bridgeVersion == route.wireVersion.rawValue,
                  let port = message.mediaPort, port > 0,
                  let encoded = message.mediaKey, let key = Data(base64Encoded: encoded), key.count == 32 else {
                onFailure?("固定 UDP 模式不匹配或配置无效；两端需要新版 Lab 并选择相同媒体模式"); return
            }
            do {
                let bridge = try DatagramBridge(secret: key, session: message.session, isHost: false, version: route.wireVersion, receiveDepth: receiveDepth, transport: bridgeTransport, trace: encoderTelemetry.trace?.rtp)
                install(bridge)
                try bridge.startViewer(host: endpointHost, port: port)
            } catch { onFailure?(error.localizedDescription) }
        case "candidate":
            guard route == .directICE else { onFailure?("固定 UDP 会话拒绝外部 ICE 候选"); return }
            guard let value = message.candidate, let line = message.line, line >= 0 else { return }
            let candidate = RTCIceCandidate(sdp: value, sdpMLineIndex: line, sdpMid: message.mid)
            if remoteReady { add(candidate) }
            else if remoteCandidates.count < 128 { remoteCandidates.append(candidate) }
            else { onFailure?("ICE 候选数量超过上限") }
        case "offer", "answer":
            guard route == .directICE || bridge != nil else { onFailure?("主机未协商固定 UDP 模式；请核对两端版本和模式"); return }
            guard let sdp = message.sdp, (message.type == "answer") == isHost else { onFailure?("意外 SDP 类型"); return }
            guard !remoteReady else { onFailure?("测试会话不接受重复 SDP"); return }
            negotiatedAt = negotiatedAt ?? ProcessInfo.processInfo.systemUptime
            let remoteSDP = route != .directICE ? Self.withoutCandidates(sdp) : sdp
            peer.setRemoteDescription(RTCSessionDescription(type: isHost ? .answer : .offer, sdp: remoteSDP)) { [weak self] error in
                DispatchQueue.main.async {
                    guard let self, !self.stopped else { return }
                    guard error == nil else { self.onFailure?("无法设置远端 SDP"); return }
                    self.remoteReady = true
                    if self.isHost {
                        self.encoderTelemetry.trace?.rtp.configure(RTPTraceConfiguration.parse(sdp))
                        if HDRFormat.prefersMain10(sdp) && message.videoFormat != "hevc-main10-pq" {
                            self.onFailure?("接收端未确认 Main10 PQ 色彩路径，已拒绝启动 HDR"); return
                        }
                        self.negotiatedHDR = self.requestedHDR && message.videoFormat == "hevc-main10-pq" && HDRFormat.prefersMain10(sdp)
                        if self.requestedHDR && !self.negotiatedHDR { self.onStatus?("接收端选择 H.264，已回退到 SDR") }
                        self.startSourceIfReady()
                    }
                    self.addBridgeCandidateIfReady()
                    self.remoteCandidates.forEach { self.add($0) }; self.remoteCandidates.removeAll()
                    if !self.isHost {
                        self.peer.transceivers.forEach { self.enableTraceExtension($0) }
                        self.peer.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { [weak self] answer, error in
                            DispatchQueue.main.async {
                                guard let self, !self.stopped else { return }
                                guard let answer, error == nil else { self.onFailure?("无法生成 SDP answer"); return }
                                self.publish(answer)
                            }
                        }
                    }
                }
            }
        default: onFailure?("未知信令类型")
        }
    }

    private func add(_ candidate: RTCIceCandidate) {
        peer.add(candidate) { [weak self] error in
            if error != nil { DispatchQueue.main.async { self?.onStatus?("部分 ICE 候选未被接受") } }
        }
    }

    private func enableTraceExtension(_ transceiver: RTCRtpTransceiver) {
        guard encoderTelemetry.trace != nil else { return }
        let extensions = transceiver.headerExtensionsToNegotiate
        guard let capture = extensions.first(where: { $0.uri == RTPTraceConfiguration.captureURI && !$0.isPreferredEncrypted }) else { return }
        capture.direction = .sendRecv
        // Public SDK negotiation, no SDP rewriting. Old peers may decline; mapping then stays unknown.
        try? transceiver.setHeaderExtensionsToNegotiate(extensions)
    }

    private func startSourceIfReady() {
        guard isHost, !stopped, remoteReady, source == nil,
              peer.iceConnectionState == .connected || peer.iceConnectionState == .completed,
              let makeSource else { return }
        do { source = try makeSource(negotiatedHDR); source?.start() }
        catch { onFailure?("无法启动协商的视频源：\(error.localizedDescription)") }
    }

    private func install(_ bridge: DatagramBridge) {
        self.bridge = bridge
        bridge.onAuthenticated = { [weak self] in
            guard let self, !self.stopped else { return }
            self.onStatus?("固定 UDP 已认证，正在验证 ICE / DTLS / 视频")
        }
        bridge.onFailure = { [weak self] message in
            guard let self, !self.stopped else { return }; self.onFailure?(message)
        }
    }
    private func addBridgeCandidateIfReady() {
        guard remoteReady, !bridgeCandidateAdded, let bridge, let candidate = localBridgeCandidate else { return }
        bridgeCandidateAdded = true
        // This candidate points to our own adapter socket, never to a rewritten public/LAN IP.
        let sdp = "candidate:kkudp 1 udp 2130706431 127.0.0.1 \(bridge.localPort) typ host"
        add(RTCIceCandidate(sdp: sdp, sdpMLineIndex: candidate.sdpMLineIndex, sdpMid: candidate.sdpMid))
    }
    private static func withoutCandidates(_ sdp: String) -> String {
        sdp.components(separatedBy: "\r\n").filter { !$0.hasPrefix("a=candidate:") && $0 != "a=end-of-candidates" }.joined(separator: "\r\n")
    }

    private func receiveTrack(_ track: RTCVideoTrack?) {
        guard !stopped, let track, remoteTrack !== track else { return }
        remoteTrack?.remove(frameCounter)
        if let old = remoteTrack { PresentationDiagnostics.remove(old); receiverTelemetry.endPresentations() }
        PresentationDiagnostics.register(track, telemetry: receiverTelemetry)
        remoteTrack = track; track.add(frameCounter); onTrack?(track)
    }

    func stop(completion: @escaping () -> Void = {}) {
        guard !stopped else { completion(); return }
        encoderTelemetry.trace?.record(.mediaStop)
        stopped = true; timer?.invalidate(); timer = nil; source?.stop(); source = nil
        receiverTelemetry.endPresentations()
        if let remoteTrack { remoteTrack.remove(frameCounter); PresentationDiagnostics.remove(remoteTrack) }; remoteTrack = nil
        channel?.delegate = nil; channel?.close(); channel = nil
        peer.delegate = nil; peer.close(); outstandingPings.removeAll()
        sdkDropDiagnostics?.stop(); sdkDropDiagnostics = nil
        let trace = encoderTelemetry.trace, directory = traceDirectory
        if directory != nil { trace?.beginShutdown() }
        let drained = {
            // Include queued-packet cancellation and socket shutdown in the exported trace.
            if let trace, let directory {
                do { try trace.write(to: directory) }
                catch { print("FRAME_TRACE_EXPORT_FAILED: \(error.localizedDescription)") }
                trace.endShutdown()
            }
            completion()
        }
        if let bridge { self.bridge = nil; bridge.stop(completion: drained) }
        else { drained() }
    }

    private func ping() {
        guard !stopped else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        probesExpired += outstandingPings.filter { now - $0.value >= 10_000_000_000 }.count
        outstandingPings = outstandingPings.filter { now - $0.value < 10_000_000_000 }
        guard let channel, channel.readyState == .open, channel.bufferedAmount < 4096 else { return }
        let id = UUID().uuidString
        if channel.sendData(RTCDataBuffer(data: Data("ping:\(id)".utf8), isBinary: false)) { outstandingPings[id] = now; probesSent += 1 }
    }

    private func poll() {
        guard !stopped else { return }
        if !isHost, firstFrameAt == nil, let negotiatedAt {
            if let first = frameCounter.firstReceivedAt { firstFrameAt = first }
            else if ProcessInfo.processInfo.systemUptime - negotiatedAt > 30 {
                onFailure?("媒体协商后 30 秒仍无解码帧：检查 UDP / ICE / 编码阶段"); return
            }
        }
        peer.statistics { [weak self] report in
            DispatchQueue.main.async { self?.consume(report) }
        }
    }

    private func consume(_ report: RTCStatisticsReport) {
        guard !stopped else { return }
        var sample = LabSample()
        sample.resources = resourceTelemetry.snapshot()
        sample.playoutDelayExtensionNegotiated = peer.localDescription?.sdp.contains("http://www.webrtc.org/experiments/rtp-hdrext/playout-delay") == true && peer.remoteDescription?.sdp.contains("http://www.webrtc.org/experiments/rtp-hdrext/playout-delay") == true
        sample.decodedPixelFormat = frameCounter.decodedFormat
        sample.decoded10BitSamples = frameCounter.decodedSamples
        #if os(macOS)
        sample.displayHeadroom = NSScreen.main.map { Double($0.maximumExtendedDynamicRangeColorComponentValue) }
        sample.potentialDisplayHeadroom = NSScreen.main.map { Double($0.maximumPotentialExtendedDynamicRangeColorComponentValue) }
        #else
        sample.displayHeadroom = Double(UIScreen.main.currentEDRHeadroom)
        sample.potentialDisplayHeadroom = Double(UIScreen.main.potentialEDRHeadroom)
        #endif
        let now = ProcessInfo.processInfo.systemUptime
        sample.seconds = now - started
        sample.bridge = bridge?.snapshot()
        if !isHost { sample.receiverDetails = receiverTelemetry.snapshot() }
        (sample.frameGapP95Milliseconds, sample.frameGapMaxMilliseconds) = frameCounter.gapSnapshot()
        if isHost {
            sample.encoderDetails = encoderTelemetry.snapshot()
            sample.captureDetails = source?.captureSnapshot()
        }
        if let firstFrameAt, let negotiatedAt { sample.firstFrameMilliseconds = (firstFrameAt - negotiatedAt) * 1000 }
        sample.probeSent = probesSent; sample.probeReceived = probesReceived; sample.probeExpired = probesExpired
        let values = Array(report.statistics.values)
        if let source = values.first(where: { $0.type == "media-source" && $0.values["kind"] as? String == "video" }) {
            sample.sourceFrames = (source.values["frames"] as? NSNumber)?.intValue ?? 0
        }
        let kind = isHost ? "outbound-rtp" : "inbound-rtp"
        if let video = values.first(where: { $0.type == kind && ($0.values["kind"] as? String == "video" || $0.values["mediaType"] as? String == "video") }) {
            func number(_ key: String) -> Double { (video.values[key] as? NSNumber)?.doubleValue ?? 0 }
            let bytes = number(isHost ? "bytesSent" : "bytesReceived")
            if let previous = previousBytes[video.id], now > previous.1, bytes >= previous.0 {
                sample.videoMbps = (bytes - previous.0) * 8 / (now - previous.1) / 1_000_000
            }
            previousBytes[video.id] = (bytes, now)
            sample.fps = number("framesPerSecond"); sample.width = Int(number("frameWidth")); sample.height = Int(number("frameHeight"))
            sample.framesDecoded = Int(number("framesDecoded")); sample.packetsLost = Int(number("packetsLost")); sample.nackCount = Int(number("nackCount"))
            sample.framesEncoded = Int(number("framesEncoded")); sample.framesSent = Int(number("framesSent"))
            sample.qualityLimitationReason = video.values["qualityLimitationReason"] as? String ?? "unknown"
            if video.values["jitter"] != nil { sample.jitterMilliseconds = number("jitter") * 1000 }
            sample.encoder = video.values["encoderImplementation"] as? String ?? "unknown"
            sample.decoder = video.values["decoderImplementation"] as? String ?? "unknown"
            sample.framesDropped = Int(number("framesDropped")); sample.freezeCount = Int(number("freezeCount"))
            sample.packetsReceived = (video.values["packetsReceived"] as? NSNumber)?.intValue
            sample.packetsSent = (video.values["packetsSent"] as? NSNumber)?.intValue
            sample.retransmittedPacketsReceived = (video.values["retransmittedPacketsReceived"] as? NSNumber)?.intValue
            sample.retransmittedPacketsSent = (video.values["retransmittedPacketsSent"] as? NSNumber)?.intValue
            sample.rtpPayloadBytes = (video.values[isHost ? "bytesSent" : "bytesReceived"] as? NSNumber)?.uint64Value
            sample.rtpHeaderBytes = (video.values[isHost ? "headerBytesSent" : "headerBytesReceived"] as? NSNumber)?.uint64Value
            sample.retransmittedPayloadBytes = (video.values[isHost ? "retransmittedBytesSent" : "retransmittedBytesReceived"] as? NSNumber)?.uint64Value
            sample.pliCount = (video.values["pliCount"] as? NSNumber)?.intValue
            func averageDelta(_ total: String, _ count: String) -> Double? {
                guard video.values[total] != nil, video.values[count] != nil else { return nil }
                let key = video.id + total, current = (number(total), number(count))
                defer { previousCounters[key] = current }
                guard let previous = previousCounters[key], current.1 > previous.1, current.0 >= previous.0 else { return nil }
                return (current.0 - previous.0) * 1000 / (current.1 - previous.1)
            }
            sample.encodeMilliseconds = averageDelta("totalEncodeTime", "framesEncoded")
            sample.decodeMilliseconds = averageDelta("totalDecodeTime", "framesDecoded")
            sample.jitterBufferMilliseconds = averageDelta("jitterBufferDelay", "jitterBufferEmittedCount")
            sample.jitterBufferTargetMilliseconds = averageDelta("jitterBufferTargetDelay", "jitterBufferEmittedCount")
            sample.jitterBufferMinimumMilliseconds = averageDelta("jitterBufferMinimumDelay", "jitterBufferEmittedCount")
            sample.sendDelayMilliseconds = averageDelta("totalPacketSendDelay", "packetsSent")
            if let id = video.values["codecId"] as? String {
                sample.codec = report.statistics[id]?.values["mimeType"] as? String ?? "unknown"
                sample.codecParameters = report.statistics[id]?.values["sdpFmtpLine"] as? String ?? "unknown"
            }
        }
        let transport = values.first { $0.type == "transport" && $0.values["selectedCandidatePairId"] != nil }
        sample.transportBytesSent = (transport?.values["bytesSent"] as? NSNumber)?.uint64Value
        sample.transportBytesReceived = (transport?.values["bytesReceived"] as? NSNumber)?.uint64Value
        if let id = transport?.values["selectedCandidatePairId"] as? String, let pair = report.statistics[id] {
            sample.networkRTTMilliseconds = (pair.values["currentRoundTripTime"] as? NSNumber).map { $0.doubleValue * 1000 }
            sample.availableOutgoingMbps = (pair.values["availableOutgoingBitrate"] as? NSNumber).map { $0.doubleValue / 1_000_000 }
            func describe(_ key: String) -> String {
                guard let id = pair.values[key] as? String, let candidate = report.statistics[id] else { return "unknown" }
                let type = candidate.values["candidateType"] as? String ?? "unknown"
                let proto = candidate.values["protocol"] as? String ?? "unknown"
                return "\(type)/\(proto)"
            }
            sample.candidatePair = "\(describe("localCandidateId")) → \(describe("remoteCandidateId"))"
        }
        sample.controlRTTMilliseconds = rtts.last
        sample.controlResponseAgeMilliseconds = lastPongAt.map { (now - $0) * 1000 }
        if !rtts.isEmpty { let sorted = rtts.sorted(); sample.controlP95Milliseconds = sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)] }
        if !isHost, sample.freezeCount > observedFreezeCount {
            if encoderTelemetry.trace?.captureFirstIncident(reason: "sdk_freeze_count_increased") == true,
               let channel, channel.readyState == .open, channel.bufferedAmount < 4096 {
                _ = channel.sendData(RTCDataBuffer(data: Data("diagnostic:first-freeze".utf8), isBinary: false))
            }
        }
        observedFreezeCount = max(observedFreezeCount, sample.freezeCount)
        onSample?(sample)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { return }
            let states: [RTCIceConnectionState: String] = [.new: "等待 ICE", .checking: "正在检查媒体路径", .connected: "媒体 ICE 已连接", .completed: "媒体 ICE 已就绪", .disconnected: "媒体路径暂时断开", .failed: "媒体 ICE 失败", .closed: "媒体 ICE 已关闭", .count: "未知 ICE 状态"]
            self.onStatus?(states[newState] ?? "未知 ICE 状态")
            if newState == .connected || newState == .completed { self.startSourceIfReady() }
            if newState == .failed { self.onFailure?("ICE 媒体连接失败：信令已通，但 UDP 候选路径不可达") }
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped, let session = self.session else { return }
            if self.route != .directICE {
                let fields = candidate.sdp.split(separator: " ")
                guard self.localBridgeCandidate == nil, fields.count >= 8, fields[2].lowercased() == "udp",
                      fields[4] == "127.0.0.1", let port = UInt16(fields[5]), port > 0, let bridge = self.bridge else { return }
                self.localBridgeCandidate = candidate; bridge.setLocalPeer(port: port)
                self.addBridgeCandidateIfReady(); return
            }
            self.onSignal?(SignalMessage(type: "candidate", session: session, candidate: candidate.sdp, mid: candidate.sdpMid, line: candidate.sdpMLineIndex))
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { dataChannel.close(); return }
            self.channel = dataChannel; dataChannel.delegate = self
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        DispatchQueue.main.async { [weak self] in self?.receiveTrack(rtpReceiver.track as? RTCVideoTrack) }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {
        DispatchQueue.main.async { [weak self] in self?.receiveTrack(transceiver.receiver.track as? RTCVideoTrack) }
    }
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {}
    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard buffer.data.count < 256, let text = String(data: buffer.data, encoding: .utf8) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { return }
            if text.hasPrefix("ping:") {
                if dataChannel.bufferedAmount < 4096 { _ = dataChannel.sendData(RTCDataBuffer(data: Data(("pong:" + text.dropFirst(5)).utf8), isBinary: false)) }
            } else if text == "diagnostic:first-freeze", self.isHost {
                // Ignored unless this host explicitly enabled local frame tracing.
                // A single authenticated diagnostic marker cannot trigger repeated snapshots.
                self.encoderTelemetry.trace?.captureFirstIncident(reason: "remote_sdk_freeze_marker")
            } else if text.hasPrefix("pong:"), let sent = self.outstandingPings.removeValue(forKey: String(text.dropFirst(5))) {
                self.probesReceived += 1
                self.lastPongAt = ProcessInfo.processInfo.systemUptime
                self.rtts.append(Double(DispatchTime.now().uptimeNanoseconds - sent) / 1_000_000)
                if self.rtts.count > 120 { self.rtts.removeFirst() }
            }
        }
    }
}
