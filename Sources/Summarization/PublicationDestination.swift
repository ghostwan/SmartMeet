import Foundation

/// Où publier le compte rendu, relativement à l'espace Confluence retenu.
public enum ParentPageReference: Codable, Sendable, Equatable, Hashable {
    /// Page d'accueil de l'espace.
    case spaceHome
    /// Page fixe, désignée par son identifiant Confluence.
    case page(id: String)
    /// Page de sprint courante, définie une fois en début de sprint dans les réglages.
    /// Toutes les réunions rattachées au sprint suivent automatiquement.
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

/// Composition du titre de la page publiée.
///
/// Le titre produit par le modèle est trop variable pour servir de convention de
/// nommage : deux dailys consécutifs sortent avec des libellés différents, ce qui rend
/// l'arborescence Confluence illisible. Le format reprend donc la main dessus.
public struct TitleFormat: Sendable {
    /// Jetons reconnus, documentés dans l'interface des réglages.
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

        // Un `{summary}` vide laisse des séparateurs orphelins en début ou fin de titre.
        result = result
            .replacingOccurrences(of: #"\s*[—–-]\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^\s*[—–-]\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        return result.isEmpty ? summaryTitle : result
    }
}

extension String {
    /// Les noms de jours sont en minuscules en français ; on ne capitalise que
    /// l'initiale, sans toucher au reste.
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
