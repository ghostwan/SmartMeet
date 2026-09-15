import Foundation
import Testing

@testable import Summarization

@Suite("Provider ACP Copilot")
struct CopilotACPProviderTests {
    @Test("Le libellé combine le nom du provider et le modèle")
    func displayName() {
        let provider = CopilotACPProvider(model: "gpt-5-mini")
        #expect(provider.displayName == "copilot · gpt-5-mini")
    }

    @Test("Un exécutable introuvable est signalé sans lancer le process")
    func unavailableWhenExecutableMissing() async {
        let provider = CopilotACPProvider(
            model: "claude-sonnet-5",
            executableURL: URL(filePath: "/nonexistent/copilot")
        )
        #expect(await provider.isAvailable() == false)
        await #expect(throws: SummaryProviderError.self) {
            _ = try await provider.complete(prompt: "test")
        }
    }

    @Test("Seuls les fragments de type agent_message_chunk sont retenus")
    func textChunkExtraction() {
        let chunk = ACPSession.textChunk(from: [
            "sessionUpdate": "agent_message_chunk",
            "content": ["type": "text", "text": "Bonjour"],
        ])
        #expect(chunk == "Bonjour")

        // Other update types (plan, tool_call, usage_update…) don't carry
        // response text and must be ignored.
        #expect(ACPSession.textChunk(from: ["sessionUpdate": "usage_update"]) == nil)
        #expect(ACPSession.textChunk(from: ["sessionUpdate": "plan", "entries": []]) == nil)
    }

    @Test("Le décompte de tokens ACP est traduit vers TokenUsage")
    func usageMapping() {
        let usage = ACPSession.usage(from: [
            "inputTokens": 39926,
            "outputTokens": 67,
            "totalTokens": 39993,
            "thoughtTokens": 0,
            "cachedReadTokens": 12,
            "cachedWriteTokens": 340,
        ])
        #expect(usage.input == 39926)
        #expect(usage.output == 67)
        #expect(usage.reasoning == 0)
        #expect(usage.cacheRead == 12)
        #expect(usage.cacheWrite == 340)
    }

    @Test("Une demande de permission est toujours refusée, jamais approuvée")
    func permissionRequestsAreAlwaysRejected() {
        let optionId = ACPSession.rejectOptionId(among: [
            ["optionId": "allow-once", "kind": "allow_once"],
            ["optionId": "reject-once", "kind": "reject_once"],
        ])
        #expect(optionId == "reject-once")
    }

    @Test("Sans option de refus explicite, le tour est annulé plutôt qu'approuvé")
    func permissionRequestFallsBackToCancellationWhenNoRejectOption() {
        let optionId = ACPSession.rejectOptionId(among: [
            ["optionId": "allow-once", "kind": "allow_once"],
            ["optionId": "allow-always", "kind": "allow_always"],
        ])
        #expect(optionId == nil)
    }
}
