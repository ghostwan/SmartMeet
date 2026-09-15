import Atlassian
import Foundation
import Summarization

/// Generates meeting minutes from a transcript on disk, without recording.
/// Lets you test providers, prompt, and publication without tying up the microphone.
///
///     SmartMeet --summarize-file <transcript.md> [--publish]
@MainActor
enum HeadlessSummarizer {
    static func run(
        transcriptPath: String,
        publish: Bool,
        templateID: String?,
        language: SummaryLanguage
    ) async {
        guard let transcript = try? String(contentsOfFile: transcriptPath, encoding: .utf8),
              !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            print("❌ transcript illisible : \(transcriptPath)")
            exit(1)
        }

        let settings = AppSettings()
        let provider = settings.makeProvider()
        let template = settings.template(id: templateID ?? settings.defaultTemplateID)
        print("provider : \(provider.displayName)")
        print("type     : \(template.localizedName) — \(template.sections.map { $0.displayName(in: language) }.joined(separator: ", "))")
        print("langue   : \(language.flag) \(language.displayName)")

        guard await provider.isAvailable() else {
            print("❌ provider indisponible")
            exit(1)
        }

        let started = Date()
        let generator = SummaryGenerator(provider: provider)
        let context = SummaryContext(
            knownAttendees: [],
            vocabulary: settings.contextualVocabulary,
            userName: settings.userName
        )

        let summary: MeetingSummary
        let usageBox = UsageBox()
        do {
            summary = try await generator.generate(
                transcript: transcript,
                context: context,
                template: template,
                language: language
            ) { progress in
                print("  · \(progress)")
            } onUsage: { usage in
                usageBox.add(usage)
            }
        } catch {
            print("❌ \(error.localizedDescription)")
            exit(1)
        }

        print("✅ compte rendu en \(Int(Date().timeIntervalSince(started))) s")
        if let totalUsage = usageBox.total { print("   tokens : \(totalUsage.formatted)") }
        print("   titre : \(summary.title)")
        for section in template.sections where summary.hasContent(section) {
            let heading = section.displayName(in: language)
            switch section {
            case .blockers:
                print("   \(heading) :")
                for blocker in summary.blockers {
                    let marker = blocker.severity == .blocking ? "🛑" : "⚠️"
                    print("     \(marker) [\(blocker.person ?? "—")] \(blocker.description)")
                }
            case .participantReports:
                print("   \(heading) :")
                for report in summary.participantReports {
                    print("     • \(report.person) — fait \(report.done.count), à venir \(report.next.count), bloqué \(report.blockers.count)")
                }
            case .moods:
                print("   \(heading) :")
                for mood in summary.moods {
                    print("     • \(mood.person) [\(mood.mood.rawValue)] \(mood.comment)")
                }
            case .sprintWeather:
                print("   \(heading) :")
                for entry in summary.sprintWeather {
                    let icons = entry.icons.map(\.emoji).joined()
                    print("     \(icons) \(entry.person) — \(entry.explanation)")
                    for point in entry.sprintFeedback { print("        · \(point)") }
                }
            case .fourL:
                if let fourL = summary.fourL {
                    print("   \(heading) :")
                    for axis in fourL.axes(in: language) where !axis.topics.isEmpty {
                        print("     \(axis.label) : \(axis.topics.map(\.heading).joined(separator: " | "))")
                    }
                }
            case .topics:
                print("   \(heading) : \(summary.topics.map(\.heading).joined(separator: " | "))")
            case .actionItems:
                print("   Action items :")
                for item in summary.actionItems {
                    print("     • [\(item.owner ?? "—")] \(item.description) — \(item.dueDate ?? "sans échéance")")
                }
            case .decisions:
                print("   Décisions : \(summary.decisions.count)")
            default:
                break
            }
        }

        guard publish else { exit(0) }

        guard settings.canPublish else {
            print("❌ configuration Atlassian incomplète")
            exit(1)
        }

        let service = PublishService(
            configuration: settings.atlassian, token: settings.atlassianToken
        )
        let translateForJira: (@Sendable (String) async throws -> String)?
        if settings.atlassian.isJiraReady, language != .english {
            let provider = settings.makeProvider()
            translateForJira = { text in try await Translator.toEnglish(text, using: provider) }
        } else {
            translateForJira = nil
        }
        do {
            let result = try await service.publish(
                summary: summary,
                transcript: transcript,
                audioNote: "test headless",
                createJiraIssues: settings.atlassian.isJiraReady,
                template: template,
                language: language,
                includeTranscript: settings.includesTranscript(for: .atlassian),
                translateForJira: translateForJira
            ) { step in print("  · \(step)") }

            print("✅ page : \(result.pageURL?.absoluteString ?? result.pageID)")
            if !result.issues.isEmpty {
                print("   tickets : \(result.issues.values.sorted().joined(separator: ", "))")
            }
            if let searchURL = result.jiraSearchURL {
                print("   tickets Jira : \(searchURL.absoluteString)")
            }
            for failure in result.failures { print("   ⚠️ \(failure)") }
        } catch {
            print("❌ publication : \(error.localizedDescription)")
            exit(1)
        }
        exit(0)
    }
}
