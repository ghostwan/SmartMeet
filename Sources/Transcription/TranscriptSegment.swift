import AudioCapture
import Foundation

/// A piece of transcript attributed to a track, timestamped on the session clock.
public struct TranscriptSegment: Sendable, Codable, Identifiable, Equatable {
    public let id: UUID
    public let track: AudioTrack
    public let start: TimeInterval
    public let end: TimeInterval
    public let text: String
    /// Label assigned retroactively by the experimental microphone-track
    /// diarization (see the `Diarization` module), when several people share
    /// the same microphone. `nil`: no diarization, falls back to the track's label.
    public var speakerOverride: String?

    public init(
        id: UUID = UUID(),
        track: AudioTrack,
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        speakerOverride: String? = nil
    ) {
        self.id = id
        self.track = track
        self.start = start
        self.end = end
        self.text = text
        self.speakerOverride = speakerOverride
    }

    private enum CodingKeys: String, CodingKey {
        case id, track, start, end, text, speakerOverride
    }

    // Tolerant decoding: transcripts recorded before diarization was added
    // must remain readable.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        track = try container.decode(AudioTrack.self, forKey: .track)
        start = try container.decode(TimeInterval.self, forKey: .start)
        end = try container.decode(TimeInterval.self, forKey: .end)
        text = try container.decode(String.self, forKey: .text)
        speakerOverride = try container.decodeIfPresent(String.self, forKey: .speakerOverride)
    }

    public var speaker: String { speakerOverride ?? track.speakerLabel }

    public var timecode: String {
        let total = Int(start.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// Current result of a track: the text being recognized, not yet final.
public struct VolatileTranscript: Sendable, Equatable {
    public let track: AudioTrack
    public let text: String

    public init(track: AudioTrack, text: String) {
        self.track = track
        self.text = text
    }
}

/// What the transcriber emits as it goes.
public enum TranscriptEvent: Sendable {
    /// Finalized segment, won't change anymore.
    case finalized(TranscriptSegment)
    /// Provisional text, for live display only.
    case volatile(VolatileTranscript)
}
