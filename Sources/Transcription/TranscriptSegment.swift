import AudioCapture
import Foundation

/// Un morceau de transcript attribué à une piste, daté sur l'horloge de session.
public struct TranscriptSegment: Sendable, Codable, Identifiable, Equatable {
    public let id: UUID
    public let track: AudioTrack
    public let start: TimeInterval
    public let end: TimeInterval
    public let text: String
    /// Étiquette assignée a posteriori par la diarisation expérimentale de la piste
    /// micro (voir le module `Diarization`), quand plusieurs personnes partagent le
    /// même micro. `nil` : pas de diarisation, on retombe sur le libellé de la piste.
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

    // Décodage tolérant : les transcripts enregistrés avant l'ajout de la
    // diarisation doivent rester lisibles.
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
