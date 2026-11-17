import Foundation
import CryptoKit
import Security

extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLOrStandard value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var norm = trimmed
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = norm.count % 4
        if remainder > 0 { norm += String(repeating: "=", count: 4 - remainder) }
        self.init(base64Encoded: norm)
    }
}

struct StoredDeviceKeys: Codable {
    let signPrivateRaw: String
    let kexPrivateRaw: String
}

/// Long-term P-256 signing identity + session/device ECDH key agreement.
/// Interoperates directly with Go x509 SPKI + WebCrypto SubtleCrypto P-256 + iOS/Android hardware curves.
final class DeviceIdentity {
    let signKey: P256.Signing.PrivateKey
    let kexKey: P256.KeyAgreement.PrivateKey
    let deviceID: String
    let signPubB64: String
    let kexPubB64: String
    private var activePairToken: String

    init(signKey: P256.Signing.PrivateKey = P256.Signing.PrivateKey(),
         kexKey: P256.KeyAgreement.PrivateKey = P256.KeyAgreement.PrivateKey()) {
        self.signKey = signKey
        self.kexKey = kexKey
        let signDER = signKey.publicKey.derRepresentation
        let kexDER = kexKey.publicKey.derRepresentation
        self.signPubB64 = signDER.base64EncodedString()
        self.kexPubB64 = kexDER.base64EncodedString()
        self.deviceID = SHA256.hash(data: signDER).prefix(16).map { String(format: "%02x", $0) }.joined()
        self.activePairToken = Self.randomToken(bytes: 18)
    }

