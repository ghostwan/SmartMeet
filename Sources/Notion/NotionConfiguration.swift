import Foundation

/// Réglages de publication Notion. Le jeton d'intégration vit dans le trousseau,
/// jamais ici.
public struct NotionConfiguration: Codable, Sendable, Equatable {
    /// Page Notion sous laquelle créer les comptes rendus.
    public var parentPageID: String
    /// Libellé lisible, affiché dans les réglages (titre de la page collée).
    public var parentPageTitle: String

    public init(parentPageID: String = "", parentPageTitle: String = "") {
        self.parentPageID = parentPageID
        self.parentPageTitle = parentPageTitle
    }

    public var isConfigured: Bool { !parentPageID.isEmpty }

    /// Accepte un identifiant nu (avec ou sans tirets) ou une URL Notion copiée
    /// depuis le navigateur.
    ///
    /// Les URL Notion terminent par un identifiant de 32 caractères hexadécimaux,
    /// avec ou sans tirets : `.../Titre-de-la-page-2ac1f5c4a1b34e6c9a9d8f6f6f6f6f6f`.
    /// On prend les 32 derniers caractères hexadécimaux du dernier segment de
    /// chemin : plus simple et plus robuste qu'un découpage sur les tirets, qui
    /// casserait un identifiant déjà tiré (format UUID standard).
    public static func extractPageID(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate: String
        if let url = URL(string: trimmed), let last = url.path.split(separator: "/").last {
            candidate = String(last)
        } else {
            candidate = trimmed
        }

        let hexOnly = candidate.filter(\.isHexDigit)
        guard hexOnly.count >= 32 else { return nil }
        return format(String(hexOnly.suffix(32)))
    }

    /// Notion accepte l'identifiant avec ou sans tirets ; on le formate en UUID
    /// standard, plus lisible dans les réglages.
    private static func format(_ hex: String) -> String {
        let chars = Array(hex)
        let groups = [8, 4, 4, 4, 12]
        var index = 0
        var parts: [String] = []
        for length in groups {
            parts.append(String(chars[index..<(index + length)]))
            index += length
        }
        return parts.joined(separator: "-")
    }
}
