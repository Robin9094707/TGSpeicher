import Foundation
import Security

enum KeychainStore {
    private static let service = "eu.simplexsmp.tgspeicher"

    static func saveRecoveryAnchor(_ anchor: RecoveryAnchor) -> Bool {
        guard let data = try? JSONEncoder().encode(anchor), data.count < 8_000 else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service + ".recovery.v3",
            kSecAttrAccount as String: String(anchor.accountID),
            kSecAttrSynchronizable as String: true
        ]
        let attributes: [String: Any] = [kSecValueData as String: data,
                                        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var insert = query
        attributes.forEach { insert[$0.key] = $0.value }
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    static func recoveryAnchor(accountID: Int64) -> RecoveryAnchor? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service + ".recovery.v3",
            kSecAttrAccount as String: String(accountID),
            kSecAttrSynchronizable as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let anchor = try? JSONDecoder().decode(RecoveryAnchor.self, from: data),
              anchor.accountID == accountID else { return nil }
        return anchor
    }

    static func set(_ value: String, for key: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess { return }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(insert as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func databaseKey() -> String {
        if let existing = get("tdlib.database-key") { return existing }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let value = Data(bytes).base64EncodedString()
        set(value, for: "tdlib.database-key")
        return value
    }
}
