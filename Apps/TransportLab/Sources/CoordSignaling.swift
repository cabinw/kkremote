import Foundation
import CryptoKit

struct CoordWireMessage: Codable {
    var type: String
    var role: String? = nil
    var hostID: String? = nil
    var clientID: String? = nil
    var targetHostID: String? = nil
    var name: String? = nil
    var signPub: String? = nil
    var kexPub: String? = nil
    var ts: Int64? = nil
    var nonce: String? = nil
    var sig: String? = nil
    var stunServers: [String]? = nil
    var hostOnline: Bool? = nil
    var hostSignPub: String? = nil
    var hostKexPub: String? = nil
    var hostName: String? = nil

    var to: String? = nil
    var from: String? = nil
    var fromSignPub: String? = nil
    var fromKexPub: String? = nil
    var session: String? = nil
    var kind: String? = nil
    var e2eNonce: String? = nil
    var ciphertext: String? = nil
    var payloadSig: String? = nil
    var error: String? = nil
}

struct CoordConnectRequest: Codable {
    var protocolVersion: Int
    var session: String
    var pairToken: String? = nil
    var accessGrant: String? = nil
    var userAgent: String? = nil
}

struct CoordRejectPayload: Codable {
    var error: String
}

struct CoordOfferAnswerPayload: Codable {
    var session: String
    var sdp: String
    var dtlsFingerprint: String
    var videoFormat: String? = nil
    var accessGrant: String? = nil
    var windowProtocol: Int? = nil
    var windowSession: String? = nil
    var windowLayout: Bool? = nil
    var windowControl: Bool? = nil
    var windowKeyboard: Bool? = nil
}

struct CoordCandidatePayload: Codable {
    var session: String
    var candidate: String
    var mid: String? = nil
    var line: Int32? = nil
}

/// Outbound WSS zero-knowledge signaling transport shared across macOS, iOS, and Android/Web peers.
final class CoordSignaling {
    let identity: DeviceIdentity
    let wsURL: URL
    private let hostName: String
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var pingTimer: Timer?
    private var stopped = false

    private var isHostRole = true
    private(set) var stunServers: [String] = []

    // Active peer session context (one authenticated viewer session at a time, matching LabModel scope).
    private var activePeerID: String?
    private var activePeerSignPub: String?
    private var activeSessionID: String?
    private var activeKey: SymmetricKey?
    private var pendingIssuedGrant: String?

    // Client-side target host profile when acting as viewer.
    private var targetHostID: String?
    private var targetHostSignPub: String?
    private var targetHostKexPub: String?
    private var clientPairToken: String?
    private var clientAccessGrant: String?

    var onStatus: ((String) -> Void)?
    var onFailure: ((String) -> Void)?
    var onHostRegistered: (([String]) -> Void)?
    /// Fired on Host when an authorized viewer requests a session: (sessionID, stunServers)
    var onClientAuthorized: ((String, [String]) -> Void)?
    /// Fired on Viewer when Host is online and ready to start handshake, or when encrypted signaling arrives.
    var onSignal: ((SignalMessage) -> Void)?
    var onGrantReceived: ((String) -> Void)?

    init(identity: DeviceIdentity, coordURLString: String, hostName: String = Host.current().localizedName ?? "Mac Host") throws {
        self.identity = identity
        self.hostName = hostName
        var raw = coordURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("https://") { raw = "wss://" + raw.dropFirst("https://".count) }
        else if raw.hasPrefix("http://") { raw = "ws://" + raw.dropFirst("http://".count) }
        if !raw.hasSuffix("/v1/ws") {
            raw = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/ws"
        }
        guard let url = URL(string: raw), ["ws", "wss"].contains(url.scheme?.lowercased()) else {
            throw LabError.message("协调服务地址无效，应为 https:// 或 wss://")
        }
        self.wsURL = url
    }

    func startHost() {
        isHostRole = true
        connectSocket()
    }

