import AudioCapture
import Foundation
import Summarization
import Transcription

/// Métadonnées d'une réunion enregistrée. L'audio et le transcript vivent à côté,
/// dans le même dossier.
public struct Meeting: Sendable, Codable, Identifiable, Equatable {
    public var id: UUID
    public var title: String
    public var startedAt: Date
    public var duration: TimeInterval
    public var locale: String
    /// Décalage réel de démarrage de chaque piste, conservé pour pouvoir réaligner
    /// un transcript recalculé a posteriori.
    public var trackStartOffsets: [String: TimeInterval]
    /// Participants issus du calendrier, injectés dans le prompt de génération.
    public var knownAttendees: [String]
    /// Type de réunion retenu : pilote le schéma demandé au modèle et l'ordre de rendu.
    public var templateID: String
    /// Langue du compte rendu, choisie avant l'enregistrement et indépendante de la
    /// langue parlée pendant la réunion.
    public var outputLanguage: SummaryLanguage
    /// Compte rendu généré, une fois disponible.
    public var summary: MeetingSummary?
    /// Renseignés après publication.
    public var confluencePageURL: String?
    public var jiraIssueKeys: [String]
    /// Renseigné après publication sur Notion.
    public var notionPageURL: String?
    /// Consommation cumulée de tokens pour la génération du compte rendu (tous
    /// appels confondus : découpage éventuel + réparations de JSON invalide).
    public var tokenUsage: TokenUsage?
    /// Lien Jira listant tous les tickets créés lors de la dernière publication.
    public var jiraSearchURL: String?

    public init(
        id: UUID = UUID(),
        title: String,
        startedAt: Date = .now,
        duration: TimeInterval = 0,
        locale: String,
        trackStartOffsets: [String: TimeInterval] = [:],
        knownAttendees: [String] = [],
        templateID: String = MeetingTemplate.generic.id,
        outputLanguage: SummaryLanguage = .french,
        summary: MeetingSummary? = nil,
        confluencePageURL: String? = nil,
        jiraIssueKeys: [String] = [],
        notionPageURL: String? = nil,
        tokenUsage: TokenUsage? = nil,
        jiraSearchURL: String? = nil
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.duration = duration
        self.locale = locale
        self.trackStartOffsets = trackStartOffsets
        self.knownAttendees = knownAttendees
        self.templateID = templateID
        self.outputLanguage = outputLanguage
        self.summary = summary
        self.confluencePageURL = confluencePageURL
        self.jiraIssueKeys = jiraIssueKeys
        self.notionPageURL = notionPageURL
        self.tokenUsage = tokenUsage
        self.jiraSearchURL = jiraSearchURL
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, startedAt, duration, locale, trackStartOffsets
        case knownAttendees, templateID, outputLanguage
        case summary, confluencePageURL, jiraIssueKeys, notionPageURL, tokenUsage
        case jiraSearchURL
    }

    // Décodage tolérant : les réunions enregistrées avant l'ajout du compte rendu
    // doivent rester lisibles.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        locale = try container.decodeIfPresent(String.self, forKey: .locale) ?? "fr-FR"
        trackStartOffsets = try container.decodeIfPresent(
            [String: TimeInterval].self, forKey: .trackStartOffsets
        ) ?? [:]
        knownAttendees = try container.decodeIfPresent([String].self, forKey: .knownAttendees) ?? []
        templateID = try container.decodeIfPresent(String.self, forKey: .templateID)
            ?? MeetingTemplate.generic.id
        outputLanguage = try container.decodeIfPresent(
            SummaryLanguage.self, forKey: .outputLanguage
        ) ?? .french
        summary = try container.decodeIfPresent(MeetingSummary.self, forKey: .summary)
        confluencePageURL = try container.decodeIfPresent(String.self, forKey: .confluencePageURL)
        jiraIssueKeys = try container.decodeIfPresent([String].self, forKey: .jiraIssueKeys) ?? []
        notionPageURL = try container.decodeIfPresent(String.self, forKey: .notionPageURL)
        tokenUsage = try container.decodeIfPresent(TokenUsage.self, forKey: .tokenUsage)
        jiraSearchURL = try container.decodeIfPresent(String.self, forKey: .jiraSearchURL)
    }

    public var formattedDuration: String {
        let total = Int(duration.rounded())
        let (hours, minutes, seconds) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d h %02d min", hours, minutes)
            : String(format: "%d min %02d s", minutes, seconds)
    }

    public var isPublished: Bool { confluencePageURL != nil }
    public var isPublishedToNotion: Bool { notionPageURL != nil }
    public var hasSummary: Bool { summary != nil }

    /// Utilisé par la recherche dans l'historique. `transcript` est optionnel et
    /// chargé par l'appelant (lecture disque via `MeetingStore`) : le contenu prononcé
    /// en réunion, pas seulement les métadonnées, doit pouvoir être retrouvé.
    public func matches(_ query: String, transcript: String? = nil) -> Bool {
        guard !query.isEmpty else { return true }
        let needle = query.folding(
            options: [.diacriticInsensitive, .caseInsensitive], locale: nil
        )
        let haystack = (
            [title, summary?.tldr ?? "", transcript ?? ""]
                + knownAttendees + (summary?.decisions ?? [])
        )
        .joined(separator: " ")
        .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return haystack.contains(needle)
    }
}
