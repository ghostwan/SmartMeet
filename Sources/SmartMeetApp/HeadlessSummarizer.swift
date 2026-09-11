import Atlassian
import Foundation
import Summarization

/// Génère un compte rendu à partir d'un transcript sur disque, sans enregistrer.
/// Permet de tester providers, prompt et publication sans mobiliser le micro.
///
///     SmartMeet --summarize-file <transcript.md> [--publish]
@MainActor
enum HeadlessSummarizer {
    static func run(transcriptPath: String, publish: Bool, templateID: String?) async {
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
        print("type     : \(template.name) — \(template.sections.map(\.displayName).joined(separator: ", "))")

        guard await provider.isAvailable() else {
            print("❌ provider indisponible")
            exit(1)
        }

        let started = Date()
        let generator = SummaryGenerator(provider: provider)
        let context = SummaryContext(
            knownAttendees: [],
            vocabulary: settings.vocabulary,
            userName: settings.userName
        )

        let summary: MeetingSummary
        do {
            summary = try await generator.generate(
                transcript: transcript,
                context: context,
                template: template
            ) { progress in
                print("  · \(progress)")
            }
        } catch {
            print("❌ \(error.localizedDescription)")
            exit(1)
        }

        print("✅ compte rendu en \(Int(Date().timeIntervalSince(started))) s")
        print("   titre : \(summary.title)")
        for section in template.sections where summary.hasContent(section) {
            switch section {
            case .blockers:
                print("   \(section.displayName) :")
                for blocker in summary.blockers {
                    let marker = blocker.severity == .blocking ? "🛑" : "⚠️"
                    print("     \(marker) [\(blocker.person ?? "—")] \(blocker.description)")
                }
            case .participantReports:
                print("   \(section.displayName) :")
                for report in summary.participantReports {
                    print("     • \(report.person) — fait \(report.done.count), à venir \(report.next.count), bloqué \(report.blockers.count)")
                }
            case .moods:
                print("   \(section.displayName) :")
                for mood in summary.moods {
                    print("     • \(mood.person) [\(mood.mood.rawValue)] \(mood.comment)")
                }
            case .topics:
                print("   Sujets : \(summary.topics.map(\.heading).joined(separator: " | "))")
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
        do {
            let result = try await service.publish(
                summary: summary,
                transcript: transcript,
                audioNote: "test headless",
                createJiraIssues: settings.atlassian.isJiraReady,
                template: template
            ) { step in print("  · \(step)") }

            print("✅ page : \(result.pageURL?.absoluteString ?? result.pageID)")
            if !result.issues.isEmpty {
                print("   tickets : \(result.issues.values.sorted().joined(separator: ", "))")
            }
            for failure in result.failures { print("   ⚠️ \(failure)") }
        } catch {
            print("❌ publication : \(error.localizedDescription)")
            exit(1)
        }
        exit(0)
    }
}
