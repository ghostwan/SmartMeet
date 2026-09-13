import AppKit
import Foundation
import UserNotifications

/// Vérifie que les notifications sont autorisées et réellement délivrées.
///
/// ⚠️ TRAVAIL EN COURS — les notifications ne fonctionnent pas encore sur cette
/// machine. `requestAuthorization` échoue avec « Notifications are not allowed for
/// this application » et l'application n'apparaît jamais dans
/// `~/Library/Preferences/com.apple.ncprefs.plist`.
///
/// Ce qui a été écarté par l'expérience :
/// - la localisation seule : l'échec persiste depuis `/Applications` ;
/// - le hardened runtime, l'identité de signature (Apple Development, ad-hoc) ;
/// - l'absence de `NSApplication` : le diagnostic en démarre une vraie désormais ;
/// - une politique MDM : le profil `com.apple.notificationsettings` présent ne
///   liste que deux bundles Microsoft et ne restreint pas les autres.
///
/// Fait notable : un bundle minimal, **sans `LSUIElement` et en politique
/// d'activation `.regular`**, lancé depuis `/Applications`, obtient l'autorisation.
/// Deux pistes ont été identifiées :
/// 1. le mode agent (`LSUIElement`) empêcherait l'enregistrement auprès de
///    `usernoted` — **testé** : `MeetingNotifier.prepare()` bascule désormais en
///    `.regular` pour la seule durée de `requestAuthorization`, avant de revenir en
///    `.accessory`. Sur une machine sans identité de signature stable (signature
///    ad-hoc, qui change à chaque build), le refus persiste malgré tout — donc soit
///    l'hypothèse est fausse, soit la signature instable invalide toute mémorisation
///    d'autorisation avant même de poser la question. À revérifier sur la machine
///    de développement avec une identité stable ;
/// 2. le premier refus pour `com.smartmeet.app` est mémorisé et colle au bundle,
///    auquel cas il faut réinitialiser l'état ou changer d'identifiant pour tester.
///
/// À reprendre en isolant ces deux variables une par une.
///
///     open build/SmartMeet.app --args --check-notifications /tmp/rapport.txt
///
/// Lancer l'exécutable depuis un terminal ne suffit pas : l'application ne serait
/// pas enregistrée auprès de LaunchServices, et la demande d'autorisation ne
/// parviendrait jamais à l'utilisateur — même piège que la capture audio.
///
/// Les autorisations de notification sont une source classique de « ça ne marche
/// pas chez moi » : ce diagnostic distingue un refus d'autorisation d'un problème
/// de code, sans avoir à enregistrer une vraie réunion.
@MainActor
enum NotificationCheck {
    /// Lancé par `open`, stdout part dans le vide : tout est aussi écrit sur disque.
    private static var reportURL: URL?
    private static var lines: [String] = []

    private static func emit(_ line: String) {
        print(line)
        lines.append(line)
        guard let reportURL else { return }
        try? lines.joined(separator: "\n")
            .write(to: reportURL, atomically: true, encoding: .utf8)
    }

    /// `UNUserNotificationCenter` exige une `NSApplication` réellement lancée : une
    /// simple `RunLoop` ne suffit pas et fait échouer la demande d'autorisation avec
    /// « Notifications are not allowed for this application ».
    static func boot(reportPath: String?) {
        let application = NSApplication.shared
        let delegate = CheckDelegate(reportPath: reportPath)
        application.delegate = delegate
        // Agent : pas d'icône dans le Dock, comme l'application réelle.
        application.setActivationPolicy(.accessory)
        application.run()
    }

    static func run(reportPath: String?) async {
        reportURL = reportPath.map { URL(filePath: $0) }
        if let reportURL {
            try? FileManager.default.createDirectory(
                at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
        }

        guard Bundle.main.bundleIdentifier != nil else {
            emit("❌ exécutable hors bundle — les notifications sont impossibles.")
            exit(1)
        }
        emit("Diagnostic des notifications — \(Date().formatted())")

        emit("bundle : \(Bundle.main.bundleIdentifier ?? "?") — \(Bundle.main.bundlePath)")

        let notifier = MeetingNotifier()
        await notifier.prepare()
        if let error = notifier.authorizationError {
            emit("erreur de demande d'autorisation : \(error)")
        }

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        emit("autorisation : \(describe(settings.authorizationStatus))")
        emit("bannières    : \(describe(settings.alertSetting))")
        emit("son          : \(describe(settings.soundSetting))")

        guard settings.authorizationStatus == .authorized else {
            emit("❌ Notifications refusées. Réglages › Notifications › SmartMeet")
            exit(1)
        }

        let meetingID = UUID()
        notifier.announceSummaryReady(
            meetingID: meetingID,
            title: "Réunion de test",
            actionItemCount: 3
        )
        notifier.announcePublication(
            meetingID: UUID(),
            title: "Réunion de test",
            url: URL(string: "https://example.com/page"),
            issues: ["TEST-1", "TEST-2"]
        )

        // Laisse le temps au centre de notifications de les enregistrer.
        try? await Task.sleep(for: .seconds(2))
        let delivered = await center.deliveredNotifications()

        emit("délivrées : \(delivered.count)")
        for notification in delivered {
            let content = notification.request.content
            emit("  • [\(content.categoryIdentifier)] \(content.title) — \(content.body)")
        }

        if delivered.isEmpty {
            emit("❌ Aucune notification délivrée malgré l'autorisation.")
            exit(1)
        }
        emit("✅ Notifications fonctionnelles.")
        exit(0)
    }

    private static func describe(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized: "accordée"
        case .denied: "refusée"
        case .notDetermined: "non demandée"
        case .provisional: "provisoire"
        case .ephemeral: "éphémère"
        @unknown default: "inconnue"
        }
    }

    private static func describe(_ setting: UNNotificationSetting) -> String {
        switch setting {
        case .enabled: "activées"
        case .disabled: "désactivées"
        case .notSupported: "non supportées"
        @unknown default: "inconnu"
        }
    }
}

/// Maintient le délégué en vie le temps du diagnostic.
@MainActor
private final class CheckDelegate: NSObject, NSApplicationDelegate {
    private let reportPath: String?

    init(reportPath: String?) {
        self.reportPath = reportPath
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await NotificationCheck.run(reportPath: reportPath) }
    }
}
