import Foundation
import Summarization

public struct PublicationResult: Sendable, Equatable {
    public let pageURL: URL?
    public let pageID: String
    public let pageTitle: String
    public let spaceKey: String
    public let issues: [String: String]
    public let failures: [String]
}

/// Espace et page parente effectivement retenus, une fois le type de réunion et les
/// réglages combinés.
public struct ResolvedDestination: Sendable, Equatable {
    public let spaceKey: String
    public let spaceID: String
    public let parentPageID: String
    /// Description lisible, affichée avant publication.
    public let description: String
}

public enum PublishStep: Sendable, Equatable {
    case resolvingDestination
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

    /// Combine type de réunion et réglages pour déterminer où publier.
    ///
    /// Priorité : espace du type de réunion, sinon espace par défaut. Pour le parent,
    /// une page de sprint non définie retombe sur la page d'accueil de l'espace
    /// plutôt que d'échouer — mieux vaut un compte rendu mal rangé que perdu.
    public func resolveDestination(for template: MeetingTemplate) async throws -> ResolvedDestination {
        let sprintPage = configuration.sprintPage

        let spaceKey: String = if template.parent.isSprintPage, let sprintPage {
            // La page de sprint dicte son propre espace : publier ailleurs créerait
            // une page orpheline, hors de l'arborescence du sprint.
            sprintPage.spaceKey
        } else if !template.spaceKeyOverride.isEmpty {
            template.spaceKeyOverride
        } else {
            configuration.spaceKey
        }

        guard !spaceKey.isEmpty else {
            throw AtlassianError.notConfigured("espace Confluence")
        }
        let space = try await confluence.space(key: spaceKey)

        switch template.parent {
        case .sprintPage:
            if let sprintPage {
                return ResolvedDestination(
                    spaceKey: spaceKey,
                    spaceID: space.id,
                    parentPageID: sprintPage.id,
                    description: "\(spaceKey) › \(sprintPage.title)"
                )
            }
            return ResolvedDestination(
                spaceKey: spaceKey,
                spaceID: space.id,
                parentPageID: space.homepageID,
                description: "\(spaceKey) › accueil (aucune page de sprint définie)"
            )

        case .page(let id) where !id.isEmpty:
            let parent = try? await confluence.page(id: id)
            return ResolvedDestination(
                spaceKey: spaceKey,
                spaceID: space.id,
                parentPageID: id,
                description: "\(spaceKey) › \(parent?.title ?? id)"
            )

        case .page, .spaceHome:
            let fallback = configuration.parentPageID
            return ResolvedDestination(
                spaceKey: spaceKey,
                spaceID: space.id,
                parentPageID: fallback.isEmpty ? space.homepageID : fallback,
                description: "\(spaceKey) › \(space.name)"
            )
        }
    }

    public func publish(
        summary: MeetingSummary,
        transcript: String,
        audioNote: String?,
        createJiraIssues: Bool,
        template: MeetingTemplate = .generic,
        meetingDate: Date = .now,
        language: SummaryLanguage = .french,
        onStep: @Sendable (PublishStep) -> Void = { _ in }
    ) async throws -> PublicationResult {
        guard configuration.isConfluenceReady || !template.spaceKeyOverride.isEmpty else {
            throw AtlassianError.notConfigured("site, e-mail ou espace Confluence")
        }

        onStep(.resolvingDestination)
        let destination = try await resolveDestination(for: template)

        onStep(.creatingPage)
        let baseTitle = template.pageTitle(
            summaryTitle: summary.title, date: meetingDate, language: language
        )
        var enriched = summary
        let body = ConfluenceStorageRenderer.render(
            summary: enriched,
            transcript: transcript,
            audioNote: audioNote,
            template: template,
            language: language
        )
        let (page, title) = try await createPageResolvingTitleConflict(
            baseTitle: baseTitle,
            storageBody: body,
            destination: destination
        )

        var createdKeys: [String: String] = [:]
        var failures: [String] = []

        if createJiraIssues, configuration.isJiraReady {
            let selected = summary.actionItems.enumerated().filter { $0.element.isSelected }
            for (position, (index, item)) in selected.enumerated() {
                onStep(.creatingIssue(index: position + 1, total: selected.count))
                do {
                    let issue = try await jira.createIssue(
                        for: item, meetingTitle: title, pageURL: page.url
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
                        template: template,
                        language: language
                    )
                )
            }
        }

        onStep(.done)
        return PublicationResult(
            pageURL: page.url,
            pageID: page.id,
            pageTitle: title,
            spaceKey: destination.spaceKey,
            issues: createdKeys,
            failures: failures
        )
    }

    /// Confluence refuse deux pages de même titre dans un espace.
    ///
    /// Les titres sont désormais déterministes (« Daily Lundi 7 septembre 2026 ») :
    /// republier après correction, ou tenir deux réunions du même type le même jour,
    /// se heurte à ce refus. Plutôt que d'échouer et de perdre le compte rendu, on
    /// suffixe le titre.
    private func createPageResolvingTitleConflict(
        baseTitle: String,
        storageBody: String,
        destination: ResolvedDestination
    ) async throws -> (page: ConfluencePage, title: String) {
        for attempt in 1...5 {
            let title = attempt == 1 ? baseTitle : "\(baseTitle) (\(attempt))"
            do {
                let page = try await confluence.createPage(
                    title: title,
                    storageBody: storageBody,
                    spaceID: destination.spaceID,
                    parentID: destination.parentPageID,
                    spaceKey: destination.spaceKey
                )
                return (page, title)
            } catch let error as AtlassianError {
                guard case .http(400, let detail) = error,
                      detail.localizedCaseInsensitiveContains("same TITLE")
                else { throw error }
                continue
            }
        }
        throw AtlassianError.http(
            status: 400,
            body: "Cinq pages portent déjà un titre dérivé de « \(baseTitle) »."
        )
    }
}
