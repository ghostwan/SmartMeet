import Foundation
import Summarization

public struct PublicationResult: Sendable, Equatable {
    public let pageURL: URL?
    public let pageID: String
    public let pageTitle: String
    public let spaceKey: String
    public let issues: [String: String]
    public let failures: [String]
    /// Lien Jira listant tous les tickets créés lors de cette publication, une fois
    /// qu'il y en a au moins un.
    public let jiraSearchURL: URL?
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
            throw AtlassianError.notConfigured(NSLocalizedString("espace Confluence", bundle: .main, value: "espace Confluence", comment: ""))
        }
        let space = try await confluence.space(key: spaceKey)

        switch template.parent {
        case .sprintPage:
            if let sprintPage {
                // La page peut avoir été supprimée côté Confluence depuis qu'elle a été
                // retenue ; mieux vaut échouer clairement ici qu'à la création de page,
                // avec un message qui pointe vers les réglages.
                _ = try await confluence.page(id: sprintPage.id)
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
            let parent = try await confluence.page(id: id)
            return ResolvedDestination(
                spaceKey: spaceKey,
                spaceID: space.id,
                parentPageID: id,
                description: "\(spaceKey) › \(parent.title)"
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
        /// Destination choisie pour cette publication précise (typiquement demandée
        /// à l'utilisateur juste avant de créer les tickets). `nil` retombe sur les
        /// réglages globaux.
        jiraProjectKey: String? = nil,
        jiraParentKey: String? = nil,
        /// Traduit un texte vers l'anglais avant de créer un ticket : les tickets
        /// Jira sont toujours en anglais, indépendamment de la langue du compte
        /// rendu. `nil` laisse le texte tel quel.
        translateForJira: (@Sendable (String) async throws -> String)? = nil,
        /// Nom de l'interlocuteur d'un one-to-one, substitué au jeton `{participant}`
        /// du titre. Ignoré pour tout autre type.
        participantName: String = "",
        /// E-mail de l'interlocuteur d'un one-to-one (`template.requiresParticipant`
        /// vrai). Ignoré pour tout autre type. Sert à restreindre la page publiée à
        /// l'utilisateur et cette seule personne.
        restrictToParticipantEmail: String? = nil,
        onStep: @Sendable (PublishStep) -> Void = { _ in }
    ) async throws -> PublicationResult {
        guard configuration.isConfluenceReady || !template.spaceKeyOverride.isEmpty else {
            throw AtlassianError.notConfigured(NSLocalizedString("site, e-mail ou espace Confluence", bundle: .main, value: "site, e-mail ou espace Confluence", comment: ""))
        }

        onStep(.resolvingDestination)
        let destination = try await resolveDestination(for: template)

        onStep(.creatingPage)
        let baseTitle = template.pageTitle(
            summaryTitle: summary.title, date: meetingDate, language: language,
            participant: participantName
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

        if template.requiresParticipant {
            do {
                var accountIDs = [try await confluence.currentUserAccountID()]
                if let restrictToParticipantEmail, !restrictToParticipantEmail.isEmpty {
                    if let participantAccountID = try await confluence.accountID(
                        forEmail: restrictToParticipantEmail
                    ) {
                        accountIDs.append(participantAccountID)
                    } else {
                        failures.append(NSLocalizedString(
                            "Le compte Confluence de l'interlocuteur n'a pas été trouvé — la page reste restreinte à toi seul.",
                            bundle: .main,
                            value: "Le compte Confluence de l'interlocuteur n'a pas été trouvé — la page reste restreinte à toi seul.",
                            comment: ""
                        ))
                    }
                } else {
                    failures.append(NSLocalizedString(
                        "Aucun e-mail renseigné pour l'interlocuteur — la page reste restreinte à toi seul.",
                        bundle: .main,
                        value: "Aucun e-mail renseigné pour l'interlocuteur — la page reste restreinte à toi seul.",
                        comment: ""
                    ))
                }
                try await confluence.restrictReadAccess(pageID: page.id, accountIDs: accountIDs)
            } catch {
                failures.append(String(
                    format: NSLocalizedString(
                        "La page n'a pas pu être restreinte : %@",
                        bundle: .main,
                        value: "La page n'a pas pu être restreinte : %@",
                        comment: ""
                    ),
                    error.localizedDescription
                ))
            }
        }

        if createJiraIssues, configuration.isJiraReady {
            let englishTitle: String
            if let translateForJira {
                englishTitle = (try? await translateForJira(title)) ?? title
            } else {
                englishTitle = title
            }

            let selected = summary.actionItems.enumerated().filter { $0.element.isSelected }
            for (position, (index, item)) in selected.enumerated() {
                onStep(.creatingIssue(index: position + 1, total: selected.count))
                do {
                    let summaryText: String
                    if let translateForJira {
                        summaryText = (try? await translateForJira(item.description)) ?? item.description
                    } else {
                        summaryText = item.description
                    }
                    let issue = try await jira.createIssue(
                        for: item,
                        summaryText: summaryText,
                        meetingTitle: englishTitle,
                        pageURL: page.url,
                        projectKey: jiraProjectKey,
                        parentKey: jiraParentKey
                    )
                    enriched.actionItems[index].jiraKey = issue.key
                    createdKeys[item.id.uuidString] = issue.key
                } catch {
                    // Un ticket refusé ne doit pas faire perdre la page déjà publiée.
                    failures.append(String(
                        format: NSLocalizedString(
                            "« %@ » — %@", bundle: .main, value: "« %@ » — %@", comment: ""
                        ),
                        String(item.description.prefix(60)), error.localizedDescription
                    ))
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
            failures: failures,
            jiraSearchURL: Self.searchURL(for: createdKeys.values, baseURL: configuration.baseURL)
        )
    }

    /// Lien Jira listant tous les tickets créés, affichable et partageable tel quel.
    private static func searchURL<S: Sequence>(for keys: S, baseURL: URL?) -> URL? where S.Element == String {
        let keys = Array(keys)
        guard !keys.isEmpty, let baseURL else { return nil }
        let jql = "key in (\(keys.joined(separator: ",")))"
        var components = URLComponents(
            url: baseURL.appendingPathComponent("issues"), resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "jql", value: jql)]
        return components?.url
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
            body: String(
                format: NSLocalizedString(
                    "Cinq pages portent déjà un titre dérivé de « %@ ».",
                    bundle: .main,
                    value: "Cinq pages portent déjà un titre dérivé de « %@ ».",
                    comment: ""
                ),
                baseTitle
            )
        )
    }
}
