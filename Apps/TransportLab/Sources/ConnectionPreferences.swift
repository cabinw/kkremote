#if os(iOS)
import Foundation
import Combine
import Security

struct ConnectionProfile: Codable, Equatable {
    var host = ""
    var pairingCode = ""
    var port = "45990"
    var mediaPort = "45991"
    var route = MediaRoute.ponteUDP
    var transport = BridgeTransportKind.socket
    var network = "Surge Ponte"

    var validationError: String? {
        if host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请填写主机地址" }
        if pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请填写配对码" }
        if UInt16(port).map({ $0 > 0 }) != true { return "信令端口应为 1–65535" }
        if UInt16(mediaPort).map({ $0 > 0 }) != true { return "媒体端口应为 1–65535" }
        return nil
    }

    func apply(to model: LabModel) {
        model.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        model.pairingKey = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        model.port = port; model.mediaPort = mediaPort
        model.mediaRoute = route; model.bridgeTransport = transport; model.networkLabel = network
    }
}

final class ConnectionPreferences: ObservableObject {
    @Published var profile: ConnectionProfile
    @Published private(set) var saveError: String?
    private let defaults: UserDefaults
    private static let storageKey = "viewer.connection.v1"
    private static let service = "com.cabinw.kkremote.lab.connection"
    private static let account = "pairing-code"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var initial = Self.bundledDefaults()
        if let data = defaults.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode(ConnectionProfile.self, from: data) {
            initial = saved
            initial.pairingCode = Self.readCode() ?? ""
        }
        profile = initial
    }

    static func bundledDefaults() -> ConnectionProfile {
        var profile = ConnectionProfile()
        // Internal builds inject defaults through the ignored local xcconfig.
        // Public builds without that config start with empty credentials.
        profile.host = Bundle.main.object(forInfoDictionaryKey: "KKRemoteDefaultHost") as? String ?? ""
        profile.pairingCode = Bundle.main.object(forInfoDictionaryKey: "KKRemoteDefaultPairingCode") as? String ?? ""
        return profile
    }

    @discardableResult func save() -> Bool {
        if let message = profile.validationError { saveError = message; return false }
        let code = profile.pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: Self.service,
                                   kSecAttrAccount as String: Self.account]
        let update = [kSecValueData as String: Data(code.utf8)]
        var result = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if result == errSecItemNotFound {
            var insert = query.merging(update) { _, new in new }
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            result = SecItemAdd(insert as CFDictionary, nil)
        }
        guard result == errSecSuccess else {
            saveError = "配对码保存失败（\(result)），请重试"; return false
        }
        var stored = profile
        stored.host = stored.host.trimmingCharacters(in: .whitespacesAndNewlines)
        stored.pairingCode = "" // Never persist credentials in UserDefaults or test reports.
        guard let data = try? JSONEncoder().encode(stored) else { saveError = "连接设置保存失败"; return false }
        defaults.set(data, forKey: Self.storageKey)
        saveError = nil
        return true
    }

    func restoreDefaults() { profile = Self.bundledDefaults(); save() }

    private static func readCode() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: account,
                                   kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
#endif
