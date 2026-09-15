import Foundation

/// Extracts a JSON object from a model's response.
///
/// Despite the instruction, models regularly wrap their output in a markdown
/// code block, or prefix it with an introductory sentence.
enum JSONExtractor {
    static func extract(from raw: String) throws -> Data {
        var text = raw

        // Optional ```json … ``` block.
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
            NSLocalizedString(
                "La réponse du modèle ne contient aucun objet JSON.",
                bundle: .main,
                value: "La réponse du modèle ne contient aucun objet JSON.",
                comment: ""
            )
        case .invalidSchema(let detail):
            String(
                format: NSLocalizedString(
                    "JSON non conforme au schéma : %@", bundle: .main, value: "JSON non conforme au schéma : %@", comment: ""
                ),
                detail
            )
        case .emptyTranscript:
            NSLocalizedString(
                "Le transcript est vide, aucun compte rendu à générer.",
                bundle: .main,
                value: "Le transcript est vide, aucun compte rendu à générer.",
                comment: ""
            )
        case .allAttemptsFailed(let detail):
            String(
                format: NSLocalizedString(
                    "Génération impossible après plusieurs tentatives — %@",
                    bundle: .main,
                    value: "Génération impossible après plusieurs tentatives — %@",
                    comment: ""
                ),
                detail
            )
        }
    }
}

/// Current step, to inform the UI during a long generation.
public enum SummaryProgress: Sendable, Equatable {
    case preparing
    case summarizingChunk(index: Int, total: Int)
    case synthesizing
    case repairing(attempt: Int)
}

/// Produces a `MeetingSummary` from a transcript, regardless of the provider.
///
/// Three responsibilities the provider does not take on: splitting meetings
/// too long for the context window, extracting JSON from the response, and
/// retrying the model when the output doesn't conform.
public struct SummaryGenerator: Sendable {
    public let provider: any SummaryProvider
    /// Beyond this size, generation switches to map-reduce. ~48,000 characters
    /// roughly corresponds to an hour-long meeting.
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
        language: SummaryLanguage = .french,
        onProgress: @Sendable (SummaryProgress) -> Void = { _ in },
        onUsage: @Sendable (TokenUsage) -> Void = { _ in }
    ) async throws -> MeetingSummary {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SummaryGenerationError.emptyTranscript }

        onProgress(.preparing)

        // Some providers (Apple Intelligence's on-device model, very narrow
        // context window) advertise a lower threshold than the generic one:
        // whichever of the two is more restrictive determines the chunking.
        let effectiveChunkThreshold = min(chunkThreshold, provider.maxPromptCharacters ?? chunkThreshold)

        let prompt: String
        if trimmed.count <= effectiveChunkThreshold {
            prompt = SummaryPrompt.single(
                transcript: trimmed,
                context: context,
                template: template,
                language: language
            )
        } else {
            let chunks = Self.split(trimmed, maxLength: effectiveChunkThreshold)
            var notes: [String] = []
            for (index, chunk) in chunks.enumerated() {
                onProgress(.summarizingChunk(index: index + 1, total: chunks.count))
                let completion = try await provider.complete(
                    prompt: SummaryPrompt.chunk(
                        transcript: chunk,
                        index: index + 1,
                        total: chunks.count,
                        template: template,
                        language: language
                    )
                )
                if let usage = completion.usage { onUsage(usage) }
                notes.append(completion.text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            onProgress(.synthesizing)
            prompt = SummaryPrompt.reduce(
                notes: notes, context: context, template: template, language: language
            )
        }

        var summary = try await completeAndDecode(
            prompt: prompt, template: template, language: language, onProgress: onProgress, onUsage: onUsage
        )
        // The chosen template is kept: it will drive both rendering and review.
        summary.templateID = template.id
        return Self.sanitize(summary, context: context)
    }

    /// Audio track labels are not identities.
    ///
    /// Despite the instruction, models regularly attribute a commitment to
    /// "Moi" or "Participants". A prompt instruction can't be verified: so
    /// normalization is done afterward, deterministically.
    static func sanitize(_ summary: MeetingSummary, context: SummaryContext) -> MeetingSummary {
        let trackLabels: Set<String> = ["moi", "participants", "participant", "me", "moi-même"]
        let userName = context.userName?.trimmingCharacters(in: .whitespaces)

        func resolve(_ name: String?) -> String? {
            guard let name else { return nil }
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            guard trackLabels.contains(trimmed.lowercased()) else { return trimmed }
            // "Moi" refers to the user; "Participants" refers to no one in particular.
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
        // A named entry without a usable name has no value: it's dropped
        // rather than displayed as an anonymous line.
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
        cleaned.sprintWeather = summary.sprintWeather.compactMap {
            guard let person = resolve($0.person) else { return nil }
            var entry = $0
            entry.person = person
            return entry
        }
        return cleaned
    }

    private func completeAndDecode(
        prompt: String,
        template: MeetingTemplate,
        language: SummaryLanguage,
        onProgress: @Sendable (SummaryProgress) -> Void,
        onUsage: @Sendable (TokenUsage) -> Void
    ) async throws -> MeetingSummary {
        var currentPrompt = prompt
        var lastError = ""

        for attempt in 0...maxRepairAttempts {
            if attempt > 0 { onProgress(.repairing(attempt: attempt)) }

            let raw: String
            do {
                let completion = try await provider.complete(prompt: currentPrompt)
                if let usage = completion.usage { onUsage(usage) }
                raw = completion.text
            } catch {
                lastError = error.localizedDescription
                // A provider failure isn't fixed by rephrasing the prompt.
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
                    previousOutput: raw,
                    error: lastError,
                    template: template,
                    language: language
                )
            }
        }

        throw SummaryGenerationError.allAttemptsFailed(lastError)
    }

    /// Splits the transcript on paragraph boundaries, to never cut in the
    /// middle of someone speaking.
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
    /// Deduplicates while preserving order of appearance.
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
