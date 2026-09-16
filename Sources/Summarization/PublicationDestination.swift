import Foundation

/// Where to publish the minutes, relative to the chosen Confluence space.
public enum ParentPageReference: Codable, Sendable, Equatable, Hashable {
    /// The space's home page.
    case spaceHome
    /// A fixed page, identified by its Confluence ID.
    case page(id: String)
    /// The current sprint page, set once at the start of the sprint in settings.
    /// Every meeting attached to the sprint follows it automatically.
    case sprintPage

    public var isSprintPage: Bool {
        if case .sprintPage = self { return true }
        return false
    }

    public var fixedPageID: String? {
        if case .page(let id) = self { return id }
        return nil
    }
}

/// Service-neutral publication location. Each service interprets a specific
/// page ID in its own API; `.profileDefault` uses that profile's configured
/// parent (or the service's safe personal/private fallback).
public enum PublicationDestination: Codable, Sendable, Equatable, Hashable {
    case profileDefault
    case page(id: String)

    public var pageID: String? {
        if case .page(let id) = self { return id }
        return nil
    }
}

/// Composition of the published page's title.
///
/// The title produced by the model is too variable to serve as a naming
/// convention: two consecutive dailys come out with different labels, which
/// makes the Confluence tree hard to read. The format takes over control of it.
public struct TitleFormat: Sendable {
    /// Recognized tokens, documented in the settings UI.
    public static let placeholders: [(token: String, description: String)] = [
        ("{summary}", "titre proposé par le modèle"),
        ("{type}", "nom du type de réunion"),
        ("{participant}", "interlocuteur (types one-to-one uniquement)"),
        ("{Weekday}", "Lundi"),
        ("{weekday}", "lundi"),
        ("{date}", "7 septembre 2026"),
        ("{shortDate}", "07/09/2026"),
        ("{isoDate}", "2026-09-07"),
        ("{time}", "14:30"),
    ]

    public static func render(
        _ format: String,
        summaryTitle: String,
        templateName: String,
        date: Date,
        language: SummaryLanguage = .french,
        participant: String = ""
    ) -> String {
        let locale = language.locale
        let weekday = date.formatted(.dateTime.weekday(.wide).locale(locale))
        let substitutions: [String: String] = [
            "{summary}": summaryTitle,
            "{type}": templateName,
            "{participant}": participant,
            "{Weekday}": weekday.capitalizedFirst,
            "{weekday}": weekday.lowercased(),
            "{date}": date.formatted(.dateTime.day().month(.wide).year().locale(locale)),
            "{shortDate}": date.formatted(.dateTime.day(.twoDigits).month(.twoDigits).year().locale(locale)),
            "{isoDate}": date.formatted(.iso8601.year().month().day().dateSeparator(.dash)),
            "{time}": date.formatted(.dateTime.hour().minute().locale(locale)),
        ]

        var result = format
        for (token, value) in substitutions {
            result = result.replacingOccurrences(of: token, with: value)
        }

        // An empty `{summary}` leaves orphaned separators at the start or end of the title.
        result = result
            .replacingOccurrences(of: #"\s*[—–-]\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^\s*[—–-]\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        return result.isEmpty ? summaryTitle : result
    }
}

extension String {
    /// Day names are lowercase in French; only the initial is capitalized,
    /// leaving the rest untouched.
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
