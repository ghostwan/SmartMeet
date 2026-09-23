import AVFoundation

/// A buffer indexed on the session clock: `offset` is the delay in seconds
/// since the start of the recording, shared by both tracks.
public struct TrackBuffer: @unchecked Sendable {
    public let track: AudioTrack
    public let buffer: AVAudioPCMBuffer
    public let offset: TimeInterval
}

/// What remains of a session once recording has stopped.
public struct RecordingResult: Sendable {
    public let directory: URL
    public let duration: TimeInterval
    /// Actual start offset of the first buffer of each track. The two captures don't
    /// start at exactly the same instant (~180ms gap measured): without this
    /// correction, the transcript's timestamps drift from one track to the other.
    public let trackStartOffsets: [AudioTrack: TimeInterval]
    public let frameCounts: [AudioTrack: AVAudioFramePosition]
}

/// Drives both captures, writes the audio files, and exposes a unified stream
/// for real-time transcription.
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

    /// True if echo cancellation could be enabled on the microphone track.
    public var echoCancellationEnabled: Bool { microphone.echoCancellationEnabled }

    /// Starts both captures and returns the merged stream of timestamped buffers.
    public func start(directory: URL) throws -> AsyncStream<TrackBuffer> {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        files.removeAll()
        trackStartOffsets.removeAll()
        frameCounts.removeAll()

        // A single time reference, taken before either capture starts.
        sessionStartHostTime = AudioClock.now

        return try beginCapture()
    }

    /// Releases both hardware captures (microphone engine, system tap)
    /// without finalizing the session: the audio files stay open, and the
    /// session clock (`sessionStartHostTime`) is untouched, ready to accept
    /// more buffers if `resume()` is called. Used when a meeting looks like
    /// it might be over but could still resume (a network drop, a call put
    /// on hold): pausing avoids capturing and transcribing dead air
    /// indefinitely without losing the session or forcing a fresh one.
    public func pause() async {
        microphone.stop()
        systemAudio.stop()
        for pump in pumps { await pump.value }
        pumps.removeAll()
    }

    /// Restarts both hardware captures after `pause()`, still writing into
    /// the same files and indexed on the same session clock — only the gap
    /// itself goes unrecorded. Returns a brand-new merged stream; the caller
    /// must resubscribe to it (the previous one has already finished).
    public func resume() throws -> AsyncStream<TrackBuffer> {
        try beginCapture()
    }

    /// Shared by `start()` and `resume()`: starts both hardware captures and
    /// wires the pump tasks that feed the merged stream and write to disk.
    private func beginCapture() throws -> AsyncStream<TrackBuffer> {
        // The system tap first: it's the one that can fail (TCC, device).
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

        // One task per track: they both feed the same merged stream.
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

    /// Writes the buffer to disk and indexes it on the session clock.
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
            // A failed write must not interrupt the ongoing transcription.
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

        // Stopping the captures closes their streams; the pump tasks then finish
        // on their own after writing the last buffers. Cancelling them here used
        // to truncate the files down to their header (observed on the system track).
        microphone.stop()
        systemAudio.stop()
        for pump in pumps { await pump.value }
        pumps.removeAll()

        // Releasing the AVAudioFile instances triggers their flush to disk.
        files.removeAll()

        return RecordingResult(
            directory: directory ?? URL(filePath: NSTemporaryDirectory()),
            duration: duration,
            trackStartOffsets: trackStartOffsets,
            frameCounts: frameCounts
        )
    }
}

/// Only closes the merged stream once both tracks have run dry.
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