    static func randomToken(bytes count: Int = 16) -> String {
        var buf = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, buf.count, &buf)
        return Data(buf).base64URLEncoded
    }

    var currentPairToken: String { activePairToken }

    @discardableResult
    func rotatePairToken() -> String {
        activePairToken = Self.randomToken(bytes: 18)
        return activePairToken
    }

    func verifyPairToken(_ candidate: String?) -> Bool {
        guard let candidate, !candidate.isEmpty else { return false }
        let lhs = Array(candidate.utf8)
        let rhs = Array(activePairToken.utf8)
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for i in lhs.indices { diff |= lhs[i] ^ rhs[i] }
        return diff == 0
    }

    func issueAccessGrant(forClientID clientID: String, ttlSeconds: Int64 = 30 * 86400) throws -> String {
        let exp = Int64(Date().timeIntervalSince1970) + ttlSeconds
        let body = "kkremote-access-grant-v1|\(deviceID)|\(clientID)|\(exp)"
        let sig = try signKey.signature(for: Data(body.utf8)).rawRepresentation.base64URLEncoded
        return "v1.\(deviceID).\(clientID).\(exp).\(sig)"
    }

    func verifyAccessGrant(_ token: String?, expectedClientID: String) -> Bool {
        guard let token else { return false }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0] == "v1",
              String(parts[1]) == deviceID,
              String(parts[2]) == expectedClientID,
              let exp = Int64(parts[3]), exp > Int64(Date().timeIntervalSince1970),
              let sigRaw = Data(base64URLOrStandard: String(parts[4])),
              let sig = try? P256.Signing.ECDSASignature(rawRepresentation: sigRaw) else {
            return false
        }
        let body = "kkremote-access-grant-v1|\(deviceID)|\(expectedClientID)|\(exp)"
        return signKey.publicKey.isValidSignature(sig, for: Data(body.utf8))
    }

    /// Pairing link places all trust material inside the URL #fragment so HTTP servers/logs never see it.
    func makePairingURL(coordBaseURL: String, hostName: String, autoSelectApp: String? = nil) -> String {
        let base = coordBaseURL
            .replacingOccurrences(of: "wss://", with: "https://")
            .replacingOccurrences(of: "ws://", with: "http://")
            .replacingOccurrences(of: "/v1/ws", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let pubURL = signKey.publicKey.derRepresentation.base64URLEncoded
        let kexURL = kexKey.publicKey.derRepresentation.base64URLEncoded
        var items = [
            "host=\(deviceID)",
            "pub=\(pubURL)",
            "kex=\(kexURL)",
            "pair=\(activePairToken)",
            "name=\(hostName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Mac")"
        ]
        if let autoSelectApp, !autoSelectApp.isEmpty,
           let encoded = autoSelectApp.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            items.append("autoselect=\(encoded)")
        }
        return "\(base)/#\(items.joined(separator: "&"))"
    }

    func signP1363(_ message: String) throws -> String {
        let sig = try signKey.signature(for: Data(message.utf8))
        return sig.rawRepresentation.base64EncodedString()
    }

    static func verifyP1363(pubSPKIB64: String, message: String, sigB64: String) -> Bool {
        guard let pubData = Data(base64URLOrStandard: pubSPKIB64),
              let sigData = Data(base64URLOrStandard: sigB64),
              sigData.count == 64,
              let pub = try? P256.Signing.PublicKey(derRepresentation: pubData),
              let sig = try? P256.Signing.ECDSASignature(rawRepresentation: sigData) else {
            return false
        }
        return pub.isValidSignature(sig, for: Data(message.utf8))
    }

    func deriveSessionKey(peerKexSPKIB64: String, sessionID: String) throws -> SymmetricKey {
        guard let peerData = Data(base64URLOrStandard: peerKexSPKIB64) else {
            throw LabError.message("对端密钥格式无效")
        }
        let peerPub = try P256.KeyAgreement.PublicKey(derRepresentation: peerData)
        let shared = try kexKey.sharedSecretFromKeyAgreement(with: peerPub)
        return shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(sessionID.utf8),
            sharedInfo: Data("kkremote-coord-e2ee-v1".utf8),
            outputByteCount: 32
        )
    }

    func sealJSON<T: Encodable>(_ payload: T, sessionID: String, to peerID: String, kind: String, key: SymmetricKey) throws -> (nonceB64: String, ciphertextB64: String, sigB64: String) {
        let plaintext = try JSONEncoder().encode(payload)
        var nonceBytes = [UInt8](repeating: 0, count: 12)
        guard SecRandomCopyBytes(kSecRandomDefault, 12, &nonceBytes) == errSecSuccess else {
            throw LabError.message("无法生成加密随机数")
        }
        let nonceData = Data(nonceBytes)
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let aad = Data("kkremote-e2ee-v1|\(sessionID)|\(deviceID)|\(peerID)|\(kind)".utf8)
        let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        var combinedCT = Data(box.ciphertext)
        combinedCT.append(box.tag)
        let nonceB64 = nonceData.base64EncodedString()
        let ciphertextB64 = combinedCT.base64EncodedString()
        let sigInput = "kkremote-e2ee-sig-v1|\(sessionID)|\(deviceID)|\(peerID)|\(kind)|\(nonceB64)|\(ciphertextB64)"
        let sigB64 = try signP1363(sigInput)
        return (nonceB64, ciphertextB64, sigB64)
    }

    func openJSON<T: Decodable>(_ type: T.Type, sessionID: String, from peerID: String, peerSignSPKIB64: String, kind: String, nonceB64: String, ciphertextB64: String, sigB64: String, key: SymmetricKey) throws -> T {
        let sigInput = "kkremote-e2ee-sig-v1|\(sessionID)|\(peerID)|\(deviceID)|\(kind)|\(nonceB64)|\(ciphertextB64)"
        guard Self.verifyP1363(pubSPKIB64: peerSignSPKIB64, message: sigInput, sigB64: sigB64) else {
            throw LabError.message("对端信令签名校验失败")
        }
        guard let nonceData = Data(base64URLOrStandard: nonceB64), nonceData.count == 12,
              let ctData = Data(base64URLOrStandard: ciphertextB64), ctData.count >= 16 else {
            throw LabError.message("加密信令负载格式无效")
        }
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let aad = Data("kkremote-e2ee-v1|\(sessionID)|\(peerID)|\(deviceID)|\(kind)".utf8)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ctData.dropLast(16), tag: ctData.suffix(16))
        let plaintext = try AES.GCM.open(box, using: key, authenticating: aad)
        return try JSONDecoder().decode(T.self, from: plaintext)
    }

    static func loadOrCreateDefault() throws -> DeviceIdentity {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("KKRemote", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let targetPath = base.appendingPathComponent("host-identity-v1.json").path
        if !FileManager.default.fileExists(atPath: targetPath) {
            let legacyPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Containers/com.cabinw.kkremote.lab.mac/Data/Library/Application Support/KKRemote/host-identity-v1.json").path
            if let migrated = try? loadOrCreate(atFile: legacyPath) {
                let stored = StoredDeviceKeys(
                    signPrivateRaw: migrated.signKey.rawRepresentation.base64EncodedString(),
                    kexPrivateRaw: migrated.kexKey.rawRepresentation.base64EncodedString()
                )
                if let encoded = try? JSONEncoder().encode(stored) {
                    let fd = open(targetPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
                    if fd >= 0 {
                        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                        try? handle.write(contentsOf: encoded)
                        try? handle.close()
                    }
                }
                return migrated
            }
        }
        return try loadOrCreate(atFile: targetPath)
    }

    static func loadOrCreate(atFile path: String) throws -> DeviceIdentity {
        if FileManager.default.fileExists(atPath: path) {
            let input = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard input >= 0 else { throw LabError.message("无法读取设备身份文件") }
            let handle = FileHandle(fileDescriptor: input, closeOnDealloc: true)
            defer { try? handle.close() }
            var st = stat()
            guard fstat(input, &st) == 0, st.st_mode & S_IFMT == S_IFREG,
                  st.st_uid == geteuid(), st.st_mode & 0o077 == 0,
                  st.st_size > 0, st.st_size <= 4096 else {
                throw LabError.message("设备身份文件必须为当前用户 0600 私有普通文件")
            }
            let data = try handle.read(upToCount: 4096) ?? Data()
            let stored = try JSONDecoder().decode(StoredDeviceKeys.self, from: data)
            guard let signRaw = Data(base64Encoded: stored.signPrivateRaw),
                  let kexRaw = Data(base64Encoded: stored.kexPrivateRaw) else {
                throw LabError.message("设备身份密钥解码失败")
            }
            return DeviceIdentity(
                signKey: try P256.Signing.PrivateKey(rawRepresentation: signRaw),
                kexKey: try P256.KeyAgreement.PrivateKey(rawRepresentation: kexRaw)
            )
        }
        let identity = DeviceIdentity()
        let stored = StoredDeviceKeys(
            signPrivateRaw: identity.signKey.rawRepresentation.base64EncodedString(),
            kexPrivateRaw: identity.kexKey.rawRepresentation.base64EncodedString()
        )
        let encoded = try JSONEncoder().encode(stored)
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw LabError.message("无法安全创建设备身份文件") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: encoded)
        try handle.close()
        return identity
    }

    static func extractDTLSFingerprints(from sdp: String) -> [String] {
        sdp.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("a=fingerprint:") }
            .map { String($0.dropFirst("a=fingerprint:".count)).trimmingCharacters(in: .whitespaces).uppercased() }
    }
}
