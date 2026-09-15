import AudioCapture
import Foundation
import Observation

/// A detected meeting, offered for recording.
public struct MeetingSuggestion: Sendable, Equatable, Identifiable {
    /// Origin of the detection, which determines how much confidence to give it.
    public enum Trigger: Sendable, Equatable {
        /// A video-conferencing app is capturing the microphone: the meeting has started.
        case conferencingApp(String)
        /// A calendar event has just started.
        case calendar
        /// Both signals agree.
        case both(app: String)
    }

    public let id: String
    public let title: String
    public let attendees: [String]
    public let trigger: Trigger
    public let detectedAt: Date
    /// Associated calendar event, if there is one.
    public let calendarMeeting: CalendarMeeting?

    public var appName: String? {
        switch trigger {
        case .conferencingApp(let name), .both(let name): name
        case .calendar: nil
        }
    }

    public var reason: String {
        switch trigger {
        case .calendar:
            NSLocalizedString("Réunion à l'agenda", bundle: .main, value: "Réunion à l'agenda", comment: "")
        case .conferencingApp(let app):
            String(
                format: NSLocalizedString("%@ utilise le micro", bundle: .main, value: "%@ utilise le micro", comment: ""),
                app
            )
        case .both(let app):
            String(
                format: NSLocalizedString(
                    "Réunion à l'agenda · %@ utilise le micro",
                    bundle: .main,
                    value: "Réunion à l'agenda · %@ utilise le micro",
                    comment: ""
                ),
                app
            )
        }
    }
}

/// Watches for the arrival of a meeting and offers to record it.
///
/// Two signals, deliberately combined: the calendar says what *should*
/// happen, the video-conferencing app capturing the microphone says what
/// *actually* started. The calendar alone would trigger on canceled or
/// rescheduled meetings; the audio alone knows neither the title nor the
/// attendees.
@MainActor
@Observable
public final class MeetingDetector {
    public private(set) var suggestion: MeetingSuggestion?

    /// Suggestions dismissed by the user, to avoid re-prompting in a loop.
    private var dismissedIDs: Set<String> = []
    private var monitorTask: Task<Void, Never>?

    private let calendar: CalendarService
    private let interval: Duration

    public init(calendar: CalendarService = CalendarService(), interval: Duration = .seconds(20)) {
        self.calendar = calendar
        self.interval = interval
    }

    public func start() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: self?.interval ?? .seconds(20))
            }
        }
    }

    public func stop() {
        monitorTask?.cancel()
        monitorTask = nil
        suggestion = nil
    }

    /// Dismisses the current suggestion without bringing it back for the same meeting.
    public func dismissCurrent() {
        if let suggestion { dismissedIDs.insert(suggestion.id) }
        suggestion = nil
    }

    /// Marks the suggestion as handled: recording has started.
    public func acceptCurrent() {
        if let suggestion { dismissedIDs.insert(suggestion.id) }
        suggestion = nil
    }

    /// Re-arms suggestions, for example after recording has stopped.
    public func resetDismissals() {
        dismissedIDs.removeAll()
    }

    /// Applies a suggestion without going through EventKit. Reserved for
    /// tests: the decision logic is pure, but the monitoring loop is not.
    func applyForTesting(_ candidate: MeetingSuggestion?) {
        guard let candidate else {
            suggestion = nil
            return
        }
        guard !dismissedIDs.contains(candidate.id) else { return }
        if suggestion?.id != candidate.id { suggestion = candidate }
    }

    func refresh() {
        let candidate = MeetingSuggestion.decide(
            apps: ConferencingDetector.activeApps(),
            event: calendar.currentMeeting()
        )

        guard let candidate else {
            // The meeting has ended: the suggestion disappears on its own.
            suggestion = nil
            return
        }
        guard !dismissedIDs.contains(candidate.id) else { return }
        // Don't re-emit the same suggestion on every cycle, which would
        // relaunch a notification every twenty seconds.
        if suggestion?.id != candidate.id { suggestion = candidate }
    }
}

public extension MeetingSuggestion {
    /// Combines the two signals into a proposal, or nothing.
    ///
    /// Rules, in decreasing order of confidence:
    /// - a dedicated video-conferencing app is capturing the microphone: the
    ///   meeting has started, it's proposed even without a calendar event;
    /// - a browser is capturing the microphone: too ambiguous alone (mic
    ///   test, video), it's only trusted if the calendar confirms it;
    /// - an event alone: it's only proposed if it carries a video link,
    ///   otherwise any physical meeting would trigger a proposal.
    static func decide(apps: [ConferencingApp], event: CalendarMeeting?) -> MeetingSuggestion? {
        let dedicated = apps.first(where: \.isDedicated)
        let browser = apps.first(where: { !$0.isDedicated })

        if let app = dedicated ?? (event != nil ? browser : nil) {
            if let event {
                return MeetingSuggestion(
                    id: event.id,
                    title: event.title,
                    attendees: event.attendees,
                    trigger: .both(app: app.name),
                    detectedAt: .now,
                    calendarMeeting: event
                )
            }
            return MeetingSuggestion(
                id: "app-\(app.bundleID)",
                title: app.name,
                attendees: [],
                trigger: .conferencingApp(app.name),
                detectedAt: .now,
                calendarMeeting: nil
            )
        }

        guard let event, event.hasVideoLink else { return nil }
        return MeetingSuggestion(
            id: event.id,
            title: event.title,
            attendees: event.attendees,
            trigger: .calendar,
            detectedAt: .now,
            calendarMeeting: event
        )
    }
}
