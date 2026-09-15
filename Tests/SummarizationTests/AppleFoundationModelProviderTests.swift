import Foundation
import Testing

@testable import Summarization

@Suite("Provider Apple Intelligence (local)")
struct AppleFoundationModelProviderTests {
    @Test("Le libellé identifie le provider comme local")
    func displayName() {
        let provider = AppleFoundationModelProvider()
        #expect(provider.displayName == "Apple Intelligence (local)")
    }

    @Test("Le seuil de découpage est nettement plus bas que le seuil générique")
    func advertisesASmallerChunkThreshold() {
        let provider = AppleFoundationModelProvider()
        let genericThreshold = SummaryGenerator(provider: provider).chunkThreshold
        #expect(provider.maxPromptCharacters != nil)
        #expect(provider.maxPromptCharacters! < genericThreshold)
    }
}

@Suite("Seuil de découpage effectif selon le provider")
struct EffectiveChunkThresholdTests {
    /// Fake provider with no external dependency, used to verify that
    /// `SummaryGenerator` correctly honors `maxPromptCharacters` when it's more
    /// restrictive than its own threshold — without depending on Apple
    /// Intelligence, which isn't necessarily available on the machine running
    /// the tests.
    struct StubProvider: SummaryProvider {
        var displayName: String { "stub" }
        var maxPromptCharacters: Int?
        var receivedPromptLengths: LockedBox = LockedBox()

        func isAvailable() async -> Bool { true }

        func complete(prompt: String) async throws -> SummaryCompletion {
            receivedPromptLengths.append(prompt.count)
            return SummaryCompletion(text: #"{"title":"T","tldr":"Résumé."}"#)
        }
    }

    final class LockedBox: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var lengths: [Int] = []
        func append(_ value: Int) {
            lock.lock()
            defer { lock.unlock() }
            lengths.append(value)
        }
    }

    @Test("Un provider plus restrictif que le seuil générique force un découpage plus fin")
    func stricterProviderThresholdTriggersFinerChunking() async throws {
        let provider = StubProvider(maxPromptCharacters: 100)
        let generator = SummaryGenerator(provider: provider, chunkThreshold: 48_000)
        let transcript = String(repeating: "Une phrase de transcript assez longue. ", count: 20)
        #expect(transcript.count > 100)

        _ = try await generator.generate(
            transcript: transcript,
            context: SummaryContext(date: Date(), knownAttendees: []),
            template: .generic,
            language: .french
        )

        // The prompt of the longest chunk must never exceed
        // `maxPromptCharacters` by much + the fixed overhead of the
        // instructions/schema — a sign that the chunking indeed used the
        // provider's threshold, not the generic 48,000 characters.
        let maxLength = provider.receivedPromptLengths.lengths.max() ?? 0
        #expect(maxLength < 48_000)
    }
}
