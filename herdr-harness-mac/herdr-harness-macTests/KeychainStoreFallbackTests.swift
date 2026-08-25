import Foundation
import Security
import Testing
@testable import herdr_harness_mac

@Suite("Keychain store fallback")
struct KeychainStoreFallbackTests {
    @Test("Uses UserDefaults only when the Data Protection Keychain is unavailable")
    func persistsAndClearsFallbackValue() {
        let account = "test-token"
        let fallbackKey = "herdr.keychainFallback.\(account)"
        UserDefaults.standard.removeObject(forKey: fallbackKey)
        defer {
            UserDefaults.standard.removeObject(forKey: fallbackKey)
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "dev.ronnierocha.herdr-harness",
                kSecAttrAccount as String: account,
                kSecUseDataProtectionKeychain as String: true,
            ]
            SecItemDelete(query as CFDictionary)
        }

        let status = KeychainStore.set("some-value", for: account)

        if status == errSecSuccess {
            #expect(UserDefaults.standard.object(forKey: fallbackKey) == nil)
        } else {
            #expect(UserDefaults.standard.string(forKey: fallbackKey) == "some-value")
        }
        #expect(KeychainStore.value(for: account) == "some-value")

        KeychainStore.set("", for: account)

        #expect(UserDefaults.standard.object(forKey: fallbackKey) == nil)
    }
}
