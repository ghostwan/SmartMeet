import Foundation
import Security

/// Stockage du jeton d'API Atlassian dans le trousseau.
///
/// Pas de variable d'environnement : une app lancée par LaunchServices n'hérite pas
/// de l'environnement du shell, et un secret en clair dans un fichier de préférences
/// n'est pas acceptable.
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

    /// Reprend le jeton depuis l'environnement au premier lancement, s'il y est.
    /// Confort de migration pour qui l'a déjà dans son shell.
    public func seedFromEnvironmentIfNeeded(account: String, variable: String) {
        guard read(account: account) == nil,
              let value = ProcessInfo.processInfo.environment[variable],
              !value.isEmpty
        else { return }
        write(value, account: account)
    }
}
