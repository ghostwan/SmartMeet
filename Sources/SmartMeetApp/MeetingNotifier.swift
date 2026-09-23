import AppKit
import Foundation
import SmartMeetCalendar
import UserNotifications

/// Actionable notifications for a meeting's lifecycle.
///
/// The menu bar is hidden most of the time: a system banner is the only way
/// to reach the user, whether they're switching over to their video
/// conference or have gone off to do something else while minutes are
/// being generated.
@MainActor
final class MeetingNotifier: NSObject, UNUserNotificationCenterDelegate {
    private enum Category {
        static let suggestion = "meeting-suggestion"
        static let summaryReady = "summary-ready"
        static let published = "meeting-published"
        static let failure = "meeting-failure"
        static let meetingEnded = "meeting-ended"
        static let maxDurationReached = "max-duration-reached"
    }

    private enum Action {
        static let record = "record"
        static let dismiss = "dismiss"
        static let review = "review"
        static let publish = "publish"
        static let open = "open"
        static let retry = "retry"
        static let generateSummary = "generate-summary"
        static let keepRecording = "keep-recording"
    }

    private enum Payload {
        static let meetingID = "meetingID"
        static let url = "url"
    }

    /// Wired up by the session.
    var onRecord: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onReview: ((UUID) -> Void)?
    var onPublish: ((UUID) -> Void)?
    var onRetrySummary: ((UUID) -> Void)?
    var onMeetingEndedGenerateSummary: (() -> Void)?
    var onMeetingEndedKeepRecording: (() -> Void)?

    private var isAuthorized = false
    /// Last authorization error, surfaced by the diagnostic.
    private(set) var authorizationError: String?
    private var deliveredSuggestionIDs: Set<String> = []

    /// `UNUserNotificationCenter` throws an uncatchable Objective-C exception in
    /// Swift if the executable doesn't live inside a bundle. The headless
    /// command-line mode would otherwise hit this.
    private var isBundled: Bool { Bundle.main.bundleIdentifier != nil }

