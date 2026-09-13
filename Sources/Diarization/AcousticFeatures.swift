import Accelerate
import Foundation

/// Traits acoustiques d'un segment, censés varier d'une personne à l'autre plus
/// qu'au sein des propos d'une même personne.
///
/// Ce n'est **pas** une empreinte vocale au sens d'un modèle de reconnaissance du
/// locuteur (type d-vector/x-vector) : juste deux grandeurs classiques du signal,
/// bon marché à calculer sans dépendance externe ni modèle à embarquer.
/// - `pitchHz` : fréquence fondamentale médiane, la grandeur la plus discriminante
///   entre deux personnes (mais qui se recoupe entre deux voix proches) ;
/// - `spectralCentroidHz` : « centre de gravité » du spectre, proxy grossier du
///   timbre (une voix plus grave a un centroïde plus bas).
struct AcousticFeatures {
    var pitchHz: Double
    var spectralCentroidHz: Double
    /// Vrai si suffisamment de fenêtres voisées ont pu être mesurées ; sinon les
    /// valeurs ci-dessus sont peu fiables (segment court, chuchoté, ou bruité).
    var isReliable: Bool
}

/// Calcule les traits acoustiques d'une plage d'échantillons mono.
enum AcousticFeatureExtractor {
    private static let windowSize = 1024
    private static let hopSize = 512
    /// En dessous de ce seuil de corrélation normalisée, la fenêtre est jugée non
    /// voisée (silence, souffle, consonne) et exclue de la médiane de hauteur.
    private static let voicingThreshold: Float = 0.35

    /// - Parameters:
    ///   - samples: échantillons mono, déjà découpés sur la plage du segment.
    ///   - sampleRate: fréquence d'échantillonnage des `samples`.
    static func extract(samples: [Float], sampleRate: Double) -> AcousticFeatures {
        guard samples.count >= windowSize else {
            return AcousticFeatures(pitchHz: 0, spectralCentroidHz: 0, isReliable: false)
        }

        var pitches: [Double] = []
        var centroids: [Double] = []

        var offset = 0
        while offset + windowSize <= samples.count {
            let window = Array(samples[offset..<(offset + windowSize)])
            if let pitch = estimatePitch(window: window, sampleRate: sampleRate) {
                pitches.append(pitch)
            }
            centroids.append(spectralCentroid(window: window, sampleRate: sampleRate))
            offset += hopSize
        }

        // Le centroïde se mesure même sur du bruit : toujours disponible dès qu'il y
        // a au moins une fenêtre. La hauteur, elle, réclame des fenêtres voisées.
        let medianCentroid = centroids.isEmpty ? 0 : median(centroids)
        guard pitches.count >= 2 else {
            return AcousticFeatures(
                pitchHz: 0, spectralCentroidHz: medianCentroid, isReliable: false
            )
        }
        return AcousticFeatures(
            pitchHz: median(pitches), spectralCentroidHz: medianCentroid, isReliable: true
        )
    }

    /// Détection de hauteur par autocorrélation : méthode classique, peu coûteuse,
    /// suffisante pour distinguer deux voix nettement différentes.
    private static func estimatePitch(window: [Float], sampleRate: Double) -> Double? {
        let minHz = 70.0
        let maxHz = 400.0
        let minLag = Int(sampleRate / maxHz)
        let maxLag = min(Int(sampleRate / minHz), window.count - 1)
        guard minLag < maxLag else { return nil }

        var mean: Float = 0
        vDSP_meamgv(window, 1, &mean, vDSP_Length(window.count))
        let centered = window.map { $0 - mean }

        var energy: Float = 0
        vDSP_svesq(centered, 1, &energy, vDSP_Length(centered.count))
        guard energy > 0 else { return nil }

        var bestLag = -1
        var bestCorrelation: Float = 0
        for lag in minLag...maxLag {
            var correlation: Float = 0
            let count = centered.count - lag
            guard count > 0 else { continue }
            vDSP_dotpr(centered, 1, Array(centered[lag...]), 1, &correlation, vDSP_Length(count))
            let normalized = correlation / energy
            if normalized > bestCorrelation {
                bestCorrelation = normalized
                bestLag = lag
            }
        }

        guard bestLag > 0, bestCorrelation > voicingThreshold else { return nil }
        return sampleRate / Double(bestLag)
    }

    /// Moyenne des fréquences pondérée par l'amplitude du spectre : plus haute pour
    /// un timbre clair, plus basse pour un timbre sombre.
    private static func spectralCentroid(window: [Float], sampleRate: Double) -> Double {
        let log2n = vDSP_Length(log2(Double(window.count)))
        let fftSize = 1 << log2n
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return 0 }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var real = Array(window.prefix(fftSize))
        var imaginary = [Float](repeating: 0, count: fftSize)
        var magnitudes = [Float](repeating: 0, count: fftSize / 2)

        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(
                    realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!
                )
                vDSP_fft_zip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
            }
        }

        var weightedSum: Double = 0
        var magnitudeSum: Double = 0
        let binHz = sampleRate / Double(fftSize)
        for (bin, magnitude) in magnitudes.enumerated() {
            let magnitude = Double(magnitude)
            weightedSum += Double(bin) * binHz * magnitude
            magnitudeSum += magnitude
        }
        guard magnitudeSum > 0 else { return 0 }
        return weightedSum / magnitudeSum
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[mid - 1] + sorted[mid]) / 2
            : sorted[mid]
    }
}
