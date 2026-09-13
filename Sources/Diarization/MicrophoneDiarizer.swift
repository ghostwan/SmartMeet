import AudioCapture
import AVFoundation
import Foundation
import Transcription

/// Diarisation expérimentale de la piste micro : distingue plusieurs locuteurs
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
/// - fonctionne mieux quand les voix sont nettement différentes (par ex.
///   grave/aiguë) que quand elles se ressemblent ;
/// - le nombre de locuteurs n'est pas connu à l'avance : plusieurs valeurs de `k`
///   sont essayées et la meilleure est retenue par score de silhouette, jusqu'à
///   `maxSpeakers` — au-delà, deux traits acoustiques (hauteur, timbre) ne suffisent
///   plus à séparer les gens de façon fiable ;
/// - opère par segment de transcript déjà découpé, pas par tour de parole réel :
///   un segment qui contiendrait déjà deux locuteurs sans coupure ne sera pas séparé.
///
/// À valider sur de vraies réunions avant de lui faire confiance pour un compte
/// rendu nominatif (rétrospective, météo du sprint).
public enum MicrophoneDiarizer {
    /// Score de silhouette minimal en dessous duquel on préfère ne rien affirmer
    /// plutôt que scinder à tort une session à un seul locuteur.
    private static let minimumSilhouetteScore = 0.45
    /// Au-delà, deux traits acoustiques grossiers (hauteur médiane, centroïde
    /// spectral) ne discriminent plus assez de monde pour que ce soit crédible.
    public static let defaultMaxSpeakers = 4

    /// - Parameters:
    ///   - segments: uniquement les segments de la piste micro, dans l'ordre.
    ///   - audioFileURL: le fichier `microphone.caf` de la réunion.
    ///   - fileTimeOffset: décalage entre l'horloge de session des segments et le
    ///     temps 0 du fichier (voir `Meeting.trackStartOffsets["microphone"]`).
    ///   - maxSpeakers: borne haute du nombre de locuteurs recherchés.
    /// - Returns: une étiquette par identifiant de segment, uniquement pour les
    ///   segments assez fiables pour être classés. `nil` si aucune scission n'est
    ///   jugée assez nette (probablement une seule personne).
    public static func diarize(
        segments: [TranscriptSegment],
        audioFileURL: URL,
        fileTimeOffset: TimeInterval,
        maxSpeakers: Int = defaultMaxSpeakers
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

        // On essaie plusieurs nombres de locuteurs et on garde celui qui sépare le
        // mieux les données (silhouette la plus haute), pas un k figé d'avance. On
        // exige au moins 3 segments fiables par locuteur candidat : en dessous, le
        // bruit de mesure sur 2-3 segments suffit à simuler une fausse séparation
        // nette (observé en test avec une seule vraie voix).
        let upperBound = min(maxSpeakers, features.count / 3)
        guard upperBound >= 2 else { return nil }

        let candidates = (2...upperBound).compactMap { k in
            SpeakerClusterer.cluster(points: normalized, k: k)
        }
        guard let best = candidates.max(by: { $0.silhouetteScore < $1.silhouetteScore }),
              best.silhouetteScore >= minimumSilhouetteScore
        else { return nil }

        // Le premier cluster à parler devient « Locuteur 1 », le suivant à
        // apparaître « Locuteur 2 », etc. — plus stable et plus lisible qu'un
        // numéro de cluster arbitraire.
        var labelByCluster: [Int: String] = [:]
        var nextLabelIndex = 1
        var mapping: [UUID: String] = [:]
        for (index, entry) in features.enumerated() {
            let cluster = best.assignments[index]
            if labelByCluster[cluster] == nil {
                labelByCluster[cluster] = "Locuteur \(nextLabelIndex)"
                nextLabelIndex += 1
            }
            mapping[entry.id] = labelByCluster[cluster]
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
