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
    /// Compte rendu généré, une fois disponible.
    public var summary: MeetingSummary?
    /// Renseignés après publication.
    public var confluencePageURL: String?
    public var jiraIssueKeys: [String]

    public init(
        id: UUID = UUID(),
        title: String,
        startedAt: Date = .now,
        duration: TimeInterval = 0,
        locale: String,
        trackStartOffsets: [String: TimeInterval] = [:],
        knownAttendees: [String] = [],
        templateID: String = MeetingTemplate.generic.id,
        summary: MeetingSummary? = nil,
        confluencePageURL: String? = nil,
        jiraIssueKeys: [String] = []
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.duration = duration
        self.locale = locale
        self.trackStartOffsets = trackStartOffsets
        self.knownAttendees = knownAttendees
        self.templateID = templateID
        self.summary = summary
        self.confluencePageURL = confluencePageURL
        self.jiraIssueKeys = jiraIssueKeys
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, startedAt, duration, locale, trackStartOffsets
        case knownAttendees, templateID, summary, confluencePageURL, jiraIssueKeys
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
        summary = try container.decodeIfPresent(MeetingSummary.self, forKey: .summary)
        confluencePageURL = try container.decodeIfPresent(String.self, forKey: .confluencePageURL)
        jiraIssueKeys = try container.decodeIfPresent([String].self, forKey: .jiraIssueKeys) ?? []
    }

    public var formattedDuration: String {
        let total = Int(duration.rounded())
        let (hours, minutes, seconds) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d h %02d min", hours, minutes)
            : String(format: "%d min %02d s", minutes, seconds)
    }

    public var isPublished: Bool { confluencePageURL != nil }
    public var hasSummary: Bool { summary != nil }

    /// Utilisé par la recherche dans l'historique.
    public func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let needle = query.folding(
            options: [.diacriticInsensitive, .caseInsensitive], locale: nil
        )
        let haystack = ([title, summary?.tldr ?? ""] + knownAttendees + (summary?.decisions ?? []))
            .joined(separator: " ")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return haystack.contains(needle)
    }
}
