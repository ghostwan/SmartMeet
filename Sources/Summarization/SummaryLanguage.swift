import Foundation

/// Language the minutes are written in, independent of the language spoken in
/// the meeting.
///
/// A team may speak French and need to deliver minutes in English to their
/// leadership. The choice is made before recording, because it drives the
/// prompt, the section labels and the title format.
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

    /// Picks between two authoring variants.
    public func pick(fr: String, en: String) -> String {
        switch self {
        case .french: fr
        case .english: en
        }
    }
}
