import Accelerate
import Foundation

/// Acoustic features of a segment, expected to vary more between different
/// people than within a single person's speech.
///
/// This is **not** a voiceprint in the sense of a speaker recognition model
/// (d-vector/x-vector type): just two classic signal quantities, cheap to
/// compute with no external dependency or model to embed.
/// - `pitchHz`: median fundamental frequency, the most discriminating quantity
///   between two people (but which overlaps between two close voices);
/// - `spectralCentroidHz`: "center of mass" of the spectrum, a coarse proxy for
///   timbre (a deeper voice has a lower centroid).
struct AcousticFeatures {
    var pitchHz: Double
    var spectralCentroidHz: Double
    /// True if enough voiced windows could be measured; otherwise the values
    /// above are unreliable (short, whispered, or noisy segment).
    var isReliable: Bool
}

/// Computes the acoustic features of a range of mono samples.
enum AcousticFeatureExtractor {
    private static let windowSize = 1024
    private static let hopSize = 512
    /// Below this normalized correlation threshold, the window is deemed
    /// unvoiced (silence, breath, consonant) and excluded from the pitch median.
    private static let voicingThreshold: Float = 0.35

    /// - Parameters:
    ///   - samples: mono samples, already trimmed to the segment's range.
    ///   - sampleRate: sample rate of the `samples`.
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

        // The centroid can be measured even on noise: always available as soon
        // as there's at least one window. Pitch, on the other hand, requires
        // voiced windows.
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

    /// Pitch detection via autocorrelation: classic, cheap method, sufficient
    /// to distinguish two clearly different voices.
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

    /// Average of frequencies weighted by spectral amplitude: higher for a
    /// bright timbre, lower for a dark timbre.
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
