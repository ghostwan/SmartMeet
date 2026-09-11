import Foundation

/// Langue de rédaction du compte rendu, indépendante de la langue parlée en réunion.
///
/// Une équipe peut parler français et devoir livrer un compte rendu en anglais à sa
/// direction. Le choix se fait avant l'enregistrement, parce qu'il conditionne le
/// prompt, les libellés de sections et le format du titre.
public enum SummaryLanguage: String, Codable, Sendable, CaseIterable, Identifiable {
    case french = "fr"
    case english = "en"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .french: "Français"
        case .english: "English"
        }
    }

    public var flag: String {
        switch self {
        case .french: "🇫🇷"
        case .english: "🇬🇧"
        }
    }

    public var locale: Locale {
        switch self {
        case .french: Locale(identifier: "fr_FR")
        case .english: Locale(identifier: "en_GB")
        }
    }

    /// Choisit entre deux variantes rédactionnelles.
    public func pick(fr: String, en: String) -> String {
        switch self {
        case .french: fr
        case .english: en
        }
    }
}
