import AVFoundation
import CoreAudio

/// Un tampon audio daté sur l'horloge système (host time), seule référence commune
/// aux deux chaînes de capture : `AVAudioEngine` et l'IOProc Core Audio.
public struct TimedAudioBuffer: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer
    /// Date de la première frame, en host time Mach.
    public let hostTime: UInt64

    public init(buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        self.buffer = buffer
        self.hostTime = hostTime
    }
}

public enum AudioClock {
    /// Convertit une durée en host time vers des secondes.
    public static func seconds(fromHostTimeDelta delta: UInt64) -> TimeInterval {
        TimeInterval(AudioConvertHostTimeToNanos(delta)) / 1_000_000_000
    }

    /// Écart signé entre deux instants host time, en secondes.
    public static func interval(from start: UInt64, to end: UInt64) -> TimeInterval {
        end >= start
            ? seconds(fromHostTimeDelta: end - start)
            : -seconds(fromHostTimeDelta: start - end)
    }

    public static var now: UInt64 { AudioGetCurrentHostTime() }
}

/// Identifie l'origine d'une piste, ce qui tient lieu de diarisation :
/// les deux sources sont physiquement séparées.
public enum AudioTrack: String, Sendable, Codable, CaseIterable {
    case microphone
    case system

    /// Libellé affiché dans le transcript.
    public var speakerLabel: String {
        switch self {
        case .microphone: "Moi"
        case .system: "Participants"
        }
    }

    public var fileName: String {
        switch self {
        case .microphone: "microphone.caf"
        case .system: "system.caf"
        }
    }
}
