import AVFoundation
import AudioCapture
import Foundation
import Testing
import Transcription

@testable import Diarization

@Suite("Diarisation de la piste micro")
struct MicrophoneDiarizerTests {
    private let sampleRate = 16_000.0

    /// Écrit un fichier audio mono synthétique : une alternance de tons purs à des
    /// fréquences distinctes, un par « locuteur ». Un ton pur n'est pas une voix
    /// humaine, mais il a une fréquence fondamentale nette et stable, ce que
    /// l'extracteur de hauteur peut mesurer sans ambiguïté — suffisant pour tester
    /// la logique de clustering indépendamment de la qualité de l'estimation.
    private func writeAudio(
        segmentDuration: TimeInterval, frequencies: [Double]
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).caf")
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
            channels: 1, interleaved: false
        )!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)

        for frequency in frequencies {
            let frameCount = AVAudioFrameCount(segmentDuration * sampleRate)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
            buffer.frameLength = frameCount
            let samples = buffer.floatChannelData![0]
            for frame in 0..<Int(frameCount) {
                let t = Double(frame) / sampleRate
                samples[frame] = Float(sin(2 * .pi * frequency * t) * 0.8)
            }
            try file.write(from: buffer)
        }
        return url
    }

    private func segments(count: Int, segmentDuration: TimeInterval) -> [TranscriptSegment] {
        (0..<count).map { index in
            TranscriptSegment(
                track: .microphone,
                start: Double(index) * segmentDuration,
                end: Double(index + 1) * segmentDuration,
                text: "segment \(index)"
            )
        }
    }

    @Test("Deux tons nettement différents sont séparés en deux locuteurs")
    func splitsTwoDistinctVoices() throws {
        let segmentDuration = 0.6
        // Grave/aiguë alternées, comme deux personnes qui se répondent.
        let frequencies = [110.0, 220.0, 110.0, 220.0, 110.0, 220.0]
        let url = try writeAudio(segmentDuration: segmentDuration, frequencies: frequencies)
        defer { try? FileManager.default.removeItem(at: url) }

        let segs = segments(count: frequencies.count, segmentDuration: segmentDuration)
        let mapping = try MicrophoneDiarizer.diarize(
            segments: segs, audioFileURL: url, fileTimeOffset: 0
        )

        let labels = try #require(mapping)
        // Les segments graves (indices pairs) doivent tous porter la même étiquette,
        // distincte de celle des segments aigus (indices impairs).
        let lowLabels = Set([0, 2, 4].map { labels[segs[$0].id] })
        let highLabels = Set([1, 3, 5].map { labels[segs[$0].id] })
        #expect(lowLabels.count == 1)
        #expect(highLabels.count == 1)
        #expect(lowLabels != highLabels)
    }

    @Test("Trois tons nettement différents sont séparés en trois locuteurs")
    func splitsThreeDistinctVoices() throws {
        let segmentDuration = 0.6
        // Trois hauteurs bien espacées, comme trois personnes qui se relaient.
        let frequencies = [100.0, 180.0, 300.0, 100.0, 180.0, 300.0, 100.0, 180.0, 300.0]
        let url = try writeAudio(segmentDuration: segmentDuration, frequencies: frequencies)
        defer { try? FileManager.default.removeItem(at: url) }

        let segs = segments(count: frequencies.count, segmentDuration: segmentDuration)
        let mapping = try MicrophoneDiarizer.diarize(
            segments: segs, audioFileURL: url, fileTimeOffset: 0
        )

        let labels = try #require(mapping)
        let distinctLabels = Set(labels.values)
        #expect(distinctLabels.count == 3)
        // Chaque hauteur doit se retrouver seule dans son groupe.
        for group in [[0, 3, 6], [1, 4, 7], [2, 5, 8]] {
            let groupLabels = Set(group.map { labels[segs[$0].id] })
            #expect(groupLabels.count == 1)
        }
    }

    @Test("Une seule voix ne se scinde pas artificiellement")
    func doesNotSplitSingleVoice() throws {
        let segmentDuration = 0.6
        let frequencies = [150.0, 150.0, 150.0, 150.0]
        let url = try writeAudio(segmentDuration: segmentDuration, frequencies: frequencies)
        defer { try? FileManager.default.removeItem(at: url) }

        let segs = segments(count: frequencies.count, segmentDuration: segmentDuration)
        let mapping = try MicrophoneDiarizer.diarize(
            segments: segs, audioFileURL: url, fileTimeOffset: 0
        )

        #expect(mapping == nil)
    }

    @Test("Moins de deux segments micro ne déclenche pas la diarisation")
    func tooFewSegments() throws {
        let url = try writeAudio(segmentDuration: 0.6, frequencies: [150.0])
        defer { try? FileManager.default.removeItem(at: url) }

        let segs = segments(count: 1, segmentDuration: 0.6)
        let mapping = try MicrophoneDiarizer.diarize(
            segments: segs, audioFileURL: url, fileTimeOffset: 0
        )
        #expect(mapping == nil)
    }
}

@Suite("Clustering de traits acoustiques")
struct SpeakerClustererTests {
    @Test("Deux groupes nettement séparés sont retrouvés")
    func separatesTwoGroups() throws {
        let points = SpeakerClusterer.normalize([
            [100, 500], [105, 520], [98, 490],
            [300, 1500], [310, 1520], [295, 1480],
        ])
        let result = try #require(SpeakerClusterer.cluster(points: points, k: 2))
        let groupA = Set([0, 1, 2].map { result.assignments[$0] })
        let groupB = Set([3, 4, 5].map { result.assignments[$0] })
        #expect(groupA.count == 1)
        #expect(groupB.count == 1)
        #expect(groupA != groupB)
        #expect(result.silhouetteScore > 0.45)
    }

    @Test("k=3 sépare trois groupes nettement distincts")
    func separatesThreeGroups() throws {
        let points = SpeakerClusterer.normalize([
            [100, 500], [105, 520], [98, 490],
            [300, 1500], [310, 1520], [295, 1480],
            [600, 3000], [610, 3020], [595, 2980],
        ])
        let result = try #require(SpeakerClusterer.cluster(points: points, k: 3))
        #expect(result.clusterCount == 3)
        #expect(Set(result.assignments).count == 3)
        #expect(result.silhouetteScore > 0.45)
    }
}
