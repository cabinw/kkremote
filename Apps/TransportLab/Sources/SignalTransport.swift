import Foundation
import Network
import Security

struct SignalMessage: Codable {
    var type: String
    var session: String
    var sdp: String? = nil
    var candidate: String? = nil
    var mid: String? = nil
    var line: Int32? = nil
    var bridgeVersion: Int? = nil
    var mediaPort: UInt16? = nil
    var mediaKey: String? = nil
}

/// TLS-PSK is only the lab's authenticated signaling transport.
/// Audio/video use WebRTC DTLS-SRTP, never this reliable byte stream.
final class SignalTransport {
    static let defaultPort: UInt16 = 45990
    static let maximumMessage = 256 * 1024
    private let queue = DispatchQueue(label: "kkremote.signaling")
    private var listener: NWListener?
    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var pendingBytes = 0
    var onReady: (() -> Void)?
    var onMessage: ((SignalMessage) -> Void)?
    var onStatus: ((String) -> Void)?
    var onFailure: ((String) -> Void)?

    static func newPairingKey() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw LabError.message("无法生成配对密钥")
        }
        return Data(bytes).base64EncodedString()
    }

    private static func parameters(key: String) throws -> NWParameters {
        guard let secret = Data(base64Encoded: key.trimmingCharacters(in: .whitespacesAndNewlines)), secret.count == 32 else {
            throw LabError.message("配对码应为主机生成的完整 32 字节密钥")
        }
        let tls = NWProtocolTLS.Options()
        // Apple Network.framework's external PSK support currently requires TLS 1.2.
        // This pins an authenticated AES-GCM suite, with no plaintext fallback or trust bypass.
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, tls_ciphersuite_t(rawValue: 0x00A8)!)
        let secretData = secret.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("kkremote-lab-v1".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, secretData as __DispatchData, identity as __DispatchData)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        return NWParameters(tls: tls, tcp: tcp)
    }

    func listen(key: String, port: UInt16) throws {
        let listener = try NWListener(using: Self.parameters(key: key), on: NWEndpoint.Port(rawValue: port)!)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.status("等待连接 · TLS 端口 \(port)")
            case .failed(let error): self?.fail("监听失败：\(error.localizedDescription)")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            // The lab handles one viewer; an additional connection cannot displace it.
            guard self.connection == nil else { connection.cancel(); return }
            self.attach(connection)
        }
        listener.start(queue: queue)
    }

    func connect(host: String, key: String, port: UInt16) throws {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !host.contains("://"), port > 0 else {
            throw LabError.message("请填写主机名称或 IP，以及有效端口")
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: try Self.parameters(key: key))
        queue.async { self.attach(connection) }
    }

    private func attach(_ newConnection: NWConnection) {
        connection = newConnection
        receiveBuffer.removeAll(keepingCapacity: true)
        pendingBytes = 0
        newConnection.stateUpdateHandler = { [weak self, weak newConnection] state in
            guard let self, let newConnection, self.connection === newConnection else { return }
            switch state {
            case .ready:
                self.status("配对信令已连接；正在建立媒体")
                DispatchQueue.main.async { self.onReady?() }
                self.receive(newConnection)
            case .failed(let error): self.fail("信令连接失败：\(error.localizedDescription)")
            case .waiting(let error): self.status("等待网络：\(error.localizedDescription)")
            default: break
            }
        }
        newConnection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 15) { [weak self, weak newConnection] in
            guard let self, let newConnection, self.connection === newConnection else { return }
            if case .ready = newConnection.state { return }
            self.fail("信令握手超时：检查端点、网络与配对码")
        }
    }

    func send(_ message: SignalMessage) {
        queue.async { [self] in
            guard let connection = self.connection else { return }
            do {
                let payload = try JSONEncoder().encode(message)
                guard payload.count <= Self.maximumMessage, self.pendingBytes + payload.count + 4 <= 1024 * 1024 else {
                    self.fail("信令队列超出上限"); return
                }
                var size = UInt32(payload.count).bigEndian
                var frame = withUnsafeBytes(of: &size) { Data($0) }
                frame.append(payload)
                let count = frame.count
                self.pendingBytes += count
                connection.send(content: frame, completion: .contentProcessed { [weak self, weak connection] error in
                    guard let self, let connection, self.connection === connection else { return }
                    self.pendingBytes -= count
                    if let error { self.fail("信令发送失败：\(error.localizedDescription)") }
                })
            } catch { self.fail("信令序列化失败") }
        }
    }

    private func receive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self, weak connection] data, _, complete, error in
            guard let self, let connection, self.connection === connection else { return }
            if let data {
                self.receiveBuffer.append(data)
                while self.receiveBuffer.count >= 4 {
                    let length = self.receiveBuffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                    guard length > 0, length <= Self.maximumMessage else { self.fail("无效信令帧长度"); return }
                    let total = 4 + Int(length)
                    guard self.receiveBuffer.count >= total else { break }
                    let payload = self.receiveBuffer.subdata(in: 4..<total)
                    self.receiveBuffer = Data(self.receiveBuffer.dropFirst(total))
                    do {
                        let message = try JSONDecoder().decode(SignalMessage.self, from: payload)
                        DispatchQueue.main.async { self.onMessage?(message) }
                    } catch { self.fail("无效信令消息"); return }
                }
            }
            if let error { self.fail("信令接收失败：\(error.localizedDescription)"); return }
            if complete { self.fail("对端已断开信令"); return }
            self.receive(connection)
        }
    }

    func stop() {
        queue.async {
            self.listener?.cancel(); self.listener = nil
            self.connection?.cancel(); self.connection = nil
            self.receiveBuffer.removeAll(); self.pendingBytes = 0
        }
    }

    private func status(_ value: String) { DispatchQueue.main.async { self.onStatus?(value) } }
    private func fail(_ value: String) {
        connection?.cancel(); connection = nil; receiveBuffer.removeAll(); pendingBytes = 0
        DispatchQueue.main.async { self.onFailure?(value) }
    }
}

enum LabError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
