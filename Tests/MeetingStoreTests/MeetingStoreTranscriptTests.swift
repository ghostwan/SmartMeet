import Foundation
import Summarization
import Testing
import Transcription

@testable import MeetingStore

@Suite("Édition manuelle du transcript")
struct MeetingStoreTranscriptTests {
    private func makeStore() -> (MeetingStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "MeetingStoreTranscriptTests-\(UUID().uuidString)")
        return (MeetingStore(root: root), root)
    }

    @Test("Le texte corrigé remplace le transcript lu par la génération, sans toucher aux segments")
    func updateTranscriptTextOverwritesOnlyTheReadableTranscript() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let meeting = Meeting(id: UUID(), title: "Daily", startedAt: .now, duration: 300, locale: "fr-FR")
        let segments = [
            TranscriptSegment(track: .microphone, start: 0, end: 1, text: "Bonjour")
        ]
        try store.save(meeting, segments: segments)

        try store.updateTranscriptText("Bonjour à tous, corrigé", for: meeting.id)

        #expect(store.transcriptMarkdown(for: meeting.id) == "Bonjour à tous, corrigé")
        // Segments untouched: a later re-diarization still has its original source.
        #expect(store.loadSegments(for: meeting.id) == segments)
    }

    @Test("Le texte corrigé est créé même si le transcript n'existait pas encore")
    func updateTranscriptTextCreatesTheFileWhenMissing() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let id = UUID()
        try store.updateTranscriptText("Texte tapé à la main", for: id)

        #expect(store.transcriptMarkdown(for: id) == "Texte tapé à la main")
    }
}
