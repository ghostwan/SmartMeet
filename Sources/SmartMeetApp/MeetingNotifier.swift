import AppKit
import Foundation
import SmartMeetCalendar
import UserNotifications

/// Propose d'enregistrer une réunion détectée, via une notification actionnable.
///
/// Le menu-bar est masqué la plupart du temps : une bannière système est le seul
/// moyen d'atteindre l'utilisateur pendant qu'il bascule vers sa visioconférence.
@MainActor
final class MeetingNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let category = "meeting-suggestion"
    private enum Action {
        static let record = "record"
        static let dismiss = "dismiss"
    }

    /// Appelés depuis la notification ; branchés par la session.
    var onRecord: (() -> Void)?
    var onDismiss: (() -> Void)?

    private var isAuthorized = false
    private var deliveredIDs: Set<String> = []

    /// Vrai si l'exécutable vit dans un bundle : `UNUserNotificationCenter` lève une
    /// exception Objective-C, non rattrapable en Swift, si ce n'est pas le cas. Le
    /// mode headless en ligne de commande passerait sinon par là.
    private var isBundled: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    func prepare() async {
        guard isBundled else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let record = UNNotificationAction(
            identifier: Action.record,
            title: "Enregistrer",
            options: [.foreground]
        )
        let dismiss = UNNotificationAction(
            identifier: Action.dismiss,
            title: "Pas maintenant",
            options: []
        )
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.category,
                actions: [record, dismiss],
                intentIdentifiers: [],
                options: []
            )
        ])

        isAuthorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func propose(_ suggestion: MeetingSuggestion) {
        guard isAuthorized, !deliveredIDs.contains(suggestion.id) else { return }
        deliveredIDs.insert(suggestion.id)

        let content = UNMutableNotificationContent()
        content.title = "Enregistrer « \(suggestion.title) » ?"
        content.body = suggestion.reason
        content.categoryIdentifier = Self.category
        content.sound = .default

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: suggestion.id, content: content, trigger: nil
            )
        )
    }

    func withdraw(_ id: String) {
        guard isBundled else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
    }

    func reset() {
        deliveredIDs.removeAll()
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
        let identifier = response.actionIdentifier
        await MainActor.run {
            switch identifier {
            case Action.record, UNNotificationDefaultActionIdentifier:
                onRecord?()
            default:
                onDismiss?()
            }
        }
    }
}
