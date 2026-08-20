import Foundation
import Security
import Testing
@testable import herdr_harness_mac

@Suite("Keychain store fallback")
struct KeychainStoreFallbackTests {
    @Test("Persists token values to the UserDefaults fallback")
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

        KeychainStore.set("some-value", for: account)

        #expect(UserDefaults.standard.string(forKey: fallbackKey) == "some-value")
        #expect(KeychainStore.value(for: account) == "some-value")

        KeychainStore.set("", for: account)

        #expect(UserDefaults.standard.object(forKey: fallbackKey) == nil)
    }
}
