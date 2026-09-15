import Foundation
import Testing

@testable import Summarization

@Suite("Provider Claude Code")
struct ClaudeCodeProviderTests {
    @Test("Le libellé combine le nom du provider et le modèle")
    func displayName() {
        let provider = ClaudeCodeProvider(model: "opus")
        #expect(provider.displayName == "Claude Code · opus")
    }

    @Test("Un exécutable introuvable est signalé sans lancer le process")
    func unavailableWhenExecutableMissing() async {
        let provider = ClaudeCodeProvider(
            model: "sonnet",
            executableURL: URL(filePath: "/nonexistent/claude")
        )
        #expect(await provider.isAvailable() == false)
        await #expect(throws: SummaryProviderError.self) {
            _ = try await provider.complete(prompt: "test")
        }
    }

    @Test("Le résultat d'un tour réussi est extrait du champ result")
    func parsesSuccessfulResult() throws {
        let json = #"""
        {"type":"result","subtype":"success","is_error":false,"result":"Bonjour","usage":{"input_tokens":120,"output_tokens":42,"cache_creation_input_tokens":10,"cache_read_input_tokens":5}}
        """#
        let completion = try ClaudeCodeProvider.parseResult(json)
        #expect(completion.text == "Bonjour")
        #expect(completion.usage?.input == 120)
        #expect(completion.usage?.output == 42)
        #expect(completion.usage?.cacheWrite == 10)
        #expect(completion.usage?.cacheRead == 5)
    }

    @Test("Un tour signalé en erreur lève une erreur plutôt que de renvoyer un texte vide")
    func errorResultThrows() {
        let json = #"{"type":"result","is_error":true,"result":"limite de crédits atteinte"}"#
        #expect(throws: SummaryProviderError.self) {
            _ = try ClaudeCodeProvider.parseResult(json)
        }
    }

    @Test("Un JSON illisible retombe sur le texte brut plutôt que d'échouer")
    func unparseableJSONFallsBackToRawText() throws {
        let raw = "sortie inattendue, pas du JSON"
        let completion = try ClaudeCodeProvider.parseResult(raw)
        #expect(completion.text == raw)
        #expect(completion.usage == nil)
    }

    @Test("Le décompte de tokens suit le schéma de l'API Anthropic")
    func usageMapping() {
        let usage = ClaudeCodeProvider.usage(from: [
            "input_tokens": 500,
            "output_tokens": 88,
            "cache_creation_input_tokens": 30,
            "cache_read_input_tokens": 15,
        ])
        #expect(usage.input == 500)
        #expect(usage.output == 88)
        #expect(usage.cacheWrite == 30)
        #expect(usage.cacheRead == 15)
        #expect(usage.reasoning == nil)
    }
}
