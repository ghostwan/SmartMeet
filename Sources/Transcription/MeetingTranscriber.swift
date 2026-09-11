import AudioCapture
import Foundation

/// Orchestre les deux transcripteurs et entretient le transcript fusionné.
///
/// La séparation physique des pistes tient lieu de diarisation : tout ce qui vient du
/// micro est l'utilisateur, tout ce qui vient du tap système est un participant distant.
public actor MeetingTranscriber {
    private let microphone: TrackTranscriber
    private let systemAudio: TrackTranscriber

    private let crossTalkFilter = CrossTalkFilter()
    private var segments: [TranscriptSegment] = []
    private var volatileByTrack: [AudioTrack: String] = [:]
    private var continuation: AsyncStream<TranscriptUpdate>.Continuation?
    private var relays: [Task<Void, Never>] = []

    public init(locale: Locale, vocabulary: [String] = []) {
        microphone = TrackTranscriber(track: .microphone, locale: locale, vocabulary: vocabulary)
        systemAudio = TrackTranscriber(track: .system, locale: locale, vocabulary: vocabulary)
    }

    public func start() async throws -> AsyncStream<TranscriptUpdate> {
        let microphoneEvents = try await microphone.start()
        let systemEvents = try await systemAudio.start()

        let (updates, continuation) = AsyncStream<TranscriptUpdate>.makeStream()
        self.continuation = continuation

        relays = [microphoneEvents, systemEvents].map { events in
            Task { [weak self] in
                for await event in events {
                    await self?.handle(event)
                }
            }
        }
        return updates
    }

    private func handle(_ event: TranscriptEvent) {
        switch event {
        case .finalized(let segment):
            // Insertion ordonnée : les deux pistes arrivent de façon entrelacée.
            let index = segments.firstIndex { $0.start > segment.start } ?? segments.endIndex
            segments.insert(segment, at: index)
            volatileByTrack[segment.track] = nil
        case .volatile(let volatile):
            volatileByTrack[volatile.track] = volatile.text
        }
        continuation?.yield(TranscriptUpdate(
            segments: crossTalkFilter.apply(to: segments),
            volatile: volatileByTrack
        ))
    }

    public func append(_ trackBuffer: TrackBuffer) async {
        switch trackBuffer.track {
        case .microphone: await microphone.append(trackBuffer)
        case .system: await systemAudio.append(trackBuffer)
        }
    }

    /// Termine les analyses et renvoie le transcript définitif.
    public func finish() async -> [TranscriptSegment] {
        await microphone.finish()
        await systemAudio.finish()
        // Laisse les derniers résultats finalisés remonter avant de clore.
        try? await Task.sleep(for: .milliseconds(500))
        relays.forEach { $0.cancel() }
        relays.removeAll()
        continuation?.finish()
        continuation = nil
        return crossTalkFilter.apply(to: segments)
    }
}

/// Instantané du transcript envoyé à l'interface.
public struct TranscriptUpdate: Sendable {
    public let segments: [TranscriptSegment]
    public let volatile: [AudioTrack: String]

    public init(segments: [TranscriptSegment], volatile: [AudioTrack: String]) {
        self.segments = segments
        self.volatile = volatile
    }
}

public extension Array where Element == TranscriptSegment {
    /// Rendu markdown du transcript, avec locuteur et horodatage.
    func markdown(title: String, date: Date) -> String {
        var output = "# \(title)\n\n"
        output += "Date : \(date.formatted(date: .abbreviated, time: .shortened))\n\n"
        for segment in self {
            output += "**[\(segment.timecode)] \(segment.speaker) :** \(segment.text)\n\n"
        }
        return output
    }
}
