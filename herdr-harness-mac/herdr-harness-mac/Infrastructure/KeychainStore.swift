import Foundation
import Security

enum KeychainStore {
    private static let service = "dev.ronnierocha.herdr-harness"

    static func value(for account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain as String: true,
        ]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data,
           let value = String(data: data, encoding: .utf8),
           !value.isEmpty {
            UserDefaults.standard.removeObject(forKey: fallbackKey(for: account))
            return value
        }

        guard let fallbackValue = UserDefaults.standard.string(forKey: fallbackKey(for: account)),
              !fallbackValue.isEmpty
        else { return "" }

        if writeToKeychain(fallbackValue, for: account) == errSecSuccess {
            UserDefaults.standard.removeObject(forKey: fallbackKey(for: account))
        }
        return fallbackValue
    }

    @discardableResult
    static func set(_ value: String, for account: String) -> OSStatus {
        let status = writeToKeychain(value, for: account)
        #if DEBUG
        if status != errSecSuccess {
            print("KeychainStore: write failed with status \(status)")
        }
        #endif

        if value.isEmpty || status == errSecSuccess {
            UserDefaults.standard.removeObject(forKey: fallbackKey(for: account))
        } else {
            UserDefaults.standard.set(value, forKey: fallbackKey(for: account))
        }
        return status
    }

    static func removeValue(for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: fallbackKey(for: account))
    }

    private static func fallbackKey(for account: String) -> String {
        "herdr.keychainFallback.\(account)"
    }

    @discardableResult
    private static func writeToKeychain(_ value: String, for account: String) -> OSStatus {
        let key: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        let data = Data(value.utf8)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(key as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var insert = key
            insert[kSecValueData as String] = data
            return SecItemAdd(insert as CFDictionary, nil)
        }
        return updateStatus
    }
}
