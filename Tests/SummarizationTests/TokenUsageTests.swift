import Foundation
import Testing

@testable import Summarization

@Suite("Consommation de tokens")
struct TokenUsageTests {
    @Test("L'addition cumule chaque champ indépendamment")
    func addition() {
        let a = TokenUsage(input: 100, output: 20, costUSD: 0.01)
        let b = TokenUsage(input: 50, reasoning: 5, cacheRead: 10)
        let sum = a + b
        #expect(sum.input == 150)
        #expect(sum.output == 20)
        #expect(sum.reasoning == 5)
        #expect(sum.cacheRead == 10)
        #expect(sum.costUSD == 0.01)
    }

    @Test("Le total additionne toutes les catégories connues")
    func total() {
        let usage = TokenUsage(input: 10, output: 5, reasoning: 2, cacheWrite: 3, cacheRead: 1)
        #expect(usage.total == 21)
    }

    @Test("Le formatage affiche le coût quand il est connu")
    func formattedWithCost() {
        let usage = TokenUsage(input: 1000, output: 200, costUSD: 0.0344)
        #expect(usage.formatted.contains("1 200 tokens"))
        #expect(usage.formatted.contains("0.034"))
    }

    @Test("Le formatage se limite aux tokens sans coût connu")
    func formattedWithoutCost() {
        let usage = TokenUsage(input: 1000, output: 200)
        #expect(usage.formatted == "1 200 tokens")
    }

    @Test("UsageBox cumule les appels concurrents")
    func usageBoxAccumulates() {
        let box = UsageBox()
        box.add(TokenUsage(input: 10))
        box.add(TokenUsage(input: 5, output: 2))
        #expect(box.total?.input == 15)
        #expect(box.total?.output == 2)
    }

    @Test("Analyse des événements NDJSON d'opencode")
    func parsesOpencodeEvents() {
        let raw = """
        {"type":"step_start","part":{"type":"step-start"}}
        {"type":"text","part":{"type":"text","text":"Bonjour"}}
        {"type":"text","part":{"type":"text","text":" le monde"}}
        {"type":"step_finish","part":{"type":"step-finish","tokens":{"total":13749,"input":2,"output":4,"reasoning":0,"cache":{"write":13743,"read":0}},"cost":0.0344015}}
        """
        let completion = OpencodeProvider.parseEvents(raw)
        #expect(completion.text == "Bonjour le monde")
        #expect(completion.usage?.input == 2)
        #expect(completion.usage?.output == 4)
        #expect(completion.usage?.cacheWrite == 13743)
        #expect(completion.usage?.costUSD == 0.0344015)
    }

    @Test("Sortie non reconnue : on retombe sur le texte brut")
    func fallsBackToRawTextWhenUnparseable() {
        let raw = "réponse texte brut, pas du NDJSON"
        let completion = OpencodeProvider.parseEvents(raw)
        #expect(completion.text == raw)
        #expect(completion.usage == nil)
    }
}
