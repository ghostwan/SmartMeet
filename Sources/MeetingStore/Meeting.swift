import AudioCapture
import Foundation
import Summarization
import Transcription

/// Metadata of a recorded meeting. The audio and transcript live alongside it,
/// in the same folder.
public struct Meeting: Sendable, Codable, Identifiable, Equatable {
    public var id: UUID
    public var title: String
    public var startedAt: Date
    public var duration: TimeInterval
    public var locale: String
    /// Actual start offset of each track, kept so a retroactively recomputed
    /// transcript can be realigned.
    public var trackStartOffsets: [String: TimeInterval]
    /// Attendees sourced from the calendar, injected into the generation prompt.
    public var knownAttendees: [String]
    /// People confirmed by the user as actually present, edited right before
    /// generation (unlike `knownAttendees`, set once from the calendar at
    /// recording time and never reviewed). Closes the gap the transcript
    /// itself can't: audio tracks and speaker diarization only carry generic
    /// labels ("Participants", "Locuteur 2"), never real names — this is what
    /// lets the model attribute decisions and action items correctly instead
    /// of guessing. Pre-filled from `knownAttendees` as a starting point.
    public var confirmedParticipants: [String]
    /// Chosen meeting type: drives the schema requested from the model and the
    /// rendering order.
    public var templateID: String
    /// Summary language, chosen before recording and independent of the
    /// language spoken during the meeting.
    public var outputLanguage: SummaryLanguage
    /// Generated summary, once available.
    public var summary: MeetingSummary?
    /// Filled in after publication.
    public var confluencePageURL: String?
    public var jiraIssueKeys: [String]
    /// Filled in after publication to Notion.
    public var notionPageURL: String?
    /// Cumulative token consumption for generating the summary (across all
    /// calls: any chunking + invalid-JSON repairs).
    public var tokenUsage: TokenUsage?
    /// Jira link listing all tickets created during the latest publication.
    public var jiraSearchURL: String?
    /// Counterpart of a one-to-one (a type where `requiresParticipant` is true).
    /// `nil` for any other meeting type.
    public var oneToOneParticipant: String?
    /// Email of that counterpart, used to restrict the published Confluence page
    /// to those two accounts only. Optional: without it, the page stays
    /// restricted to the user alone rather than being open to the whole space.
    public var oneToOneParticipantEmail: String?
    /// Confluence `accountId` of that counterpart, resolved ahead of time via
    /// the "search Confluence users" picker (by display name) rather than the
    /// e-mail search, which some Cloud sites restrict for GDPR reasons. Takes
    /// priority over `oneToOneParticipantEmail` at publish time when present.
    public var oneToOneParticipantAccountID: String?
    /// Publication destination carried over from the counterpart configured
    /// in Settings (`OneToOnePerson.destination`), overriding the meeting
    /// type's own destination. `nil` defers to the meeting type, same as
    /// `.profileDefault`.
    public var oneToOneDestination: PublicationDestination?
    /// E-mail of the account to add as a watcher on every Jira ticket created
    /// from this meeting's action items, carried over from the counterpart
    /// configured in Settings. `nil` shares with no one beyond the assignee.
    public var oneToOneJiraShareEmail: String?
    /// Extra people allowed to view the published page, in addition to the
    /// author — independent of the one-to-one restriction above, applicable
    /// to any meeting type. Pre-filled from `MeetingTemplate.
    /// defaultRestrictedViewers` when the meeting is recorded, still editable
    /// from the review window before publication.
    public var restrictedViewers: [RestrictedViewer]

