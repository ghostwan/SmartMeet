import AudioCapture
import Foundation

/// Removes cross-talk between the two tracks.
///
/// Without headphones, participants' voices come out of the speakers and back
/// into the microphone: the same remarks then get transcribed twice, once per
/// track, which ruins diarization. Hardware echo cancellation isn't usable here
/// (Apple's voice processing takes ownership of the output device and starves
/// the system tap of its source), so the correction happens at the text level.
///
/// Arbitration rule: in case of a duplicate, the **system** segment is kept. A
/// remote participant's voice arrives clean through the tap and degraded
/// through the microphone; conversely, the user's own voice is never routed
/// back to the system output.
public struct CrossTalkFilter: Sendable {
    /// Time-overlap tolerance between two candidate segments.
    public var timeTolerance: TimeInterval
    /// Minimum share of the microphone segment's words that must be found on
    /// the system side.
    public var containmentThreshold: Double

    public init(timeTolerance: TimeInterval = 3, containmentThreshold: Double = 0.5) {
        self.timeTolerance = timeTolerance
        self.containmentThreshold = containmentThreshold
    }

    public func apply(to segments: [TranscriptSegment]) -> [TranscriptSegment] {
        let systemSegments = segments.filter { $0.track == .system }
        guard !systemSegments.isEmpty else { return segments }

        return segments.filter { segment in
            guard segment.track == .microphone else { return true }
            return !systemSegments.contains { system in
                overlaps(segment, system)
                    && containment(of: segment.text, in: system.text) >= containmentThreshold
            }
        }
    }

    private func overlaps(_ lhs: TranscriptSegment, _ rhs: TranscriptSegment) -> Bool {
        lhs.start < rhs.end + timeTolerance && rhs.start < lhs.end + timeTolerance
    }

    /// Proportion of the microphone segment's words found in the system segment.
    ///
    /// Asymmetric measure rather than a Jaccard index: the two tracks don't cut
    /// speech at the same points, and the system track often groups several
    /// sentences into a single segment. Comparing full sets diluted the
    /// similarity to the point of letting duplicates through.
    func containment(of candidate: String, in reference: String) -> Double {
        let candidateTokens = tokens(candidate)
        let referenceTokens = tokens(reference)
        guard !candidateTokens.isEmpty, !referenceTokens.isEmpty else { return 0 }
        return Double(candidateTokens.intersection(referenceTokens).count)
            / Double(candidateTokens.count)
    }

    private func tokens(_ text: String) -> Set<String> {
        Set(
            text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { $0.count > 2 }
        )
    }
}
