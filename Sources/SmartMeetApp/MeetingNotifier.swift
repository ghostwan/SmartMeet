import AppKit
import Foundation
import SmartMeetCalendar
import UserNotifications

/// Notifications actionnables du cycle de vie d'une réunion.
///
/// Le menu-bar est masqué la plupart du temps : une bannière système est le seul
/// moyen d'atteindre l'utilisateur, qu'il soit en train de basculer vers sa
/// visioconférence ou parti faire autre chose pendant la génération du compte rendu.
@MainActor
final class MeetingNotifier: NSObject, UNUserNotificationCenterDelegate {
    private enum Category {
        static let suggestion = "meeting-suggestion"
        static let summaryReady = "summary-ready"
        static let published = "meeting-published"
        static let failure = "meeting-failure"
    }

    private enum Action {
        static let record = "record"
        static let dismiss = "dismiss"
        static let review = "review"
        static let publish = "publish"
        static let open = "open"
        static let retry = "retry"
    }

    private enum Payload {
        static let meetingID = "meetingID"
        static let url = "url"
    }

    /// Branchés par la session.
    var onRecord: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onReview: ((UUID) -> Void)?
    var onPublish: ((UUID) -> Void)?
    var onRetrySummary: ((UUID) -> Void)?

    private var isAuthorized = false
    /// Dernière erreur d'autorisation, remontée par le diagnostic.
    private(set) var authorizationError: String?
    private var deliveredSuggestionIDs: Set<String> = []

    /// `UNUserNotificationCenter` lève une exception Objective-C, non rattrapable en
    /// Swift, si l'exécutable ne vit pas dans un bundle. Le mode headless en ligne de
    /// commande passerait sinon par là.
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
                    action(Action.record, "Enregistrer", foreground: true),
                    action(Action.dismiss, "Pas maintenant"),
                ],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: Category.summaryReady,
                actions: [
                    action(Action.review, "Relire", foreground: true),
                    action(Action.publish, "Publier", foreground: true),
                ],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: Category.published,
                actions: [action(Action.open, "Ouvrir la page", foreground: true)],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: Category.failure,
                actions: [action(Action.retry, "Réessayer", foreground: true)],
                intentIdentifiers: []
            ),
        ])

        do {
            isAuthorized = try await center.requestAuthorization(options: [.alert, .sound])
            authorizationError = nil
        } catch {
            isAuthorized = false
            authorizationError = error.localizedDescription
        }
    }

    // MARK: - Émission

    func propose(_ suggestion: MeetingSuggestion) {
        guard !deliveredSuggestionIDs.contains(suggestion.id) else { return }
        deliveredSuggestionIDs.insert(suggestion.id)
        send(
            id: suggestion.id,
            category: Category.suggestion,
            title: "Enregistrer « \(suggestion.title) » ?",
            body: suggestion.reason
        )
    }

    /// Le compte rendu est prêt à être relu.
    func announceSummaryReady(meetingID: UUID, title: String, actionItemCount: Int) {
        let detail = actionItemCount == 0
            ? "Aucun action item"
            : "\(actionItemCount) action item\(actionItemCount > 1 ? "s" : "")"
        send(
            id: "summary-\(meetingID.uuidString)",
            category: Category.summaryReady,
            title: "Compte rendu prêt",
            body: "« \(title) » — \(detail)",
            payload: [Payload.meetingID: meetingID.uuidString]
        )
    }

    /// La page est publiée : la notification porte le lien.
    func announcePublication(meetingID: UUID, title: String, url: URL?, issues: [String]) {
        var body = "« \(title) »"
        if !issues.isEmpty {
            body += " — \(issues.count) ticket\(issues.count > 1 ? "s" : "") créé\(issues.count > 1 ? "s" : "")"
        }
        var payload: [String: String] = [Payload.meetingID: meetingID.uuidString]
        if let url { payload[Payload.url] = url.absoluteString }

        send(
            id: "published-\(meetingID.uuidString)",
            category: Category.published,
            title: "Publié sur Confluence",
            body: body,
            payload: payload
        )
    }

    /// Une génération ratée doit se voir : sans notification, l'échec passe inaperçu
    /// jusqu'à ce qu'on rouvre le menu.
    func announceFailure(meetingID: UUID, title: String, message: String) {
        send(
            id: "failure-\(meetingID.uuidString)",
            category: Category.failure,
            title: "Compte rendu impossible",
            body: "« \(title) » — \(message)",
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

    /// Sans ceci, macOS masque la bannière quand l'application est au premier plan.
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
                // Le lien est le cœur de cette notification : cliquer ouvre la page.
                if let url {
                    NSWorkspace.shared.open(url)
                } else if let meetingID {
                    onReview?(meetingID)
                }

            case (Category.failure, Action.retry):
                if let meetingID { onRetrySummary?(meetingID) }
            case (Category.failure, _):
                if let meetingID { onReview?(meetingID) }

            default:
                break
            }
        }
    }
}
