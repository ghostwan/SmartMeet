import AudioCapture
import Foundation

/// Orchestrates both transcribers and maintains the merged transcript.
///
/// The physical separation of the tracks stands in for diarization: anything
/// coming from the microphone is the user, anything coming from the system tap
/// is a remote participant.
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
            // Ordered insertion: the two tracks arrive interleaved.
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

    /// Ends the analyses and returns the final transcript.
    public func finish() async -> [TranscriptSegment] {
        await microphone.finish()
        await systemAudio.finish()
        // Let the last finalized results come through before closing.
        try? await Task.sleep(for: .milliseconds(500))
        relays.forEach { $0.cancel() }
        relays.removeAll()
        continuation?.finish()
        continuation = nil
        return crossTalkFilter.apply(to: segments)
    }
}

/// Snapshot of the transcript sent to the UI.
public struct TranscriptUpdate: Sendable {
    public let segments: [TranscriptSegment]
    public let volatile: [AudioTrack: String]

    public init(segments: [TranscriptSegment], volatile: [AudioTrack: String]) {
        self.segments = segments
        self.volatile = volatile
    }
}

public extension Array where Element == TranscriptSegment {
    /// Markdown rendering of the transcript, with speaker and timestamp.
    func markdown(title: String, date: Date) -> String {
        var output = "# \(title)\n\n"
        output += "Date : \(date.formatted(date: .abbreviated, time: .shortened))\n\n"
        for segment in self {
            output += "**[\(segment.timecode)] \(segment.speaker) :** \(segment.text)\n\n"
        }
        return output
    }
}
