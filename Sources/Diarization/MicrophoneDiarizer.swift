import AudioCapture
import AVFoundation
import Foundation
import Transcription

/// Experimental diarization of the microphone track: distinguishes between
/// several speakers sharing the same microphone, based on classic acoustic
/// features (pitch, timbre) rather than a voice recognition model.
///
/// ## What this is not
///
/// This is **not** real diarization in the research sense (an embeddings model of
/// the d-vector/x-vector type + clustering). Apple exposes no public API of that
/// kind in `Speech`/`SpeechAnalyzer` (verified on macOS 26): doing better would
/// require embedding a third-party model converted to CoreML, a project of its
/// own. This is a deliberately modest first pass:
///
/// - works better when voices are clearly different (e.g. low/high pitched)
///   than when they sound similar;
/// - the number of speakers isn't known in advance: several values of `k` are
///   tried and the best one is kept by silhouette score, up to `maxSpeakers` —
///   beyond that, two acoustic features (pitch, timbre) are no longer enough to
///   reliably tell people apart;
/// - operates on already-cut transcript segments, not on actual speaking turns:
///   a segment that already contains two speakers without a break won't be split.
///
/// To be validated on real meetings before trusting it for a named-participant
/// summary (retrospective, sprint weather report).
public enum MicrophoneDiarizer {
    /// Minimum silhouette score below which we prefer to assert nothing rather
    /// than wrongly split a single-speaker session.
    private static let minimumSilhouetteScore = 0.45
    /// Beyond that, two coarse acoustic features (median pitch, spectral
    /// centroid) no longer discriminate enough people for this to be credible.
    public static let defaultMaxSpeakers = 4

    /// - Parameters:
    ///   - segments: microphone track segments only, in order.
    ///   - audioFileURL: the meeting's `microphone.caf` file.
    ///   - fileTimeOffset: offset between the session clock of the segments and
    ///     time 0 of the file (see `Meeting.trackStartOffsets["microphone"]`).
    ///   - maxSpeakers: upper bound on the number of speakers searched for.
    /// - Returns: one label per segment identifier, only for segments reliable
    ///   enough to be classified. `nil` if no split is deemed clear enough
    ///   (probably a single person).
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

        // We try several speaker counts and keep the one that separates the
        // data best (highest silhouette), not a `k` fixed in advance. We
        // require at least 3 reliable segments per candidate speaker: below
        // that, measurement noise on 2-3 segments is enough to fake a clean
        // separation (observed in testing with a single real voice).
        let upperBound = min(maxSpeakers, features.count / 3)
        guard upperBound >= 2 else { return nil }

        let candidates = (2...upperBound).compactMap { k in
            SpeakerClusterer.cluster(points: normalized, k: k)
        }
        guard let best = candidates.max(by: { $0.silhouetteScore < $1.silhouetteScore }),
              best.silhouetteScore >= minimumSilhouetteScore
        else { return nil }

        // The first cluster to speak becomes "Speaker 1", the next one to
        // appear "Speaker 2", etc. — more stable and readable than an
        // arbitrary cluster number.
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

    /// Reads mono samples over a time range, averaging channels if the file
    /// isn't already mono.
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
