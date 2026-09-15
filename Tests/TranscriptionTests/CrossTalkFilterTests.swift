import AudioCapture
import Foundation
import Testing

@testable import Transcription

@Suite("Filtre de diaphonie")
struct CrossTalkFilterTests {
    private let filter = CrossTalkFilter()

    private func segment(
        _ track: AudioTrack,
        _ start: TimeInterval,
        _ end: TimeInterval,
        _ text: String
    ) -> TranscriptSegment {
        TranscriptSegment(track: track, start: start, end: end, text: text)
    }

    @Test("Supprime l'écho du micro quand le même propos est sur la piste système")
    func removesEcho() {
        let segments = [
            segment(.system, 4, 10, "Bonjour à tous, je propose qu'on commence par le point sur la migration"),
            segment(.microphone, 4.2, 10.1, "Bonjour à tous je propose qu'on commence par le point sur la migration"),
        ]
        let filtered = filter.apply(to: segments)
        #expect(filtered.count == 1)
        #expect(filtered.first?.track == .system)
    }

    @Test("Conserve la parole de l'utilisateur, absente de la piste système")
    func keepsUserSpeech() {
        let segments = [
            segment(.system, 4, 10, "Il reste la validation des traductions pour vendredi"),
            segment(.microphone, 11, 14, "Sandra, tu penses pouvoir boucler ça pour vendredi ?"),
        ]
        let filtered = filter.apply(to: segments)
        #expect(filtered.count == 2)
    }

    @Test("Détecte l'écho même quand la piste système regroupe plusieurs phrases")
    func detectsEchoInsideLongerSegment() {
        // Real-world case: the system track merges two sentences, the mic track
        // separates them. A Jaccard index would fail here, the overlap measure won't.
        let long = "Bonjour à tous je propose qu'on commence par la migration. "
            + "D'accord j'ai terminé l'intégration il reste la validation des traductions pour vendredi"
        let segments = [
            segment(.system, 4, 18, long),
            segment(.microphone, 12, 17, "j'ai terminé l'intégration il reste la validation des traductions"),
        ]
        let filtered = filter.apply(to: segments)
        #expect(filtered.count == 1)
        #expect(filtered.first?.track == .system)
    }

    @Test("N'agit pas sur des propos éloignés dans le temps")
    func ignoresDistantSegments() {
        let text = "Il reste la validation des traductions pour vendredi"
        let segments = [
            segment(.system, 4, 10, text),
            segment(.microphone, 300, 306, text),
        ]
        #expect(filter.apply(to: segments).count == 2)
    }

    @Test("Ne touche à rien en l'absence de piste système")
    func noSystemTrack() {
        let segments = [
            segment(.microphone, 0, 3, "Premier point"),
            segment(.microphone, 4, 7, "Deuxième point"),
        ]
        #expect(filter.apply(to: segments).count == 2)
    }

    @Test("Le recouvrement est insensible à la casse et aux accents")
    func containmentNormalises() {
        let score = filter.containment(
            of: "integration des traductions",
            in: "j'ai terminé l'intégration des traductions pour vendredi"
        )
        #expect(score == 1.0)
    }
}

@Suite("Rendu markdown du transcript")
struct TranscriptMarkdownTests {
    @Test("Le transcript porte locuteur et horodatage")
    func rendersSpeakerAndTimecode() {
        let segments = [
            TranscriptSegment(track: .microphone, start: 5, end: 8, text: "Bonjour"),
            TranscriptSegment(track: .system, start: 65, end: 70, text: "Salut"),
        ]
        let markdown = segments.markdown(title: "Réunion", date: Date(timeIntervalSince1970: 0))
        #expect(markdown.contains("**[00:05] Moi :** Bonjour"))
        #expect(markdown.contains("**[01:05] Participants :** Salut"))
    }
}
