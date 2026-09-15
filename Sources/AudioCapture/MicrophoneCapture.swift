import AVFoundation

/// Captures the microphone via AVAudioEngine, timestamping each buffer on the same
/// host time clock as the system tap — this is what makes it possible to align the
/// two tracks.
public final class MicrophoneCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<TimedAudioBuffer>.Continuation?

    public private(set) var format: AVAudioFormat?
    /// Indicates whether echo cancellation could be enabled on this device.
    public private(set) var echoCancellationEnabled = false

    public init() {}

    public static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    public func start() throws -> AsyncStream<TimedAudioBuffer> {
        let input = engine.inputNode

        // Attempt abandoned: `setVoiceProcessingEnabled(true)` does cancel the
        // speaker echo in the microphone, but Apple's voice processing takes
        // ownership of the output device and starves the aggregate device of its
        // source — the system tap drops to ~30,000 frames instead of 900,000
        // (measured). Cross-talk is therefore handled downstream, at the
        // transcript level, by `CrossTalkFilter`.
        echoCancellationEnabled = false

        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw CoreAudioError(status: kAudio_ParamError, context: "aucun périphérique d'entrée disponible")
        }
        format = inputFormat

        let (stream, continuation) = AsyncStream<TimedAudioBuffer>.makeStream(
            bufferingPolicy: .bufferingNewest(512)
        )
        self.continuation = continuation

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, time in
            guard let copy = buffer.copied() else { return }
            // `time.hostTime` is only valid if the clock is valid; otherwise we
            // fall back to the current instant, at the cost of buffer-sized imprecision.
            let hostTime = time.isHostTimeValid ? time.hostTime : AudioClock.now
            continuation.yield(TimedAudioBuffer(buffer: copy, hostTime: hostTime))
        }

        engine.prepare()
        try engine.start()
        return stream
    }

    public func stop() {
        continuation?.finish()
        continuation = nil
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
    }

    deinit { stop() }
}
