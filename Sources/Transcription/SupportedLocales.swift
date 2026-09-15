import Foundation
import Speech

/// Exposes the locales that the `Speech` framework can natively transcribe on
/// this machine, to build a dynamic list rather than one hardcoded in the UI —
/// without this, a language supported by macOS but overlooked in the code
/// would stay invisible to the user.
public enum SupportedTranscriptionLocales {
    /// All locales recognized by `SpeechTranscriber`, sorted by readable name
    /// in the user's locale (e.g. "Chinese (Mainland China)").
    public static func all(displayIn uiLocale: Locale = .current) async -> [(id: String, label: String)] {
        let locales = await SpeechTranscriber.supportedLocales
        return locales
            .map { locale in (id: locale.identifier, label: displayName(for: locale, in: uiLocale)) }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    /// Exact identifier recognized by the framework for a given locale, when it
    /// exists (used to migrate an identifier stored in a different format,
    /// e.g. `fr-FR` to `fr_FR`).
    public static func resolvedIdentifier(for locale: Locale) async -> String? {
        await SpeechTranscriber.supportedLocale(equivalentTo: locale)?.identifier
    }

    private static func displayName(for locale: Locale, in uiLocale: Locale) -> String {
        uiLocale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }
}
