import Foundation
import Testing

@testable import Summarization

@Suite("Attribution des propos aux participants confirmés")
struct SummaryContextParticipantsTests {
    @Test("Sans participants confirmés, seul l'indice calendrier (facultatif) apparaît")
    func noConfirmedParticipantsOmitsStrongInstruction() {
        let prompt = SummaryPrompt.instructions(
            context: SummaryContext(), template: .generic, language: .french
        )
        #expect(!prompt.contains("EXACTEMENT ces personnes"))
    }

    @Test("Les participants confirmés sont listés avec une consigne d'attribution stricte")
    func confirmedParticipantsProduceStrongInstruction() {
        let prompt = SummaryPrompt.instructions(
            context: SummaryContext(confirmedParticipants: ["Sandra", "Alex"]),
            template: .generic,
            language: .french
        )
        #expect(prompt.contains("Sandra, Alex"))
        #expect(prompt.contains("EXACTEMENT ces personnes"))
        #expect(prompt.contains("jamais à « Participants »"))
    }

    @Test("La consigne d'attribution stricte suit la langue du compte rendu")
    func confirmedParticipantsInstructionFollowsLanguage() {
        let prompt = SummaryPrompt.instructions(
            context: SummaryContext(confirmedParticipants: ["Sandra", "Alex"]),
            template: .generic,
            language: .english
        )
        #expect(prompt.contains("Sandra, Alex"))
        #expect(prompt.contains("EXACTLY these people"))
        #expect(prompt.contains("never to \"Participants\""))
    }

    @Test("Les participants confirmés et les participants du calendrier peuvent coexister dans le prompt")
    func confirmedParticipantsCoexistWithKnownAttendees() {
        let prompt = SummaryPrompt.instructions(
            context: SummaryContext(
                knownAttendees: ["Bob"],
                confirmedParticipants: ["Sandra", "Alex"]
            ),
            template: .generic,
            language: .french
        )
        #expect(prompt.contains("Bob"))
        #expect(prompt.contains("Sandra, Alex"))
    }
}