    func prepare() async {
        guard isBundled else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        func action(_ id: String, _ title: String, foreground: Bool = false) -> UNNotificationAction {
            UNNotificationAction(
                identifier: id, title: title, options: foreground ? [.foreground] : []
            )
        }

        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Category.suggestion,
                actions: [
                    action(Action.record, L("Enregistrer"), foreground: true),
                    action(Action.dismiss, L("Pas maintenant")),
                ],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: Category.summaryReady,
                actions: [
                    action(Action.review, L("Relire"), foreground: true),
                    action(Action.publish, L("Publier"), foreground: true),
                ],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: Category.published,
                actions: [action(Action.open, L("Ouvrir la page"), foreground: true)],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: Category.failure,
                actions: [action(Action.retry, L("Réessayer"), foreground: true)],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: Category.meetingEnded,
                actions: [
                    action(Action.generateSummary, L("Terminer et générer"), foreground: true),
                    action(Action.keepRecording, L("Reprendre")),
                ],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: Category.maxDurationReached,
                actions: [action(Action.review, L("Relire"), foreground: true)],
                intentIdentifiers: []
            ),
        ])

        do {
            // Unresolved lead from the TODO: in agent mode (`LSUIElement`/`.accessory`),
            // `usernoted` supposedly refuses to register the app with the notification
            // center. We temporarily switch to `.regular` for the duration of the
            // authorization request only, then revert to `.accessory` — this will be
            // briefly visible in the Dock. If the failure persists despite this, the
            // second lead (first denial remembered by the bundle identifier) still
            // needs testing by changing `CFBundleIdentifier`.
            let application = NSApplication.shared
            let previousPolicy = application.activationPolicy()
            application.setActivationPolicy(.regular)
            defer { application.setActivationPolicy(previousPolicy) }

            isAuthorized = try await center.requestAuthorization(options: [.alert, .sound])
            authorizationError = nil
        } catch {
            isAuthorized = false
            authorizationError = error.localizedDescription
        }
    }

    // MARK: - Emission

    func propose(_ suggestion: MeetingSuggestion) {
        guard !deliveredSuggestionIDs.contains(suggestion.id) else { return }
        deliveredSuggestionIDs.insert(suggestion.id)
        send(
            id: suggestion.id,
            category: Category.suggestion,
            title: L("Enregistrer « %@ » ?", suggestion.title),
            body: suggestion.reason
        )
    }

    /// The minutes are ready to be reviewed.
    func announceSummaryReady(meetingID: UUID, title: String, actionItemCount: Int) {
        let detail = actionItemCount == 0
            ? L("Aucun action item")
            : L("%d action item(s)", actionItemCount)
        send(
            id: "summary-\(meetingID.uuidString)",
            category: Category.summaryReady,
            title: L("Compte rendu prêt"),
            body: L("« %@ » — %@", title, detail),
            payload: [Payload.meetingID: meetingID.uuidString]
        )
    }

    /// The page has been published: the notification carries the link.
    func announcePublication(
        meetingID: UUID,
        title: String,
        serviceName: String,
        url: URL?,
        issues: [String]
    ) {
        var body = L("« %@ »", title)
        if !issues.isEmpty {
            body += " " + L("— %d ticket(s) créé(s)", issues.count)
        }
        var payload: [String: String] = [Payload.meetingID: meetingID.uuidString]
        if let url { payload[Payload.url] = url.absoluteString }

        send(
            id: "published-\(meetingID.uuidString)",
            category: Category.published,
            title: L("Publié sur %@", serviceName),
            body: body,
            payload: payload
        )
    }

    /// A failed generation must be visible: without a notification, the failure
    /// goes unnoticed until the menu is reopened.
    func announceFailure(meetingID: UUID, title: String, message: String) {
        send(
            id: "failure-\(meetingID.uuidString)",
            category: Category.failure,
            title: L("Compte rendu impossible"),
            body: L("« %@ » — %@", title, message),
            payload: [Payload.meetingID: meetingID.uuidString]
        )
    }

    /// The tracked video-conferencing app has stopped picking up the microphone
    /// for a while, or the calendar event's scheduled end has passed: the
    /// meeting seems to be over. Recording is already paused by this point
    /// (see `RecordingSession.pauseForSuspectedEnd`) rather than left running
    /// on the assumption this notification gets seen — it's just how the
    /// user is told, and offered a quick way to resume if it's a false
    /// positive.
    func announceMeetingEnded(meetingID: UUID, reasonMessage: String) {
        send(
            id: "ended-\(meetingID.uuidString)",
            category: Category.meetingEnded,
            title: L("Réunion en pause — terminée ?"),
            body: reasonMessage + " " + L("L'enregistrement est en pause."),
            payload: [Payload.meetingID: meetingID.uuidString]
        )
    }

    /// The hard duration cap was reached: the recording was stopped and its
    /// minutes generated automatically, without asking — unlike every other
    /// notification here, this reports something already done rather than
    /// asking for a decision.
    func announceMaxDurationReached(meetingID: UUID, hours: Double) {
        send(
            id: "maxduration-\(meetingID.uuidString)",
            category: Category.maxDurationReached,
            title: L("Enregistrement arrêté automatiquement"),
            body: L("Durée maximale de %.0f h atteinte — le compte rendu a été généré.", hours),
            payload: [Payload.meetingID: meetingID.uuidString]
        )
    }

    private func send(
        id: String,
        category: String,
        title: String,
        body: String,
        payload: [String: String] = [:]
    ) {
        guard isAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
        content.userInfo = payload
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: nil)
        )
    }

    func withdraw(_ id: String) {
        guard isBundled else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
    }

    func reset() {
        deliveredSuggestionIDs.removeAll()
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Without this, macOS hides the banner when the app is in the foreground.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        let category = response.notification.request.content.categoryIdentifier
        let info = response.notification.request.content.userInfo
        let meetingID = (info[Payload.meetingID] as? String).flatMap(UUID.init(uuidString:))
        let url = (info[Payload.url] as? String).flatMap(URL.init(string:))

        await MainActor.run {
            switch (category, action) {
            case (Category.suggestion, Action.dismiss):
                onDismiss?()
            case (Category.suggestion, _):
                onRecord?()

            case (Category.summaryReady, Action.publish):
                if let meetingID { onPublish?(meetingID) }
            case (Category.summaryReady, _):
                if let meetingID { onReview?(meetingID) }

            case (Category.published, _):
                // The link is the whole point of this notification: tapping opens the page.
                if let url {
                    NSWorkspace.shared.open(url)
                } else if let meetingID {
                    onReview?(meetingID)
                }

            case (Category.failure, Action.retry):
                if let meetingID { onRetrySummary?(meetingID) }
            case (Category.failure, _):
                if let meetingID { onReview?(meetingID) }

            case (Category.meetingEnded, Action.generateSummary):
                onMeetingEndedGenerateSummary?()
            case (Category.meetingEnded, _):
                // Tapping the banner itself remains the least committal choice:
                // resume recording rather than risk stopping it via a hasty tap
                // on the notification.
                onMeetingEndedKeepRecording?()

            case (Category.maxDurationReached, _):
                if let meetingID { onReview?(meetingID) }

            default:
                break
            }
        }
    }
}
