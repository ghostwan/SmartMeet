import Foundation

/// Extrait un objet JSON d'une réponse de modèle.
///
/// Malgré la consigne, les modèles encadrent régulièrement leur sortie d'un bloc de
/// code markdown, ou la font précéder d'une phrase d'introduction.
enum JSONExtractor {
    static func extract(from raw: String) throws -> Data {
        var text = raw

        // Bloc ```json … ``` éventuel.
        if let fenceStart = text.range(of: "```") {
            let afterFence = text[fenceStart.upperBound...]
            let body = afterFence.hasPrefix("json")
                ? afterFence.dropFirst(4)
                : afterFence
            if let fenceEnd = body.range(of: "```") {
                text = String(body[..<fenceEnd.lowerBound])
            } else {
                text = String(body)
            }
        }

        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end
        else {
            throw SummaryGenerationError.noJSONObject
        }
        return Data(text[start...end].utf8)
    }
}

public enum SummaryGenerationError: LocalizedError {
    case noJSONObject
    case invalidSchema(String)
    case emptyTranscript
    case allAttemptsFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noJSONObject:
            "La réponse du modèle ne contient aucun objet JSON."
        case .invalidSchema(let detail):
            "JSON non conforme au schéma : \(detail)"
        case .emptyTranscript:
            "Le transcript est vide, aucun compte rendu à générer."
        case .allAttemptsFailed(let detail):
            "Génération impossible après plusieurs tentatives — \(detail)"
        }
    }
}

/// Étape en cours, pour informer l'interface pendant une génération longue.
public enum SummaryProgress: Sendable, Equatable {
    case preparing
    case summarizingChunk(index: Int, total: Int)
    case synthesizing
    case repairing(attempt: Int)
}

/// Produit un `MeetingSummary` à partir d'un transcript, quel que soit le provider.
///
/// Trois responsabilités que le provider n'assume pas : découper les réunions trop
/// longues pour la fenêtre de contexte, extraire le JSON de la réponse, et relancer
/// le modèle quand la sortie n'est pas conforme.
public struct SummaryGenerator: Sendable {
    public let provider: any SummaryProvider
    /// Au-delà de cette taille, on bascule en map-reduce. ~48 000 caractères
    /// correspondent grossièrement à une heure de réunion.
    public var chunkThreshold: Int
    public var maxRepairAttempts: Int

    public init(
        provider: any SummaryProvider,
        chunkThreshold: Int = 48_000,
        maxRepairAttempts: Int = 2
    ) {
        self.provider = provider
        self.chunkThreshold = chunkThreshold
        self.maxRepairAttempts = maxRepairAttempts
    }

    public func generate(
        transcript: String,
        context: SummaryContext,
        template: MeetingTemplate = .generic,
        onProgress: @Sendable (SummaryProgress) -> Void = { _ in }
    ) async throws -> MeetingSummary {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SummaryGenerationError.emptyTranscript }

        onProgress(.preparing)

