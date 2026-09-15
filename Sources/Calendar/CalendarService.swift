import EventKit
import Foundation

/// A calendar event that may correspond to the ongoing meeting.
public struct CalendarMeeting: Sendable, Equatable, Identifiable {
    /// A named attendee, with their e-mail when EventKit provides it — useful
    /// for suggesting a one-to-one counterpart without manual re-entry.
    public struct Attendee: Sendable, Equatable, Identifiable {
        public let name: String
        public let email: String?
        public var id: String { email ?? name }

        public init(name: String, email: String? = nil) {
            self.name = name
            self.email = email
        }
    }

    public let id: String
    public let title: String
    public let startDate: Date
    public let endDate: Date
    public let attendees: [String]
    /// Same attendees as `attendees`, but with their e-mail when available.
    public let attendeeDetails: [Attendee]
    public let hasVideoLink: Bool

    public init(
        id: String,
        title: String,
        startDate: Date,
        endDate: Date,
        attendees: [String],
        attendeeDetails: [Attendee] = [],
        hasVideoLink: Bool
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.attendees = attendees
        self.attendeeDetails = attendeeDetails
        self.hasVideoLink = hasVideoLink
    }
}

/// Retrieves the current meeting to prefill the title and attendees.
///
/// The transcript doesn't name the speakers: without the calendar, the
/// meeting minutes are reduced to "Me" and "Attendees". This is where the
/// real names come from.
@MainActor
public final class CalendarService {
    // EKEventStore is not Sendable: the service stays confined to the main
    // actor, which suits a use purely triggered by the interface.
    private let store = EKEventStore()

    public init() {}

    public func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    public var isAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// Meeting covering the present moment, or starting within the next few minutes.
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
        let participants = (event.attendees ?? [])
            // The organizer also appears in the attendee list.
            .filter { $0.name != nil && $0.name != event.organizer?.name }
        let attendees = participants.compactMap(\.name)
        let attendeeDetails = participants.compactMap { participant -> CalendarMeeting.Attendee? in
            guard let name = participant.name else { return nil }
            // EventKit exposes the e-mail via a `mailto:` URL, not a dedicated field.
            let email = participant.url.scheme == "mailto"
                ? String(participant.url.absoluteString.dropFirst("mailto:".count))
                : nil
            return CalendarMeeting.Attendee(name: name, email: email)
        }

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
            attendeeDetails: attendeeDetails,
            hasVideoLink: videoHosts.contains { haystack.contains($0) }
        )
    }
}
