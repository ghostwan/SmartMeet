import AVFoundation

/// Capture le micro via AVAudioEngine, en datant chaque tampon sur la même horloge
/// host time que le tap système — c'est ce qui permet d'aligner les deux pistes.
public final class MicrophoneCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<TimedAudioBuffer>.Continuation?

    public private(set) var format: AVAudioFormat?
    /// Indique si l'annulation d'écho a pu être activée sur ce périphérique.
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

        // Tentative écartée : `setVoiceProcessingEnabled(true)` annule bien l'écho des
        // haut-parleurs dans le micro, mais le traitement de voix d'Apple s'approprie
        // le périphérique de sortie et prive le périphérique agrégé de sa source — le
        // tap système tombe à ~30 000 frames au lieu de 900 000 (mesuré).
        // La diaphonie est donc traitée en aval, au niveau du transcript, par
        // `CrossTalkFilter`.
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
            // `time.hostTime` n'est renseigné que si l'horloge est valide ; sinon on
            // retombe sur l'instant courant, au prix d'une imprécision de l'ordre du tampon.
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
