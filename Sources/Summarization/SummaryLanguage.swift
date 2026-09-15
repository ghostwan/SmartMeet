import Foundation

/// Language the minutes are written in, independent of the language spoken in
/// the meeting.
///
/// A team may speak French and need to deliver minutes in English to their
/// leadership. The choice is made before recording, because it drives the
/// prompt, the section labels and the title format.
public enum SummaryLanguage: String, Codable, Sendable, CaseIterable, Identifiable {
    case english = "en"
    case mandarin = "zh"
    case hindi = "hi"
    case spanish = "es"
    case french = "fr"
    case arabic = "ar"
    case bengali = "bn"
    case portuguese = "pt"
    case russian = "ru"
    case urdu = "ur"
    case indonesian = "id"
    case german = "de"
    case japanese = "ja"
    case italian = "it"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .english: "English"
        case .mandarin: "中文（普通话）"
        case .hindi: "हिन्दी"
        case .spanish: "Español"
        case .french: "Français"
        case .arabic: "العربية الفصحى"
        case .bengali: "বাংলা"
        case .portuguese: "Português"
        case .russian: "Русский"
        case .urdu: "اردو"
        case .indonesian: "Bahasa Indonesia"
        case .german: "Deutsch"
        case .japanese: "日本語"
        case .italian: "Italiano"
        }
    }

    public var flag: String {
        switch self {
        case .english: "🇬🇧"
        case .mandarin: "🇨🇳"
        case .hindi: "🇮🇳"
        case .spanish: "🇪🇸"
        case .french: "🇫🇷"
        case .arabic: "🌐"
        case .bengali: "🇧🇩"
        case .portuguese: "🇵🇹"
        case .russian: "🇷🇺"
        case .urdu: "🇵🇰"
        case .indonesian: "🇮🇩"
        case .german: "🇩🇪"
        case .japanese: "🇯🇵"
        case .italian: "🇮🇹"
        }
    }

    public var locale: Locale {
        switch self {
        case .english: Locale(identifier: "en_GB")
        case .mandarin: Locale(identifier: "zh_CN")
        case .hindi: Locale(identifier: "hi_IN")
        case .spanish: Locale(identifier: "es_ES")
        case .french: Locale(identifier: "fr_FR")
        case .arabic: Locale(identifier: "ar_001")
        case .bengali: Locale(identifier: "bn_BD")
        case .portuguese: Locale(identifier: "pt_PT")
        case .russian: Locale(identifier: "ru_RU")
        case .urdu: Locale(identifier: "ur_PK")
        case .indonesian: Locale(identifier: "id_ID")
        case .german: Locale(identifier: "de_DE")
        case .japanese: Locale(identifier: "ja_JP")
        case .italian: Locale(identifier: "it_IT")
        }
    }

    /// Unambiguous language name used in model instructions. Endonyms are
    /// useful in the UI, while English names are more consistently understood
    /// by every provider's control prompt.
    public var promptName: String {
        switch self {
        case .english: "English"
        case .mandarin: "Simplified Mandarin Chinese"
        case .hindi: "Hindi"
        case .spanish: "Spanish"
        case .french: "French"
        case .arabic: "Modern Standard Arabic"
        case .bengali: "Bengali"
        case .portuguese: "Portuguese"
        case .russian: "Russian"
        case .urdu: "Urdu"
        case .indonesian: "Indonesian"
        case .german: "German"
        case .japanese: "Japanese"
        case .italian: "Italian"
        }
    }

    /// Picks between two authoring variants.
    public func pick(fr: String, en: String) -> String {
        self == .french ? fr : en
    }
}
