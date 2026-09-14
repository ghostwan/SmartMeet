import Foundation

/// Traduit un texte court vers l'anglais avec le provider LLM déjà configuré pour la
/// synthèse.
///
/// Les tickets Jira sont toujours créés en anglais, quelle que soit la langue du
/// compte rendu : une équipe distribuée partage un board Jira en anglais même quand
/// le compte rendu lui-même est rédigé en français.
public enum Translator {
    public static func toEnglish(
        _ text: String,
        using provider: any SummaryProvider
    ) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        let prompt = """
        Translate the following text to English. Keep names, dates, acronyms and \
        technical terms unchanged. Reply with the translation only : no quotes, no \
        explanation, no surrounding text.

        --- TEXT ---

        \(trimmed)
        """
        let result = try await provider.complete(prompt: prompt)
        let cleaned = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? text : cleaned
    }
}
