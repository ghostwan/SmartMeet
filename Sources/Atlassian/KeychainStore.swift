import Foundation
import Security

/// Storage of the Atlassian API token in the keychain.
///
/// No environment variable: an app launched by LaunchServices does not
/// inherit the shell's environment, and a plaintext secret in a preferences
/// file is not acceptable.
public struct KeychainStore: Sendable {
    public let service: String

    public init(service: String = "com.smartmeet.atlassian") {
        self.service = service
    }

    public func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public func write(_ value: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)

        guard !value.isEmpty else { return true }
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    /// Picks up the token from the environment on first launch, if it's there.
    /// Migration convenience for anyone who already has it in their shell.
    public func seedFromEnvironmentIfNeeded(account: String, variable: String) {
        guard read(account: account) == nil,
              let value = ProcessInfo.processInfo.environment[variable],
              !value.isEmpty
        else { return }
        write(value, account: account)
    }
}