    public init(
        id: UUID = UUID(),
        title: String,
        startedAt: Date = .now,
        duration: TimeInterval = 0,
        locale: String,
        trackStartOffsets: [String: TimeInterval] = [:],
        knownAttendees: [String] = [],
        confirmedParticipants: [String] = [],
        templateID: String = MeetingTemplate.personal.id,
        outputLanguage: SummaryLanguage = .french,
        summary: MeetingSummary? = nil,
        confluencePageURL: String? = nil,
        jiraIssueKeys: [String] = [],
        notionPageURL: String? = nil,
        tokenUsage: TokenUsage? = nil,
        jiraSearchURL: String? = nil,
        oneToOneParticipant: String? = nil,
        oneToOneParticipantEmail: String? = nil,
        oneToOneParticipantAccountID: String? = nil,
        oneToOneDestination: PublicationDestination? = nil,
        oneToOneJiraShareEmail: String? = nil,
        restrictedViewers: [RestrictedViewer] = []
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.duration = duration
        self.locale = locale
        self.trackStartOffsets = trackStartOffsets
        self.knownAttendees = knownAttendees
        self.confirmedParticipants = confirmedParticipants
        self.templateID = templateID
        self.outputLanguage = outputLanguage
        self.summary = summary
        self.confluencePageURL = confluencePageURL
        self.jiraIssueKeys = jiraIssueKeys
        self.notionPageURL = notionPageURL
        self.tokenUsage = tokenUsage
        self.jiraSearchURL = jiraSearchURL
        self.oneToOneParticipant = oneToOneParticipant
        self.oneToOneParticipantEmail = oneToOneParticipantEmail
        self.oneToOneParticipantAccountID = oneToOneParticipantAccountID
        self.oneToOneDestination = oneToOneDestination
        self.oneToOneJiraShareEmail = oneToOneJiraShareEmail
        self.restrictedViewers = restrictedViewers
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, startedAt, duration, locale, trackStartOffsets
        case knownAttendees, confirmedParticipants, templateID, outputLanguage
        case summary, confluencePageURL, jiraIssueKeys, notionPageURL, tokenUsage
        case jiraSearchURL, oneToOneParticipant, oneToOneParticipantEmail
        case oneToOneParticipantAccountID, oneToOneDestination, oneToOneJiraShareEmail
        case restrictedViewers
    }

    // Tolerant decoding: meetings recorded before the summary feature was added
    // must remain readable.
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
        confirmedParticipants = try container.decodeIfPresent(
            [String].self, forKey: .confirmedParticipants
        ) ?? []
        templateID = try container.decodeIfPresent(String.self, forKey: .templateID)
            ?? MeetingTemplate.personal.id
        outputLanguage = try container.decodeIfPresent(
            SummaryLanguage.self, forKey: .outputLanguage
        ) ?? .french
        summary = try container.decodeIfPresent(MeetingSummary.self, forKey: .summary)
        confluencePageURL = try container.decodeIfPresent(String.self, forKey: .confluencePageURL)
        jiraIssueKeys = try container.decodeIfPresent([String].self, forKey: .jiraIssueKeys) ?? []
        notionPageURL = try container.decodeIfPresent(String.self, forKey: .notionPageURL)
        tokenUsage = try container.decodeIfPresent(TokenUsage.self, forKey: .tokenUsage)
        jiraSearchURL = try container.decodeIfPresent(String.self, forKey: .jiraSearchURL)
        oneToOneParticipant = try container.decodeIfPresent(String.self, forKey: .oneToOneParticipant)
        oneToOneParticipantEmail = try container.decodeIfPresent(
            String.self, forKey: .oneToOneParticipantEmail
        )
        oneToOneParticipantAccountID = try container.decodeIfPresent(
            String.self, forKey: .oneToOneParticipantAccountID
        )
        oneToOneDestination = try container.decodeIfPresent(
            PublicationDestination.self, forKey: .oneToOneDestination
        )
        oneToOneJiraShareEmail = try container.decodeIfPresent(
            String.self, forKey: .oneToOneJiraShareEmail
        )
        restrictedViewers = try container.decodeIfPresent(
            [RestrictedViewer].self, forKey: .restrictedViewers
        ) ?? []
    }

    public var formattedDuration: String {
        let total = Int(duration.rounded())
        let (hours, minutes, seconds) = (total / 3600, (total % 3600) / 60, total % 60)
        let format = hours > 0
            ? NSLocalizedString("%d h %02d min", bundle: .main, value: "%d h %02d min", comment: "")
            : NSLocalizedString("%d min %02d s", bundle: .main, value: "%d min %02d s", comment: "")
        return hours > 0
            ? String(format: format, hours, minutes)
            : String(format: format, minutes, seconds)
    }

    public var isPublished: Bool { confluencePageURL != nil }
    public var isPublishedToNotion: Bool { notionPageURL != nil }
    public var hasSummary: Bool { summary != nil }

    /// Used by the history search. `transcript` is optional and loaded by the
    /// caller (disk read via `MeetingStore`): the content spoken during the
    /// meeting, not just the metadata, must be searchable.
    public func matches(_ query: String, transcript: String? = nil) -> Bool {
        guard !query.isEmpty else { return true }
        let needle = query.folding(
            options: [.diacriticInsensitive, .caseInsensitive], locale: nil
        )
        let haystack = (
            [title, summary?.tldr ?? "", transcript ?? "", oneToOneParticipant ?? ""]
                + knownAttendees + confirmedParticipants + (summary?.decisions ?? [])
        )
        .joined(separator: " ")
        .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return haystack.contains(needle)
    }
}
