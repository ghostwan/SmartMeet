import AVFoundation
import CoreAudio

/// An audio buffer timestamped on the system clock (host time), the only reference
/// shared by both capture chains: `AVAudioEngine` and the Core Audio IOProc.
public struct TimedAudioBuffer: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer
    /// Timestamp of the first frame, in Mach host time.
    public let hostTime: UInt64

    public init(buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        self.buffer = buffer
        self.hostTime = hostTime
    }
}

public enum AudioClock {
    /// Converts a host time duration into seconds.
    public static func seconds(fromHostTimeDelta delta: UInt64) -> TimeInterval {
        TimeInterval(AudioConvertHostTimeToNanos(delta)) / 1_000_000_000
    }

    /// Signed difference between two host time instants, in seconds.
    public static func interval(from start: UInt64, to end: UInt64) -> TimeInterval {
        end >= start
            ? seconds(fromHostTimeDelta: end - start)
            : -seconds(fromHostTimeDelta: start - end)
    }

    public static var now: UInt64 { AudioGetCurrentHostTime() }
}

/// Identifies the origin of a track, which stands in for diarization: the two
/// sources are physically separate.
public enum AudioTrack: String, Sendable, Codable, CaseIterable {
    case microphone
    case system

    /// Label shown in the transcript.
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
