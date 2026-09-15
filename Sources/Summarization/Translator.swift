import Foundation

/// Translates a short piece of text into English using the LLM provider
/// already configured for summarization.
///
/// Jira tickets are always created in English, regardless of the minutes'
/// language: a distributed team shares an English-language Jira board even
/// when the minutes themselves are written in French.
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