        let prompt: String
        if trimmed.count <= chunkThreshold {
            prompt = SummaryPrompt.single(
                transcript: trimmed, context: context, template: template
            )
        } else {
            let chunks = Self.split(trimmed, maxLength: chunkThreshold)
            var notes: [String] = []
            for (index, chunk) in chunks.enumerated() {
                onProgress(.summarizingChunk(index: index + 1, total: chunks.count))
                let note = try await provider.complete(
                    prompt: SummaryPrompt.chunk(
                        transcript: chunk,
                        index: index + 1,
                        total: chunks.count,
                        template: template
                    )
                )
                notes.append(note.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            onProgress(.synthesizing)
            prompt = SummaryPrompt.reduce(notes: notes, context: context, template: template)
        }

        var summary = try await completeAndDecode(
            prompt: prompt, template: template, onProgress: onProgress
        )
        // Le type retenu est conservé : c'est lui qui pilotera le rendu et la relecture.
        summary.templateID = template.id
        return Self.sanitize(summary, context: context)
    }

    /// Les libellés de piste audio ne sont pas des identités.
    ///
    /// Malgré la consigne, les modèles attribuent régulièrement un engagement à
    /// « Moi » ou « Participants ». Une consigne de prompt ne se vérifie pas : la
    /// normalisation est donc faite après coup, de façon déterministe.
    static func sanitize(_ summary: MeetingSummary, context: SummaryContext) -> MeetingSummary {
        let trackLabels: Set<String> = ["moi", "participants", "participant", "me", "moi-même"]
        let userName = context.userName?.trimmingCharacters(in: .whitespaces)

        func resolve(_ name: String?) -> String? {
            guard let name else { return nil }
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            guard trackLabels.contains(trimmed.lowercased()) else { return trimmed }
            // « Moi » désigne l'utilisateur ; « Participants » ne désigne personne.
            let isSelf = trimmed.lowercased() != "participants" && trimmed.lowercased() != "participant"
            return isSelf ? userName.flatMap { $0.isEmpty ? nil : $0 } : nil
        }

        var cleaned = summary
        cleaned.attendees = summary.attendees.compactMap(resolve).uniqued()
        cleaned.actionItems = summary.actionItems.map {
            var item = $0
            item.owner = resolve($0.owner)
            return item
        }
        cleaned.blockers = summary.blockers.map {
            var blocker = $0
            blocker.person = resolve($0.person)
            return blocker
        }
        // Une entrée nominative sans nom exploitable n'a aucune valeur : on la retire
        // plutôt que d'afficher une ligne anonyme.
        cleaned.participantReports = summary.participantReports.compactMap {
            guard let person = resolve($0.person) else { return nil }
            var report = $0
            report.person = person
            return report
        }
        cleaned.moods = summary.moods.compactMap {
            guard let person = resolve($0.person) else { return nil }
            var mood = $0
            mood.person = person
            return mood
        }
        return cleaned
    }

    private func completeAndDecode(
        prompt: String,
        template: MeetingTemplate,
        onProgress: @Sendable (SummaryProgress) -> Void
    ) async throws -> MeetingSummary {
        var currentPrompt = prompt
        var lastError = ""

        for attempt in 0...maxRepairAttempts {
            if attempt > 0 { onProgress(.repairing(attempt: attempt)) }

            let raw: String
            do {
                raw = try await provider.complete(prompt: currentPrompt)
            } catch {
                lastError = error.localizedDescription
                // Une panne du provider ne se répare pas en reformulant le prompt.
                throw SummaryGenerationError.allAttemptsFailed(lastError)
            }

            do {
                let data = try JSONExtractor.extract(from: raw)
                let summary = try JSONDecoder().decode(MeetingSummary.self, from: data)
                guard summary.isUsable else {
                    throw SummaryGenerationError.invalidSchema("titre manquant ou compte rendu vide")
                }
                return summary
            } catch {
                lastError = error.localizedDescription
                currentPrompt = SummaryPrompt.repair(
                    previousOutput: raw, error: lastError, template: template
                )
            }
        }

        throw SummaryGenerationError.allAttemptsFailed(lastError)
    }

    /// Découpe le transcript sur les frontières de paragraphes, pour ne jamais couper
    /// au milieu d'une prise de parole.
    static func split(_ transcript: String, maxLength: Int) -> [String] {
        let paragraphs = transcript.components(separatedBy: "\n\n")
        var chunks: [String] = []
        var current = ""

        for paragraph in paragraphs {
            if !current.isEmpty, current.count + paragraph.count + 2 > maxLength {
                chunks.append(current)
                current = paragraph
            } else {
                current += current.isEmpty ? paragraph : "\n\n" + paragraph
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}

extension Array where Element: Hashable {
    /// Déduplique en conservant l'ordre d'apparition.
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
