import AudioCapture
import Foundation

/// Supprime la diaphonie entre les deux pistes.
///
/// Sans casque, la voix des participants sort par les haut-parleurs et revient dans le
/// micro : le même propos est alors transcrit deux fois, une fois par piste, ce qui
/// ruine la diarisation. L'annulation d'écho matérielle n'est pas utilisable ici (le
/// traitement de voix d'Apple s'approprie le périphérique de sortie et prive le tap
/// système de sa source), la correction se fait donc sur le texte.
///
/// Règle d'arbitrage : en cas de doublon, on conserve le segment **système**. La voix
/// d'un participant distant arrive propre par le tap et dégradée par le micro ; à
/// l'inverse, la voix de l'utilisateur n'est jamais renvoyée vers la sortie système.
public struct CrossTalkFilter: Sendable {
    /// Tolérance de recouvrement temporel entre deux segments candidats.
    public var timeTolerance: TimeInterval
    /// Part minimale des mots du segment micro devant se retrouver côté système.
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

    /// Proportion des mots du segment micro retrouvés dans le segment système.
    ///
    /// Mesure asymétrique et non un indice de Jaccard : les deux pistes ne découpent
    /// pas la parole aux mêmes endroits, et la piste système regroupe souvent
    /// plusieurs phrases en un seul segment. Comparer les ensembles complets diluait
    /// la similarité au point de laisser passer les doublons.
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
