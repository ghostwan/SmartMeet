import AudioCapture
import AVFoundation
import Foundation
import Transcription

/// Diarisation expérimentale de la piste micro : distingue jusqu'à deux locuteurs
/// partageant un même micro, à partir de traits acoustiques classiques (hauteur,
/// timbre) plutôt que d'un modèle de reconnaissance vocale.
///
/// ## Ce que ce n'est pas
///
/// Ce n'est **pas** une vraie diarisation au sens où l'entend la recherche (modèle
/// d'embeddings de type d-vector/x-vector + clustering). Apple n'expose aucune API
/// publique de ce type dans `Speech`/`SpeechAnalyzer` (vérifié sur macOS 26) : faire
/// mieux demanderait d'embarquer un modèle tiers converti en CoreML, projet à part
/// entière. Ceci est un premier jet, volontairement modeste :
///
/// - fonctionne mieux quand les deux voix sont nettement différentes (par ex.
///   grave/aiguë) que quand elles se ressemblent ;
/// - suppose au plus **deux** locuteurs sur la piste micro ;
/// - opère par segment de transcript déjà découpé, pas par tour de parole réel :
///   un segment qui contiendrait déjà deux locuteurs sans coupure ne sera pas séparé.
///
/// À valider sur de vraies réunions avant de lui faire confiance pour un compte
/// rendu nominatif (rétrospective, météo du sprint).
public enum MicrophoneDiarizer {
    /// Score de séparation minimal (voir `SpeakerClusterer`) en dessous duquel on
    /// préfère ne rien affirmer plutôt que scinder à tort une session à un seul
    /// locuteur.
    private static let minimumSeparationScore = 1.4

    /// - Parameters:
    ///   - segments: uniquement les segments de la piste micro, dans l'ordre.
    ///   - audioFileURL: le fichier `microphone.caf` de la réunion.
    ///   - fileTimeOffset: décalage entre l'horloge de session des segments et le
    ///     temps 0 du fichier (voir `Meeting.trackStartOffsets["microphone"]`).
    /// - Returns: une étiquette par identifiant de segment, uniquement pour les
    ///   segments assez fiables pour être classés. `nil` si la séparation n'est pas
    ///   jugée assez nette (probablement une seule personne).
    public static func diarize(
        segments: [TranscriptSegment],
        audioFileURL: URL,
        fileTimeOffset: TimeInterval
    ) throws -> [UUID: String]? {
        let microphoneSegments = segments
            .filter { $0.track == .microphone }
            .sorted { $0.start < $1.start }
        guard microphoneSegments.count >= 2 else { return nil }

        let file = try AVAudioFile(forReading: audioFileURL)
        let sampleRate = file.processingFormat.sampleRate

        var features: [(id: UUID, start: TimeInterval, feature: AcousticFeatures)] = []
        for segment in microphoneSegments {
            let fileStart = segment.start - fileTimeOffset
            let fileEnd = segment.end - fileTimeOffset
            guard let samples = try readMonoSamples(
                from: file, start: fileStart, end: fileEnd
            ) else { continue }
            let feature = AcousticFeatureExtractor.extract(samples: samples, sampleRate: sampleRate)
            guard feature.isReliable else { continue }
            features.append((segment.id, segment.start, feature))
        }

        guard features.count >= 2 else { return nil }

        let points = features.map { [$0.feature.pitchHz, $0.feature.spectralCentroidHz] }
        let normalized = SpeakerClusterer.normalize(points)
        guard let result = SpeakerClusterer.cluster(points: normalized),
              result.separationScore >= minimumSeparationScore
        else { return nil }

        // Le premier à parler devient « Locuteur 1 » : plus stable et plus lisible
        // qu'un numéro de cluster arbitraire.
        let firstClusterSeen = result.assignments.first ?? 0
        var mapping: [UUID: String] = [:]
        for (index, entry) in features.enumerated() {
            let label = result.assignments[index] == firstClusterSeen ? "Locuteur 1" : "Locuteur 2"
            mapping[entry.id] = label
        }
        return mapping
    }

    /// Lit les échantillons mono d'une plage temporelle, en moyennant les canaux si
    /// le fichier n'est pas déjà mono.
    private static func readMonoSamples(
        from file: AVAudioFile, start: TimeInterval, end: TimeInterval
    ) throws -> [Float]? {
        let sampleRate = file.processingFormat.sampleRate
        let startFrame = max(0, AVAudioFramePosition(start * sampleRate))
        let endFrame = min(file.length, AVAudioFramePosition(end * sampleRate))
        guard endFrame > startFrame else { return nil }
        let frameCount = AVAudioFrameCount(endFrame - startFrame)

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: frameCount
        ) else { return nil }

        file.framePosition = startFrame
        try file.read(into: buffer, frameCount: frameCount)
        guard let channelData = buffer.floatChannelData else { return nil }

        let channelCount = Int(buffer.format.channelCount)
        let length = Int(buffer.frameLength)
        guard length > 0 else { return nil }

        if channelCount == 1 {
            return Array(UnsafeBufferPointer(start: channelData[0], count: length))
        }

        var mono = [Float](repeating: 0, count: length)
        for channel in 0..<channelCount {
            let data = UnsafeBufferPointer(start: channelData[channel], count: length)
            for index in 0..<length { mono[index] += data[index] }
        }
        let count = Float(channelCount)
        return mono.map { $0 / count }
    }
}
