import AVFoundation
import AudioCapture
import Foundation
import Speech

/// Transcrit une piste au fil de l'eau avec `SpeechAnalyzer`.
///
/// Deux enseignements de la phase 0 sont câblés ici :
/// - un unique `AVAudioConverter` maintenu sur toute la session ; en recréer un par
///   tampon fait perdre la moitié des frames au rééchantillonnage ;
/// - les horodatages renvoyés par l'analyseur partent de zéro au premier tampon reçu,
///   d'où le `startOffset` ajouté pour revenir à l'horloge de session.
public actor TrackTranscriber {
    private let track: AudioTrack
    private let locale: Locale
    private let vocabulary: [String]

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var converter: AVAudioConverter?
    private var analysisFormat: AVAudioFormat?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    /// Décalage entre le début de la session et le premier tampon transcrit.
    private var startOffset: TimeInterval?

    public init(track: AudioTrack, locale: Locale, vocabulary: [String] = []) {
        self.track = track
        self.locale = locale
        self.vocabulary = vocabulary
    }

    /// Prépare les modèles et démarre l'analyse. Renvoie le flux d'événements.
    public func start() async throws -> AsyncStream<TranscriptEvent> {
        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionError.unavailable
        }

        let resolvedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) ?? locale
        let transcriber = SpeechTranscriber(
            locale: resolvedLocale,
            preset: .timeIndexedProgressiveTranscription
        )
        self.transcriber = transcriber

        try await Self.installAssetsIfNeeded(for: transcriber)

        guard let analysisFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]
        ) else {
            throw TranscriptionError.noCompatibleFormat
        }
        self.analysisFormat = analysisFormat

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings = [.general: vocabulary]
            try await analyzer.setContext(context)
        }

        let (events, eventsContinuation) = AsyncStream<TranscriptEvent>.makeStream()
        let track = track

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }

                    let offset = await self?.startOffset ?? 0
                    if result.isFinal {
                        eventsContinuation.yield(.finalized(TranscriptSegment(
                            track: track,
                            start: result.range.start.seconds + offset,
                            end: result.range.end.seconds + offset,
                            text: text
                        )))
                    } else {
                        eventsContinuation.yield(.volatile(
                            VolatileTranscript(track: track, text: text)
                        ))
                    }
                }
            } catch {
                NSLog("SmartMeet: transcription \(track.rawValue) interrompue — \(error)")
            }
            eventsContinuation.finish()
        }

        let (inputs, inputsContinuation) = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: .bufferingNewest(512)
        )
        continuation = inputsContinuation
        try await analyzer.start(inputSequence: inputs)

        return events
    }

    /// Pousse un tampon de la piste dans l'analyseur.
    public func append(_ trackBuffer: TrackBuffer) {
        guard trackBuffer.track == track,
              let analysisFormat,
              let continuation
        else { return }

        if startOffset == nil { startOffset = trackBuffer.offset }

        let sourceFormat = trackBuffer.buffer.format
        if converter == nil || converter?.inputFormat != sourceFormat {
            // Le périphérique peut changer en cours de réunion : on reconstruit alors
            // le convertisseur, en acceptant la discontinuité que cela implique.
            converter = AVAudioConverter(from: sourceFormat, to: analysisFormat)
        }
        guard let converter else { return }

        let ratio = analysisFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(trackBuffer.buffer.frameLength) * ratio) + 1024
        guard let converted = AVAudioPCMBuffer(pcmFormat: analysisFormat, frameCapacity: capacity)
        else { return }

        let pending = PendingBuffer(trackBuffer.buffer)
        var conversionError: NSError?
        converter.convert(to: converted, error: &conversionError) { _, status in
            guard let buffer = pending.take() else {
                status.pointee = .noDataNow
                return nil
            }
            status.pointee = .haveData
            return buffer
        }

        guard conversionError == nil, converted.frameLength > 0 else { return }
        continuation.yield(AnalyzerInput(buffer: converted))
    }

    public func finish() async {
        continuation?.finish()
        continuation = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        resultsTask = nil
        analyzer = nil
        transcriber = nil
        converter = nil
    }

    private static func installAssetsIfNeeded(for transcriber: SpeechTranscriber) async throws {
        let status = await AssetInventory.status(forModules: [transcriber])
        guard status != .installed else { return }
        guard let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]
        ) else {
            throw TranscriptionError.assetsUnavailable
        }
        try await request.downloadAndInstall()
    }
}

public enum TranscriptionError: LocalizedError {
    case unavailable
    case noCompatibleFormat
    case assetsUnavailable

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "La transcription on-device n'est pas disponible sur cette machine."
        case .noCompatibleFormat:
            "Aucun format audio compatible avec le moteur de transcription."
        case .assetsUnavailable:
            "Les modèles de langue ne peuvent pas être installés pour cette locale."
        }
    }
}

/// `AVAudioConverter` réclame son tampon d'entrée une seule fois ; ce petit conteneur
/// évite de capturer une variable mutable dans un bloc concurrent.
private final class PendingBuffer: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}
