import Foundation

/// The app's own version, as reported by the bundle at runtime — the single
/// source of truth is the repo-root `VERSION` file, injected into
/// `CFBundleShortVersionString` by `Scripts/bundle-app.sh` at build time.
enum AppVersion {
    static var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
}