    func startClient(targetHostID: String, hostSignPub: String, hostKexPub: String, pairToken: String?, accessGrant: String?) {
        isHostRole = false
        self.targetHostID = targetHostID.lowercased()
        self.targetHostSignPub = hostSignPub
        self.targetHostKexPub = hostKexPub
        self.clientPairToken = pairToken
        self.clientAccessGrant = accessGrant
        connectSocket()
    }

    private func connectSocket() {
        guard !stopped else { return }
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = true
        let urlSession = URLSession(configuration: config)
        self.session = urlSession
        let wsTask = urlSession.webSocketTask(with: wsURL)
        wsTask.maximumMessageSize = 65536
        self.task = wsTask
        wsTask.resume()
        receiveLoop(wsTask)
        sendHello(wsTask)

        DispatchQueue.main.async { [weak self] in
            self?.pingTimer?.invalidate()
            self?.pingTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
                self?.sendRaw(CoordWireMessage(type: "ping"))
            }
        }
    }

    private func sendHello(_ wsTask: URLSessionWebSocketTask) {
        do {
            let ts = Int64(Date().timeIntervalSince1970)
            let nonce = DeviceIdentity.randomToken(bytes: 12)
            if isHostRole {
                let signed = "kkremote-host-hello-v1|\(identity.deviceID)|\(identity.kexPubB64)|\(ts)|\(nonce)"
                let sig = try identity.signP1363(signed)
                let hello = CoordWireMessage(
                    type: "hostHello",
                    hostID: identity.deviceID,
                    name: hostName,
                    signPub: identity.signPubB64,
                    kexPub: identity.kexPubB64,
                    ts: ts,
                    nonce: nonce,
                    sig: sig
                )
                sendRaw(hello, on: wsTask)
            } else {
                guard let targetHostID else { return }
                let signed = "kkremote-client-hello-v1|\(identity.deviceID)|\(targetHostID)|\(identity.kexPubB64)|\(ts)|\(nonce)"
                let sig = try identity.signP1363(signed)
                let hello = CoordWireMessage(
                    type: "clientHello",
                    clientID: identity.deviceID,
                    targetHostID: targetHostID,
                    name: hostName,
                    signPub: identity.signPubB64,
                    kexPub: identity.kexPubB64,
                    ts: ts,
                    nonce: nonce,
                    sig: sig
                )
                sendRaw(hello, on: wsTask)
            }
        } catch {
            fail("身份签名失败：\(error.localizedDescription)")
        }
    }

    private func receiveLoop(_ wsTask: URLSessionWebSocketTask) {
        wsTask.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, !self.stopped, self.task === wsTask else { return }
                switch result {
                case .failure(let err):
                    self.fail("协调连接中断：\(err.localizedDescription)")
                case .success(let message):
                    let data: Data?
                    switch message {
                    case .string(let text): data = Data(text.utf8)
                    case .data(let bytes): data = bytes
                    @unknown default: data = nil
                    }
                    if let data, let wire = try? JSONDecoder().decode(CoordWireMessage.self, from: data) {
                        self.handleWire(wire)
                    }
                    self.receiveLoop(wsTask)
                }
            }
        }
    }

    private func handleWire(_ msg: CoordWireMessage) {
        switch msg.type {
        case "welcome":
            stunServers = msg.stunServers ?? []
            if isHostRole {
                onStatus?("协调服务在线 · 等待已授权设备连接")
                onHostRegistered?(stunServers)
            } else {
                if msg.hostOnline == true {
                    if let hostSignPub = msg.hostSignPub, let expected = targetHostSignPub, hostSignPub != expected {
                        fail("远端主机签名公钥不匹配，已拒绝连接")
                        return
                    }
                    if let kex = msg.hostKexPub { targetHostKexPub = kex }
                    beginClientSessionHandshake()
                } else {
                    onStatus?("协调服务已连接，等待目标主机上线…")
                }
            }
        case "hostPresence":
            guard !isHostRole else { return }
            if msg.hostOnline == true {
                if let kex = msg.hostKexPub { targetHostKexPub = kex }
                if activeSessionID == nil { beginClientSessionHandshake() }
            } else {
                onStatus?("目标主机已离线")
            }
        case "relay":
            handleRelay(msg)
        case "error":
            onStatus?("协调服务提示：\(msg.error ?? "未知错误")")
        default:
            break
        }
    }

    private func beginClientSessionHandshake() {
        guard let targetHostID, let targetHostSignPub, let targetHostKexPub else { return }
        do {
            let sid = UUID().uuidString.lowercased()
            let key = try identity.deriveSessionKey(peerKexSPKIB64: targetHostKexPub, sessionID: sid)
            activePeerID = targetHostID
            activePeerSignPub = targetHostSignPub
            activeSessionID = sid
            activeKey = key
            let req = CoordConnectRequest(
                protocolVersion: 1,
                session: sid,
                pairToken: clientPairToken,
                accessGrant: clientAccessGrant,
                userAgent: "KKRemote-Apple"
            )
            try sendEncrypted(kind: "connectRequest", payload: req, to: targetHostID, sessionID: sid, key: key)
            onStatus?("正在与主机进行端到端身份认证…")
        } catch {
            fail("发起加密握手失败：\(error.localizedDescription)")
        }
    }

    private func handleRelay(_ msg: CoordWireMessage) {
        guard let from = msg.from, let fromSignPub = msg.fromSignPub,
              let sessionID = msg.session, let kind = msg.kind,
              let nonce = msg.e2eNonce, let ciphertext = msg.ciphertext,
              let sig = msg.payloadSig else { return }

        if isHostRole && kind == "connectRequest" {
            guard let fromKexPub = msg.fromKexPub else { return }
            do {
                let key = try identity.deriveSessionKey(peerKexSPKIB64: fromKexPub, sessionID: sessionID)
                let req = try identity.openJSON(
                    CoordConnectRequest.self,
                    sessionID: sessionID,
                    from: from,
                    peerSignSPKIB64: fromSignPub,
                    kind: kind,
                    nonceB64: nonce,
                    ciphertextB64: ciphertext,
                    sigB64: sig,
                    key: key
                )
                guard req.protocolVersion == 1, req.session == sessionID else { return }
                var newGrant: String? = nil
                if identity.verifyAccessGrant(req.accessGrant, expectedClientID: from) {
                    newGrant = nil
                } else if identity.verifyPairToken(req.pairToken) {
                    newGrant = try identity.issueAccessGrant(forClientID: from)
                } else {
                    try sendEncrypted(kind: "reject", payload: CoordRejectPayload(error: "配对凭证无效或已过期"), to: from, sessionID: sessionID, key: key)
                    return
                }
                activePeerID = from
                activePeerSignPub = fromSignPub
                activeSessionID = sessionID
                activeKey = key
                pendingIssuedGrant = newGrant
                onClientAuthorized?(sessionID, stunServers)
            } catch {
                onStatus?("已拒绝无效连接请求")
            }
            return
        }

        guard from == activePeerID, sessionID == activeSessionID,
              let peerSignPub = activePeerSignPub, let key = activeKey else { return }

        do {
            switch kind {
            case "reject":
                let body = try identity.openJSON(CoordRejectPayload.self, sessionID: sessionID, from: from, peerSignSPKIB64: peerSignPub, kind: kind, nonceB64: nonce, ciphertextB64: ciphertext, sigB64: sig, key: key)
                fail("主机拒绝连接：\(body.error)")
            case "offer", "answer":
                let body = try identity.openJSON(CoordOfferAnswerPayload.self, sessionID: sessionID, from: from, peerSignSPKIB64: peerSignPub, kind: kind, nonceB64: nonce, ciphertextB64: ciphertext, sigB64: sig, key: key)
                let fingerprints = DeviceIdentity.extractDTLSFingerprints(from: body.sdp)
                guard !body.dtlsFingerprint.isEmpty, fingerprints.contains(body.dtlsFingerprint.uppercased()) else {
                    fail("远端 SDP DTLS 指纹绑定校验失败")
                    return
                }
                if let grant = body.accessGrant {
                    clientAccessGrant = grant
                    clientPairToken = nil
                    onGrantReceived?(grant)
                }
                var sigMsg = SignalMessage(type: kind, session: sessionID, sdp: body.sdp, videoFormat: body.videoFormat)
                sigMsg.windowProtocol = body.windowProtocol
                sigMsg.windowSession = body.windowSession
                sigMsg.windowLayout = body.windowLayout
                sigMsg.windowControl = body.windowControl
                sigMsg.windowKeyboard = body.windowKeyboard
                onSignal?(sigMsg)
            case "candidate":
                let body = try identity.openJSON(CoordCandidatePayload.self, sessionID: sessionID, from: from, peerSignSPKIB64: peerSignPub, kind: kind, nonceB64: nonce, ciphertextB64: ciphertext, sigB64: sig, key: key)
                onSignal?(SignalMessage(type: "candidate", session: sessionID, candidate: body.candidate, mid: body.mid, line: body.line))
            default:
                break
            }
        } catch {
            onStatus?("丢弃未通过认证的信令分片")
        }
    }

    func send(_ message: SignalMessage) {
        guard let peerID = activePeerID, let sessionID = activeSessionID,
              message.session == sessionID, let key = activeKey else { return }
        do {
            switch message.type {
            case "offer", "answer":
                guard let sdp = message.sdp,
                      let fp = DeviceIdentity.extractDTLSFingerprints(from: sdp).first else { return }
                let payload = CoordOfferAnswerPayload(
                    session: sessionID,
                    sdp: sdp,
                    dtlsFingerprint: fp,
                    videoFormat: message.videoFormat,
                    accessGrant: message.type == "offer" ? pendingIssuedGrant : nil,
                    windowProtocol: message.windowProtocol,
                    windowSession: message.windowSession,
                    windowLayout: message.windowLayout,
                    windowControl: message.windowControl,
                    windowKeyboard: message.windowKeyboard
                )
                pendingIssuedGrant = nil
                try sendEncrypted(kind: message.type, payload: payload, to: peerID, sessionID: sessionID, key: key)
            case "candidate":
                guard let candidate = message.candidate else { return }
                let payload = CoordCandidatePayload(session: sessionID, candidate: candidate, mid: message.mid, line: message.line)
                try sendEncrypted(kind: "candidate", payload: payload, to: peerID, sessionID: sessionID, key: key)
            default:
                break
            }
        } catch {
            onStatus?("发送加密信令失败：\(error.localizedDescription)")
        }
    }

    private func sendEncrypted<T: Encodable>(kind: String, payload: T, to peerID: String, sessionID: String, key: SymmetricKey) throws {
        let sealed = try identity.sealJSON(payload, sessionID: sessionID, to: peerID, kind: kind, key: key)
        let wire = CoordWireMessage(
            type: "relay",
            to: peerID,
            session: sessionID,
            kind: kind,
            e2eNonce: sealed.nonceB64,
            ciphertext: sealed.ciphertextB64,
            payloadSig: sealed.sigB64
        )
        sendRaw(wire)
    }

    private func sendRaw(_ wire: CoordWireMessage, on specificTask: URLSessionWebSocketTask? = nil) {
        guard let target = specificTask ?? task, let data = try? JSONEncoder().encode(wire),
              let text = String(data: data, encoding: .utf8) else { return }
        target.send(.string(text)) { _ in }
    }

    func stop() {
        stopped = true
        pingTimer?.invalidate(); pingTimer = nil
        task?.cancel(with: .normalClosure, reason: nil); task = nil
        session?.invalidateAndCancel(); session = nil
        activePeerID = nil; activeSessionID = nil; activeKey = nil
    }

    private func fail(_ message: String) {
        guard !stopped else { return }
        stop()
        DispatchQueue.main.async { self.onFailure?(message) }
    }
}
