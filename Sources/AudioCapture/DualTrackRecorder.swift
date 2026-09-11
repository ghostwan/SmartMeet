import AVFoundation

/// Un tampon rapporté à l'horloge de la session : `offset` est le décalage en secondes
/// depuis le début de l'enregistrement, commun aux deux pistes.
public struct TrackBuffer: @unchecked Sendable {
    public let track: AudioTrack
    public let buffer: AVAudioPCMBuffer
    public let offset: TimeInterval
}

/// Ce qu'il reste d'une session une fois l'enregistrement arrêté.
public struct RecordingResult: Sendable {
    public let directory: URL
    public let duration: TimeInterval
    /// Décalage réel du premier tampon de chaque piste. Les deux captures ne démarrent
    /// pas au même instant (~180 ms d'écart mesurés) : sans cette correction, les
    /// horodatages du transcript dérivent d'une piste à l'autre.
    public let trackStartOffsets: [AudioTrack: TimeInterval]
    public let frameCounts: [AudioTrack: AVAudioFramePosition]
}

/// Pilote les deux captures, écrit les fichiers audio et expose un flux unifié
/// pour la transcription temps réel.
public actor DualTrackRecorder {
    private let microphone = MicrophoneCapture()
    private let systemAudio = SystemAudioTap()

    private var sessionStartHostTime: UInt64 = 0
    private var directory: URL?
    private var files: [AudioTrack: AVAudioFile] = [:]
    private var trackStartOffsets: [AudioTrack: TimeInterval] = [:]
    private var frameCounts: [AudioTrack: AVAudioFramePosition] = [:]
    private var pumps: [Task<Void, Never>] = []

    public init() {}

    /// Vrai si l'annulation d'écho a pu être activée sur la piste micro.
    public var echoCancellationEnabled: Bool { microphone.echoCancellationEnabled }

    /// Démarre les deux captures et renvoie le flux fusionné des tampons datés.
    public func start(directory: URL) throws -> AsyncStream<TrackBuffer> {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        files.removeAll()
        trackStartOffsets.removeAll()
        frameCounts.removeAll()

        // Une seule référence temporelle, prise avant tout démarrage.
        sessionStartHostTime = AudioClock.now

        // Le tap système d'abord : c'est lui qui peut échouer (TCC, périphérique).
        let systemStream = try systemAudio.start()
        let microphoneStream: AsyncStream<TimedAudioBuffer>
        do {
            microphoneStream = try microphone.start()
        } catch {
            systemAudio.stop()
            throw error
        }

        let (merged, continuation) = AsyncStream<TrackBuffer>.makeStream(
            bufferingPolicy: .bufferingNewest(1024)
        )

        // Une tâche par piste : elles alimentent le même flux fusionné.
        let sources: [(AudioTrack, AsyncStream<TimedAudioBuffer>)] = [
            (.system, systemStream),
            (.microphone, microphoneStream),
        ]
        let expected = sources.count
        let finished = FinishCounter(expected: expected, continuation: continuation)

        pumps = sources.map { track, stream in
            Task { [weak self] in
                for await timed in stream {
                    guard let self else { break }
                    if let trackBuffer = await self.ingest(timed, track: track) {
                        continuation.yield(trackBuffer)
                    }
                }
                await finished.signal()
            }
        }

        return merged
    }

    /// Écrit le tampon sur disque et le rapporte à l'horloge de session.
    private func ingest(_ timed: TimedAudioBuffer, track: AudioTrack) -> TrackBuffer? {
        let offset = AudioClock.interval(from: sessionStartHostTime, to: timed.hostTime)

        if trackStartOffsets[track] == nil {
            trackStartOffsets[track] = offset
        }

        do {
            let file = try fileFor(track: track, format: timed.buffer.format)
            try file.write(from: timed.buffer)
            frameCounts[track, default: 0] += AVAudioFramePosition(timed.buffer.frameLength)
        } catch {
            // Une écriture ratée ne doit pas interrompre la transcription en cours.
            NSLog("SmartMeet: écriture de la piste \(track.rawValue) impossible — \(error)")
        }

        return TrackBuffer(track: track, buffer: timed.buffer, offset: offset)
    }

    private func fileFor(track: AudioTrack, format: AVAudioFormat) throws -> AVAudioFile {
        if let existing = files[track] { return existing }
        guard let directory else {
            throw CoreAudioError(status: kAudio_ParamError, context: "dossier de session absent")
        }
        let file = try AVAudioFile(
            forWriting: directory.appending(path: track.fileName),
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        files[track] = file
        return file
    }

    public func stop() async -> RecordingResult {
        let duration = AudioClock.interval(from: sessionStartHostTime, to: AudioClock.now)

        // Arrêter les captures clôt les flux ; les tâches de pompage s'achèvent alors
        // d'elles-mêmes après avoir écrit les derniers tampons. Les annuler ici
        // tronquait les fichiers à leur en-tête (constaté sur la piste système).
        microphone.stop()
        systemAudio.stop()
        for pump in pumps { await pump.value }
        pumps.removeAll()

        // Libérer les AVAudioFile déclenche leur vidage sur disque.
        files.removeAll()

        return RecordingResult(
            directory: directory ?? URL(filePath: NSTemporaryDirectory()),
            duration: duration,
            trackStartOffsets: trackStartOffsets,
            frameCounts: frameCounts
        )
    }
}

/// Ne clôt le flux fusionné qu'une fois les deux pistes taries.
private actor FinishCounter {
    private var remaining: Int
    private let continuation: AsyncStream<TrackBuffer>.Continuation

    init(expected: Int, continuation: AsyncStream<TrackBuffer>.Continuation) {
        self.remaining = expected
        self.continuation = continuation
    }

    func signal() {
        remaining -= 1
        if remaining <= 0 { continuation.finish() }
    }
}
