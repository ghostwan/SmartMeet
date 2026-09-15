import Foundation

/// Weather icon chosen by a member to illustrate their sprint.
///
/// Controlled vocabulary: the model produces free-form text, which is mapped
/// back here to a finite set so it can be displayed consistently. Parsing
/// accepts French, English and emoji, because models vary.
public enum WeatherIcon: String, Codable, Sendable, CaseIterable, Identifiable {
    case sun
    case partlySunny
    case cloudy
    case rain
    case storm
    case fog
    case snow
    case rainbow
    case wind
    case heatwave

    public var id: String { rawValue }

    public var emoji: String {
        switch self {
        case .sun: "☀️"
        case .partlySunny: "🌤️"
        case .cloudy: "☁️"
        case .rain: "🌧️"
        case .storm: "⛈️"
        case .fog: "🌫️"
        case .snow: "❄️"
        case .rainbow: "🌈"
        case .wind: "💨"
        case .heatwave: "🔥"
        }
    }

    public var symbol: String {
        switch self {
        case .sun: "sun.max.fill"
        case .partlySunny: "cloud.sun.fill"
        case .cloudy: "cloud.fill"
        case .rain: "cloud.rain.fill"
        case .storm: "cloud.bolt.rain.fill"
        case .fog: "cloud.fog.fill"
        case .snow: "snowflake"
        case .rainbow: "rainbow"
        case .wind: "wind"
        case .heatwave: "flame.fill"
        }
    }

    public func label(in language: SummaryLanguage) -> String {
        switch self {
        case .sun: language.pick(fr: "Soleil", en: "Sunny")
        case .partlySunny: language.pick(fr: "Éclaircie", en: "Partly sunny")
        case .cloudy: language.pick(fr: "Nuageux", en: "Cloudy")
        case .rain: language.pick(fr: "Pluie", en: "Rain")
        case .storm: language.pick(fr: "Orage", en: "Storm")
        case .fog: language.pick(fr: "Brouillard", en: "Fog")
        case .snow: language.pick(fr: "Neige", en: "Snow")
        case .rainbow: language.pick(fr: "Arc-en-ciel", en: "Rainbow")
        case .wind: language.pick(fr: "Vent", en: "Wind")
        case .heatwave: language.pick(fr: "Canicule", en: "Heatwave")
        }
    }

    /// Vocabulary offered to the model in the prompt.
    static var promptVocabulary: String {
        allCases.map(\.rawValue).joined(separator: ", ")
    }

    /// Tolerant recognition: identifier, French or English label, emoji.
    public static func parse(_ raw: String) -> WeatherIcon? {
        let normalised = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")

        guard !normalised.isEmpty else { return nil }

        for icon in allCases {
            let candidates = [
                icon.rawValue,
                icon.emoji,
                icon.label(in: .french),
                icon.label(in: .english),
            ].map {
                $0.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
                    .replacingOccurrences(of: " ", with: "")
                    .replacingOccurrences(of: "-", with: "")
            }
            if candidates.contains(normalised) { return icon }
        }

        // Common model variants.
        let aliases: [String: WeatherIcon] = [
            "soleil": .sun, "ensoleille": .sun, "sunny": .sun, "clear": .sun,
            "partlycloudy": .partlySunny, "eclaircies": .partlySunny,
            "nuage": .cloudy, "nuages": .cloudy, "couvert": .cloudy, "overcast": .cloudy,
            "pluvieux": .rain, "rainy": .rain, "averse": .rain,
            "orageux": .storm, "tempete": .storm, "thunderstorm": .storm, "stormy": .storm,
            "brume": .fog, "foggy": .fog, "misty": .fog,
            "neigeux": .snow, "snowy": .snow,
            "venteux": .wind, "windy": .wind,
            "canicular": .heatwave, "chaleur": .heatwave, "heat": .heatwave,
        ]
        return aliases[normalised]
    }
}
