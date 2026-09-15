import AppKit
import Foundation
import UserNotifications

/// Checks that notifications are authorized and actually delivered.
///
/// ⚠️ WORK IN PROGRESS — notifications don't work yet on this machine.
/// `requestAuthorization` fails with "Notifications are not allowed for
/// this application" and the app never shows up in
/// `~/Library/Preferences/com.apple.ncprefs.plist`.
///
/// What experimentation has ruled out:
/// - localization alone: the failure persists when launched from `/Applications`;
/// - the hardened runtime, the signing identity (Apple Development, ad-hoc);
/// - the absence of `NSApplication`: the diagnostic now starts a real one;
/// - an MDM policy: the `com.apple.notificationsettings` profile present only
///   lists two Microsoft bundles and doesn't restrict others.
///
/// Notable finding: a minimal bundle, **without `LSUIElement` and with
/// `.regular` activation policy**, launched from `/Applications`, gets the
/// authorization. Two leads have been identified:
/// 1. agent mode (`LSUIElement`) would prevent registration with
///    `usernoted` — **tested**: `MeetingNotifier.prepare()` now switches to
///    `.regular` for the duration of `requestAuthorization` only, then reverts
///    to `.accessory`. On a machine without a stable signing identity (ad-hoc
///    signature, which changes on every build), the denial persists regardless —
///    so either the hypothesis is wrong, or the unstable signature invalidates
///    any authorization memory before the prompt is even shown. Needs
///    re-checking on the development machine with a stable identity;
/// 2. the first denial for `com.smartmeet.app` is remembered and sticks to the
///    bundle, in which case the state needs resetting or the identifier
///    changing to test again.
///
/// To be resumed by isolating these two variables one at a time.
///
///     open build/SmartMeet.app --args --check-notifications /tmp/rapport.txt
///
/// Running the executable from a terminal isn't enough: the app wouldn't be
/// registered with LaunchServices, and the authorization request would never
/// reach the user — same trap as audio capture.
///
/// Notification authorizations are a classic source of "works on my machine":
/// this diagnostic distinguishes an authorization denial from a code issue,
/// without having to record an actual meeting.
@MainActor
enum NotificationCheck {
    /// Launched by `open`, stdout goes nowhere: everything is also written to disk.
    private static var reportURL: URL?
    private static var lines: [String] = []

    private static func emit(_ line: String) {
        print(line)
        lines.append(line)
        guard let reportURL else { return }
        try? lines.joined(separator: "\n")
            .write(to: reportURL, atomically: true, encoding: .utf8)
    }

    /// `UNUserNotificationCenter` requires an actually running `NSApplication`: a
    /// plain `RunLoop` isn't enough and makes the authorization request fail with
    /// "Notifications are not allowed for this application".
    static func boot(reportPath: String?) {
        let application = NSApplication.shared
        let delegate = CheckDelegate(reportPath: reportPath)
        application.delegate = delegate
        // Agent: no Dock icon, just like the real app.
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

        // Gives the notification center time to register them.
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

/// Keeps the delegate alive for the duration of the diagnostic.
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
