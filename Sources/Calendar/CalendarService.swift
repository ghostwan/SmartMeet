import EventKit
import Foundation

/// Un événement de calendrier susceptible de correspondre à la réunion en cours.
public struct CalendarMeeting: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let startDate: Date
    public let endDate: Date
    public let attendees: [String]
    public let hasVideoLink: Bool

    public init(
        id: String,
        title: String,
        startDate: Date,
        endDate: Date,
        attendees: [String],
        hasVideoLink: Bool
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.attendees = attendees
        self.hasVideoLink = hasVideoLink
    }
}

/// Récupère la réunion en cours pour préremplir titre et participants.
///
/// Le transcript ne nomme pas les locuteurs : sans le calendrier, le compte rendu se
/// résume à « Moi » et « Participants ». C'est ici que viennent les vrais noms.
@MainActor
public final class CalendarService {
    // EKEventStore n'est pas Sendable : le service reste confiné au main actor,
    // ce qui convient à un usage purement déclenché par l'interface.
    private let store = EKEventStore()

    public init() {}

    public func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    public var isAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// Réunion couvrant l'instant présent, ou démarrant dans les minutes qui suivent.
    public func currentMeeting(tolerance: TimeInterval = 300) -> CalendarMeeting? {
        guard isAuthorized else { return nil }

        let now = Date.now
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-tolerance),
            end: now.addingTimeInterval(tolerance),
            calendars: nil
        )

        let candidates = store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .filter { $0.status != .canceled }
            .sorted { abs($0.startDate.timeIntervalSince(now)) < abs($1.startDate.timeIntervalSince(now)) }

        guard let event = candidates.first else { return nil }
        return meeting(from: event)
    }

    public func upcomingMeetings(within window: TimeInterval = 3600 * 8) -> [CalendarMeeting] {
        guard isAuthorized else { return [] }
        let now = Date.now
        let predicate = store.predicateForEvents(
            withStart: now, end: now.addingTimeInterval(window), calendars: nil
        )
        return store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }
            .map(meeting(from:))
    }

    private func meeting(from event: EKEvent) -> CalendarMeeting {
        let attendees = (event.attendees ?? [])
            .compactMap { $0.name }
            // L'organisateur apparaît aussi dans la liste des participants.
            .filter { $0 != event.organizer?.name }

        let haystack = [event.location, event.notes, event.url?.absoluteString]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        let videoHosts = ["teams.microsoft", "meet.google", "zoom.us", "webex", "whereby"]

        return CalendarMeeting(
            id: event.eventIdentifier ?? UUID().uuidString,
            title: event.title ?? "Réunion",
            startDate: event.startDate,
            endDate: event.endDate,
            attendees: attendees,
            hasVideoLink: videoHosts.contains { haystack.contains($0) }
        )
    }
}
