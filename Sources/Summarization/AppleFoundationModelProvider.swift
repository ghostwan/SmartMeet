import Foundation
import FoundationModels

/// Uses Apple Intelligence's on-device model (`FoundationModels`, macOS 26+):
/// fully on-device, no data leaves the machine, no external binary to install
/// or authenticate (unlike `ollama` or `copilot`).
///
/// Trade-off measured empirically (undocumented by Apple): a context window of
/// roughly 4096 tokens, much narrower than other providers'.
/// `maxPromptCharacters` reflects this so that `SummaryGenerator` splits into
/// noticeably smaller chunks — this provider is suited to short meetings or
/// map-reduce chunks, not a one-hour meeting sent as a single block.
public struct AppleFoundationModelProvider: SummaryProvider {
    public var displayName: String { "Apple Intelligence (local)" }

    public init() {}

    public func isAvailable() async -> Bool {
        SystemLanguageModel.default.isAvailable
    }

    /// ~4096 tokens of measured context window, shared between instructions,
    /// JSON schema and transcript sent in the same prompt, plus the expected
    /// response. 6000 characters of transcript leaves margin for the rest,
    /// experimentally found sufficient to stay within the limit.
    public var maxPromptCharacters: Int? { 6_000 }

    public func complete(prompt: String) async throws -> SummaryCompletion {
        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            throw SummaryProviderError.serverUnreachable(Self.unavailabilityReason(model.availability))
        }

        let session = LanguageModelSession()
        do {
            let response = try await session.respond(
                to: prompt,
                options: GenerationOptions(temperature: 0.2)
            )
            let text = response.content
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SummaryProviderError.emptyResponse
            }
            return SummaryCompletion(text: text, usage: await Self.usage(prompt: prompt, response: text, model: model))
        } catch let error as SummaryProviderError {
            throw error
        } catch {
            throw SummaryProviderError.processFailed(error.localizedDescription)
        }
    }

    private static func unavailabilityReason(_ availability: SystemLanguageModel.Availability) -> String {
        guard case .unavailable(let reason) = availability else { return "Apple Intelligence" }
        switch reason {
        case .deviceNotEligible:
            return "Apple Intelligence (appareil non compatible)"
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence (non activé dans Réglages Système)"
        case .modelNotReady:
            return "Apple Intelligence (modèle en cours de préparation)"
        @unknown default:
            return "Apple Intelligence"
        }
    }

    /// Token count isn't returned by `respond(to:)`: it's measured afterward
    /// via `tokenCount(for:)`, available only since macOS 26.4. On an earlier
    /// version, usage simply comes back as `nil` — same as `ollama` when a
    /// field isn't provided.
    private static func usage(
        prompt: String, response: String, model: SystemLanguageModel
    ) async -> TokenUsage? {
        guard #available(macOS 26.4, *) else { return nil }
        guard let input = try? await model.tokenCount(for: prompt),
              let output = try? await model.tokenCount(for: response)
        else { return nil }
        return TokenUsage(input: input, output: output)
    }
}
