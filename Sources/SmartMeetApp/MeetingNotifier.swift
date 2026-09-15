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
        static let meetingEnded = "meeting-ended"
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

    /// Branchés par la session.
    var onRecord: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onReview: ((UUID) -> Void)?
    var onPublish: ((UUID) -> Void)?
    var onRetrySummary: ((UUID) -> Void)?
    var onMeetingEndedGenerateSummary: (() -> Void)?
    var onMeetingEndedKeepRecording: (() -> Void)?

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
                    action(Action.generateSummary, L("Générer le compte rendu"), foreground: true),
                    action(Action.keepRecording, L("Continuer l'enregistrement")),
                ],
                intentIdentifiers: []
            ),
        ])

        do {
            // Piste non tranchée du TODO : en mode agent (`LSUIElement`/`.accessory`),
            // `usernoted` refuserait l'enregistrement de l'application auprès du centre
            // de notifications. On bascule temporairement en `.regular` pour la seule
            // durée de la demande d'autorisation, avant de revenir en `.accessory` — ce
            // sera visible un court instant dans le Dock. Si l'échec persiste malgré
            // cela, la seconde piste (premier refus mémorisé par le bundle identifier)
            // reste à tester en changeant `CFBundleIdentifier`.
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

    // MARK: - Émission

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

    /// Le compte rendu est prêt à être relu.
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

    /// La page est publiée : la notification porte le lien.
    func announcePublication(meetingID: UUID, title: String, url: URL?, issues: [String]) {
        var body = L("« %@ »", title)
        if !issues.isEmpty {
            body += " " + L("— %d ticket(s) créé(s)", issues.count)
        }
        var payload: [String: String] = [Payload.meetingID: meetingID.uuidString]
        if let url { payload[Payload.url] = url.absoluteString }

        send(
            id: "published-\(meetingID.uuidString)",
            category: Category.published,
            title: L("Publié sur Confluence"),
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
            title: L("Compte rendu impossible"),
            body: L("« %@ » — %@", title, message),
            payload: [Payload.meetingID: meetingID.uuidString]
        )
    }

    /// L'application de visioconférence suivie ne capte plus le micro depuis un
    /// moment : la réunion semble terminée. Une simple proposition — jamais un arrêt
    /// automatique, une coupure passagère (réseau, micro coupé volontairement…) ne
    /// doit pas couper l'enregistrement à la place de l'utilisateur.
    func announceMeetingEnded(meetingID: UUID) {
        send(
            id: "ended-\(meetingID.uuidString)",
            category: Category.meetingEnded,
            title: L("La réunion semble terminée"),
            body: L("Générer le compte rendu, ou continuer l'enregistrement ?"),
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

            case (Category.meetingEnded, Action.generateSummary):
                onMeetingEndedGenerateSummary?()
            case (Category.meetingEnded, _):
                // Tapoter la bannière elle-même reste le choix le moins engageant :
                // on continue l'enregistrement plutôt que de risquer de l'arrêter
                // par un clic hâtif sur la notification.
                onMeetingEndedKeepRecording?()

            default:
                break
            }
        }
    }
}
