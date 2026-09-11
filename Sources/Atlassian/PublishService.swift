import Foundation
import Summarization

public struct PublicationResult: Sendable, Equatable {
    public let pageURL: URL?
    public let pageID: String
    public let issues: [String: String]
    public let failures: [String]
}

public enum PublishStep: Sendable, Equatable {
    case creatingPage
    case creatingIssue(index: Int, total: Int)
    case linkingIssues
    case done
}

/// Enchaîne la publication Confluence puis Jira.
///
/// Ordre retenu : page d'abord (sans les clés), tickets ensuite avec un lien vers
/// elle, puis réécriture de la page avec les clés. C'est le seul ordre qui donne un
/// lien dans les deux sens ; l'inverse laisserait les tickets orphelins.
public struct PublishService: Sendable {
    private let configuration: AtlassianConfiguration
    private let confluence: ConfluenceClient
    private let jira: JiraClient

    public init(configuration: AtlassianConfiguration, token: String) {
        self.configuration = configuration
        self.confluence = ConfluenceClient(configuration: configuration, token: token)
        self.jira = JiraClient(configuration: configuration, token: token)
    }

    public func publish(
        summary: MeetingSummary,
        transcript: String,
        audioNote: String?,
        createJiraIssues: Bool,
        template: MeetingTemplate = .generic,
        onStep: @Sendable (PublishStep) -> Void = { _ in }
    ) async throws -> PublicationResult {
        guard configuration.isConfluenceReady else {
            throw AtlassianError.notConfigured("site, e-mail ou espace Confluence")
        }

        onStep(.creatingPage)
        let space = try await confluence.space(key: configuration.spaceKey)
        let parentID = configuration.parentPageID.isEmpty
            ? space.homepageID
            : configuration.parentPageID

        let title = pageTitle(for: summary)
        var enriched = summary
        let page = try await confluence.createPage(
            title: title,
            storageBody: ConfluenceStorageRenderer.render(
                summary: enriched,
                transcript: transcript,
                audioNote: audioNote,
                template: template
            ),
            spaceID: space.id,
            parentID: parentID
        )

        var createdKeys: [String: String] = [:]
        var failures: [String] = []

        if createJiraIssues, configuration.isJiraReady {
            let selected = summary.actionItems.enumerated().filter { $0.element.isSelected }
            for (position, (index, item)) in selected.enumerated() {
                onStep(.creatingIssue(index: position + 1, total: selected.count))
                do {
                    let issue = try await jira.createIssue(
                        for: item, meetingTitle: summary.title, pageURL: page.url
                    )
                    enriched.actionItems[index].jiraKey = issue.key
                    createdKeys[item.id.uuidString] = issue.key
                } catch {
                    // Un ticket refusé ne doit pas faire perdre la page déjà publiée.
                    failures.append("« \(item.description.prefix(60)) » — \(error.localizedDescription)")
                }
            }

            if !createdKeys.isEmpty {
                onStep(.linkingIssues)
                try? await confluence.updatePage(
                    id: page.id,
                    title: title,
                    storageBody: ConfluenceStorageRenderer.render(
                        summary: enriched,
                        transcript: transcript,
                        audioNote: audioNote,
                        template: template
                    )
                )
            }
        }

        onStep(.done)
        return PublicationResult(
            pageURL: page.url,
            pageID: page.id,
            issues: createdKeys,
            failures: failures
        )
    }

    private func pageTitle(for summary: MeetingSummary) -> String {
        // Confluence refuse deux pages de même titre dans un espace : la date suffit
        // à les distinguer dans l'écrasante majorité des cas.
        let date = Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash))
        return "\(summary.title) — \(date)"
    }
}
