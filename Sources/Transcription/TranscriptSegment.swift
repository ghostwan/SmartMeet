import AudioCapture
import Foundation

/// Un morceau de transcript attribué à une piste, daté sur l'horloge de session.
public struct TranscriptSegment: Sendable, Codable, Identifiable, Equatable {
    public let id: UUID
    public let track: AudioTrack
    public let start: TimeInterval
    public let end: TimeInterval
    public let text: String

    public init(
        id: UUID = UUID(),
        track: AudioTrack,
        start: TimeInterval,
        end: TimeInterval,
        text: String
    ) {
        self.id = id
        self.track = track
        self.start = start
        self.end = end
        self.text = text
    }

    public var speaker: String { track.speakerLabel }

    public var timecode: String {
        let total = Int(start.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// Résultat courant d'une piste : le texte en cours de reconnaissance, non figé.
public struct VolatileTranscript: Sendable, Equatable {
    public let track: AudioTrack
    public let text: String

    public init(track: AudioTrack, text: String) {
        self.track = track
        self.text = text
    }
}

/// Ce que le transcripteur émet au fil de l'eau.
public enum TranscriptEvent: Sendable {
    /// Segment finalisé, ne bougera plus.
    case finalized(TranscriptSegment)
    /// Texte provisoire, destiné à l'affichage live uniquement.
    case volatile(VolatileTranscript)
}
