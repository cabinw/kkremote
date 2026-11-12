import Foundation
import WebRTC

struct LabSample: Codable {
    var seconds: Double = 0
    var videoMbps: Double = 0
    var fps: Double = 0
    var width: Int = 0
    var height: Int = 0
    var framesDecoded: Int = 0
    var packetsLost: Int = 0
    var nackCount: Int = 0
    var networkRTTMilliseconds: Double? = nil
    var controlRTTMilliseconds: Double? = nil
    var controlP95Milliseconds: Double? = nil
    var jitterMilliseconds: Double? = nil
    var candidatePair: String = "unknown"
    var codec: String = "unknown"
    var encoder: String = "unknown"
    var decoder: String = "unknown"
}

final class FrameCounter: NSObject, RTCVideoRenderer {
    private let lock = NSLock()
    private var count = 0
    var received: Int { lock.lock(); defer { lock.unlock() }; return count }
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard frame != nil else { return }
        lock.lock(); count += 1; lock.unlock()
    }
}

/// One lab peer. All mutable session state is accessed on the main queue.
final class PeerEngine: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate {
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: RTCVideoEncoderFactoryH264(), decoderFactory: RTCVideoDecoderFactoryH264())
    }()
    private var peer: RTCPeerConnection!
    private var channel: RTCDataChannel?
    private var source: TestPattern?
    private var timer: Timer?
    private var remoteCandidates: [RTCIceCandidate] = []
    private var remoteReady = false
    private var stopped = false
    private var session: String?
    private let isHost: Bool
    private let preset: LabPreset
    private let started = ProcessInfo.processInfo.systemUptime
    private var previousBytes: [String: (Double, Double)] = [:]
    private var outstandingPings: [String: UInt64] = [:]
    private var rtts: [Double] = []
    private var remoteTrack: RTCVideoTrack?
    let frameCounter = FrameCounter()
    var onSignal: ((SignalMessage) -> Void)?
    var onTrack: ((RTCVideoTrack) -> Void)?
    var onStatus: ((String) -> Void)?
    var onSample: ((LabSample) -> Void)?
    var onFailure: ((String) -> Void)?

    init(isHost: Bool, preset: LabPreset) throws {
        self.isHost = isHost; self.preset = preset
        self.session = isHost ? UUID().uuidString : nil
        super.init()
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.iceServers = []
        configuration.bundlePolicy = .maxBundle
        configuration.rtcpMuxPolicy = .require
        configuration.tcpCandidatePolicy = .disabled
        configuration.continualGatheringPolicy = .gatherOnce
        guard let pc = Self.factory.peerConnection(with: configuration,
                constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self) else {
            throw LabError.message("无法创建 WebRTC 会话")
        }
        peer = pc
        if isHost {
            let videoSource = Self.factory.videoSource(forScreenCast: true)
            let track = Self.factory.videoTrack(with: videoSource, trackId: "pattern")
            let transceiver = RTCRtpTransceiverInit()
            transceiver.direction = .sendOnly
            guard let sender = pc.addTransceiver(with: track, init: transceiver)?.sender else {
                throw LabError.message("无法创建视频轨道")
            }
            let parameters = sender.parameters
            // Preserve source dimensions; report real encoded/decoded dimensions as well.
            parameters.degradationPreference = NSNumber(value: RTCDegradationPreference.maintainResolution.rawValue)
            for encoding in parameters.encodings {
                encoding.maxBitrateBps = NSNumber(value: preset.megabits * 1_000_000)
                encoding.maxFramerate = NSNumber(value: preset.fps)
                encoding.scaleResolutionDownBy = 1
            }
            sender.parameters = parameters
            _ = pc.setBweMinBitrateBps(nil, currentBitrateBps: nil, maxBitrateBps: NSNumber(value: preset.megabits * 1_000_000))
            source = try TestPattern(source: videoSource, preset: preset)
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
                self.onSignal?(SignalMessage(type: sdp.type == .offer ? "offer" : "answer", session: session, sdp: sdp.sdp))
            }
        }
    }

    func receive(_ message: SignalMessage) {
        guard !stopped else { return }
        if session == nil && !isHost { session = message.session }
        guard session == message.session else { onFailure?("信令会话不匹配"); return }
        switch message.type {
        case "candidate":
            guard let value = message.candidate, let line = message.line, line >= 0 else { return }
            let candidate = RTCIceCandidate(sdp: value, sdpMLineIndex: line, sdpMid: message.mid)
            if remoteReady { add(candidate) }
            else if remoteCandidates.count < 128 { remoteCandidates.append(candidate) }
            else { onFailure?("ICE 候选数量超过上限") }
        case "offer", "answer":
            guard let sdp = message.sdp, (message.type == "answer") == isHost else { onFailure?("意外 SDP 类型"); return }
            guard !remoteReady else { onFailure?("测试会话不接受重复 SDP"); return }
            peer.setRemoteDescription(RTCSessionDescription(type: isHost ? .answer : .offer, sdp: sdp)) { [weak self] error in
                DispatchQueue.main.async {
                    guard let self, !self.stopped else { return }
                    guard error == nil else { self.onFailure?("无法设置远端 SDP"); return }
                    self.remoteReady = true
                    self.remoteCandidates.forEach { self.add($0) }; self.remoteCandidates.removeAll()
                    if !self.isHost {
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

    private func receiveTrack(_ track: RTCVideoTrack?) {
        guard !stopped, let track, remoteTrack !== track else { return }
        remoteTrack?.remove(frameCounter)
        remoteTrack = track; track.add(frameCounter); onTrack?(track)
    }

    func stop() {
        guard !stopped else { return }
        stopped = true; timer?.invalidate(); timer = nil; source?.stop(); source = nil
        remoteTrack?.remove(frameCounter); remoteTrack = nil
        channel?.delegate = nil; channel?.close(); channel = nil
        peer.delegate = nil; peer.close(); outstandingPings.removeAll()
    }

    private func ping() {
        guard !stopped, let channel, channel.readyState == .open, channel.bufferedAmount < 4096 else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        outstandingPings = outstandingPings.filter { now - $0.value < 10_000_000_000 }
        let id = UUID().uuidString
        if channel.sendData(RTCDataBuffer(data: Data("ping:\(id)".utf8), isBinary: false)) { outstandingPings[id] = now }
    }

    private func poll() {
        guard !stopped else { return }
        peer.statistics { [weak self] report in
            DispatchQueue.main.async { self?.consume(report) }
        }
    }

    private func consume(_ report: RTCStatisticsReport) {
        guard !stopped else { return }
        var sample = LabSample()
        let now = ProcessInfo.processInfo.systemUptime
        sample.seconds = now - started
        let values = Array(report.statistics.values)
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
            if video.values["jitter"] != nil { sample.jitterMilliseconds = number("jitter") * 1000 }
            sample.encoder = video.values["encoderImplementation"] as? String ?? "unknown"
            sample.decoder = video.values["decoderImplementation"] as? String ?? "unknown"
            if let id = video.values["codecId"] as? String { sample.codec = report.statistics[id]?.values["mimeType"] as? String ?? "unknown" }
        }
        let transport = values.first { $0.type == "transport" && $0.values["selectedCandidatePairId"] != nil }
        if let id = transport?.values["selectedCandidatePairId"] as? String, let pair = report.statistics[id] {
            sample.networkRTTMilliseconds = (pair.values["currentRoundTripTime"] as? NSNumber).map { $0.doubleValue * 1000 }
            func describe(_ key: String) -> String {
                guard let id = pair.values[key] as? String, let candidate = report.statistics[id] else { return "unknown" }
                let type = candidate.values["candidateType"] as? String ?? "unknown"
                let proto = candidate.values["protocol"] as? String ?? "unknown"
                return "\(type)/\(proto)"
            }
            sample.candidatePair = "\(describe("localCandidateId")) → \(describe("remoteCandidateId"))"
        }
        sample.controlRTTMilliseconds = rtts.last
        if !rtts.isEmpty { let sorted = rtts.sorted(); sample.controlP95Milliseconds = sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)] }
        onSample?(sample)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.onStatus?("ICE：\(newState.rawValue)")
            if newState == .connected || newState == .completed { if self.source != nil { self.source?.start() } }
            if newState == .failed { self.onFailure?("ICE 媒体连接失败：信令已通，但 UDP 候选路径不可达") }
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped, let session = self.session else { return }
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
            } else if text.hasPrefix("pong:"), let sent = self.outstandingPings.removeValue(forKey: String(text.dropFirst(5))) {
                self.rtts.append(Double(DispatchTime.now().uptimeNanoseconds - sent) / 1_000_000)
                if self.rtts.count > 120 { self.rtts.removeFirst() }
            }
        }
    }
}
