import Foundation
import Speech

/// Expose les locales que le framework `Speech` sait transcrire nativement sur la
/// machine, pour construire une liste dynamique plutôt qu'une liste figée dans
/// l'interface — sans ça, une langue supportée par macOS mais oubliée du code reste
/// invisible pour l'utilisateur.
public enum SupportedTranscriptionLocales {
    /// Toutes les locales reconnues par `SpeechTranscriber`, triées par nom lisible
    /// dans la locale de l'utilisateur (ex. « Chinois (Chine continentale) »).
    public static func all(displayIn uiLocale: Locale = .current) async -> [(id: String, label: String)] {
        let locales = await SpeechTranscriber.supportedLocales
        return locales
            .map { locale in (id: locale.identifier, label: displayName(for: locale, in: uiLocale)) }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    /// Identifiant exact reconnu par le framework pour une locale donnée, quand elle
    /// existe (utilisé pour migrer un identifiant stocké dans un format différent,
    /// ex. `fr-FR` vers `fr_FR`).
    public static func resolvedIdentifier(for locale: Locale) async -> String? {
        await SpeechTranscriber.supportedLocale(equivalentTo: locale)?.identifier
    }

    private static func displayName(for locale: Locale, in uiLocale: Locale) -> String {
        uiLocale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }
}
