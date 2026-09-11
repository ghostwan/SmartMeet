import Foundation
import Summarization

/// Rend le compte rendu au format *storage* de Confluence (XHTML).
///
/// Format retenu plutôt qu'ADF : il accepte les macros natives (`expand`, `jira`,
/// `panel`) avec un balisage simple et stable, là où ADF impose une structure de
/// nœuds bien plus verbeuse pour le même résultat.
///
/// L'ordre des sections suit celui du type de réunion : un daily ouvre sur les points
/// bloquants, une rétrospective sur le ressenti de l'équipe.
public enum ConfluenceStorageRenderer {
    public static func render(
        summary: MeetingSummary,
        transcript: String,
        audioNote: String?,
        template: MeetingTemplate = .generic
    ) -> String {
        var parts: [String] = []

        let realAttendees = summary.attendees.filter {
            !["moi", "participants"].contains($0.lowercased())
        }
        if !realAttendees.isEmpty {
            parts.append(
                "<p><strong>Participants :</strong> "
                    + "\(escaped(realAttendees.joined(separator: ", ")))</p>"
            )
        }

        for section in template.sections where summary.hasContent(section) {
            parts.append(contentsOf: render(section: section, of: summary))
        }

        // Le transcript intégral est utile mais encombrant : replié par défaut.
        let body = transcript
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { "<p>\(escaped(stripMarkdown($0)))</p>" }
            .joined()
        parts.append(expand(title: "Transcript intégral", body: body))

        var footer = "<p><em>Compte rendu généré par SmartMeet (\(escaped(template.name)))"
        if let audioNote { footer += " — \(escaped(audioNote))" }
        footer += ".</em></p>"
        parts.append(footer)

        return parts.joined()
    }

    private static func render(
        section: SummarySection,
        of summary: MeetingSummary
    ) -> [String] {
        switch section {
        case .tldr:
            return ["<p><strong>TL;DR —</strong> \(escaped(summary.tldr))</p>"]

        case .blockers:
            // Encadré d'alerte : dans un daily, c'est la seule information qui appelle
            // une action immédiate, elle doit sauter aux yeux.
            return [panel(
                type: summary.blockers.contains { $0.severity == .blocking } ? "warning" : "note",
                title: section.displayName,
                body: "<ul>" + summary.blockers.map { blocker in
                    let marker = blocker.severity == .blocking ? "🛑" : "⚠️"
                    let who = blocker.person.map { "<strong>\(escaped($0))</strong> — " } ?? ""
                    return "<li>\(marker) \(who)\(escaped(blocker.description))</li>"
                }.joined() + "</ul>"
            )]

        case .participantReports:
            return ["<h2>\(escaped(section.displayName))</h2>"] + summary.participantReports.map { report in
                var block = "<h3>\(escaped(report.person))</h3>"
                if !report.done.isEmpty {
                    block += "<p><em>Fait</em></p>" + list(report.done)
                }
                if !report.next.isEmpty {
                    block += "<p><em>À venir</em></p>" + list(report.next)
                }
                if !report.blockers.isEmpty {
                    block += "<p><em>Bloqué par</em></p>" + list(report.blockers)
                }
                return block
            }

        case .moods:
            var rows = ["<tr><th>Personne</th><th>Ressenti</th><th>Commentaire</th></tr>"]
            for mood in summary.moods {
                let icon = switch mood.mood {
                case .positive: "🙂"
                case .neutral: "😐"
                case .negative: "🙁"
                }
                rows.append(
                    "<tr>"
                        + "<td>\(escaped(mood.person))</td>"
                        + "<td>\(icon) \(escaped(mood.mood.rawValue))</td>"
                        + "<td>\(escaped(mood.comment))</td>"
                        + "</tr>"
                )
            }
            return [
                "<h2>\(escaped(section.displayName))</h2>",
                "<table><tbody>" + rows.joined() + "</tbody></table>",
            ]

        case .topics:
            return summary.topics
                .filter { !$0.heading.isEmpty }
                .flatMap { ["<h2>\(escaped($0.heading))</h2>", list($0.bullets)] }

        case .decisions:
            return ["<h2>\(escaped(section.displayName))</h2>", list(summary.decisions)]

        case .actionItems:
            return ["<h2>\(escaped(section.displayName))</h2>", actionItemsTable(summary.actionItems)]

        case .openQuestions:
            return ["<h2>\(escaped(section.displayName))</h2>", list(summary.openQuestions)]

        case .nextSteps:
            return ["<h2>\(escaped(section.displayName))</h2>", list(summary.nextSteps)]
        }
    }

    static func list(_ items: [String]) -> String {
        let visible = items.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !visible.isEmpty else { return "<p><em>Aucun</em></p>" }
        return "<ul>" + visible.map { "<li>\(escaped($0))</li>" }.joined() + "</ul>"
    }

    static func actionItemsTable(_ items: [MeetingSummary.ActionItem]) -> String {
        var rows = ["<tr><th>Responsable</th><th>Action</th><th>Échéance</th><th>Ticket</th></tr>"]
        for item in items {
            let ticket = item.jiraKey.map(jiraMacro) ?? "—"
            rows.append(
                "<tr>"
                    + "<td>\(escaped(item.owner ?? "—"))</td>"
                    + "<td>\(escaped(item.description))</td>"
                    + "<td>\(escaped(item.dueDate ?? "—"))</td>"
                    + "<td>\(ticket)</td>"
                    + "</tr>"
            )
        }
        return "<table><tbody>" + rows.joined() + "</tbody></table>"
    }

    static func jiraMacro(_ key: String) -> String {
        "<ac:structured-macro ac:name=\"jira\">"
            + "<ac:parameter ac:name=\"key\">\(escaped(key))</ac:parameter>"
            + "</ac:structured-macro>"
    }

    static func expand(title: String, body: String) -> String {
        "<ac:structured-macro ac:name=\"expand\">"
            + "<ac:parameter ac:name=\"title\">\(escaped(title))</ac:parameter>"
            + "<ac:rich-text-body>\(body)</ac:rich-text-body>"
            + "</ac:structured-macro>"
    }

    static func panel(type: String, title: String, body: String) -> String {
        "<ac:structured-macro ac:name=\"\(type)\">"
            + "<ac:parameter ac:name=\"title\">\(escaped(title))</ac:parameter>"
            + "<ac:rich-text-body>\(body)</ac:rich-text-body>"
            + "</ac:structured-macro>"
    }

    /// Le transcript est stocké en markdown ; on retire le balisage avant échappement.
    static func stripMarkdown(_ line: String) -> String {
        line.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression)
    }

    /// Échappement XML strict : le format storage rejette une entité mal formée et
    /// fait échouer toute la page.
    public static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
