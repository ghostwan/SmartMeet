import Foundation
import Summarization

public struct PublicationResult: Sendable, Equatable {
    public let pageURL: URL?
    public let pageID: String
    public let pageTitle: String
    public let spaceKey: String
    public let issues: [String: String]
    public let failures: [String]
    /// Jira link listing every ticket created during this publication, once
    /// there's at least one.
    public let jiraSearchURL: URL?
}

/// Space and parent page actually chosen, once the meeting type and settings
/// have been combined.
public struct ResolvedDestination: Sendable, Equatable {
    public let spaceKey: String
    public let spaceID: String
    public let parentPageID: String
    /// Human-readable description, shown before publication.
    public let description: String
}

public enum PublishStep: Sendable, Equatable {
    case resolvingDestination
    case creatingPage
    case creatingIssue(index: Int, total: Int)
    case linkingIssues
    case done
}

/// Chains the Confluence publication followed by Jira.
///
/// Order chosen: page first (without the keys), tickets next with a link back
/// to it, then the page is rewritten with the keys. This is the only order
/// that produces a two-way link; the reverse would leave the tickets orphaned.
public struct PublishService: Sendable {
    private let configuration: AtlassianConfiguration
    private let confluence: ConfluenceClient
    private let jira: JiraClient

    public init(configuration: AtlassianConfiguration, token: String) {
        self.configuration = configuration
        self.confluence = ConfluenceClient(configuration: configuration, token: token)
        self.jira = JiraClient(configuration: configuration, token: token)
    }

    /// Combines the meeting type and settings to determine where to publish.
    ///
    /// Priority: the meeting type's space, falling back to the default space.
    /// For the parent, an unset sprint page falls back to the space's home
    /// page rather than failing outright — a poorly filed report beats a lost
    /// one.
    public func resolveDestination(
        _ destination: PublicationDestination
    ) async throws -> ResolvedDestination {
        let pageID: String? = switch destination {
        case .page(let id) where !id.isEmpty: id
        case .page, .profileDefault: configuration.parentPageID.isEmpty
            ? nil
            : configuration.parentPageID
        }

        if let pageID {
            let page = try await confluence.page(id: pageID)
            return ResolvedDestination(
                spaceKey: page.spaceKey,
                spaceID: page.spaceID,
                parentPageID: page.id,
                description: "\(page.spaceKey) › \(page.title)"
            )
        }

        let space = try await confluence.personalSpace()
        return ResolvedDestination(
            spaceKey: space.key,
            spaceID: space.id,
            parentPageID: space.homepageID,
            description: "\(space.key) › \(space.name)"
        )
    }

    public func publish(
        summary: MeetingSummary,
        transcript: String,
        audioNote: String?,
        createJiraIssues: Bool,
        template: MeetingTemplate = .generic,
        meetingDate: Date = .now,
        language: SummaryLanguage = .french,
        includeTranscript: Bool = true,
        destination: PublicationDestination? = nil,
        /// Destination chosen for this specific publication (typically asked of
        /// the user right before creating the tickets). `nil` falls back to the
        /// global settings.
        jiraProjectKey: String? = nil,
        jiraParentKey: String? = nil,
        /// Translates a text into English before creating a ticket: Jira tickets
        /// are always in English, regardless of the meeting minutes' language.
        /// `nil` leaves the text as is.
        translateForJira: (@Sendable (String) async throws -> String)? = nil,
        /// Name of the one-to-one's counterpart, substituted for the
        /// `{participant}` token in the title. Ignored for any other type.
        participantName: String = "",
        /// E-mail of the one-to-one's counterpart (`template.requiresParticipant`
        /// true). Ignored for any other type. Used to restrict the published
        /// page to the user and that one person only.
        restrictToParticipantEmail: String? = nil,
        /// `accountId` resolved ahead of time (typically via the "search
        /// Confluence users" picker). Takes priority over
        /// `restrictToParticipantEmail`: it's already an exact match, so
        /// there's no need to fall back to the less reliable e-mail search.
        restrictToParticipantAccountID: String? = nil,
        /// Confluence `accountId`s of extra people allowed to view the page,
        /// in addition to its author — independent of `template.
        /// requiresParticipant`, applicable to any meeting type. Resolved
        /// ahead of time (via the "search Confluence users" picker), same as
        /// `restrictToParticipantAccountID`.
        restrictedViewerAccountIDs: [String] = [],
        /// E-mail to add as a watcher on every Jira ticket created during
        /// this publication, e.g. a one-to-one counterpart configured to
        /// always see their tickets regardless of who's assigned. Resolved
        /// to an `accountId` once and reused for every ticket rather than
        /// per-ticket, since it never changes within a single publication.
        jiraShareEmail: String? = nil,
        onStep: @Sendable (PublishStep) -> Void = { _ in }
    ) async throws -> PublicationResult {
        guard configuration.isConfluenceReady else {
            throw AtlassianError.notConfigured(NSLocalizedString("site ou e-mail Confluence", bundle: .main, value: "site ou e-mail Confluence", comment: ""))
        }

        onStep(.resolvingDestination)
        let destination = try await resolveDestination(destination ?? template.destination)

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
            language: language,
            includeTranscript: includeTranscript
        )
        let (page, title) = try await createPageResolvingTitleConflict(
            baseTitle: baseTitle,
            storageBody: body,
            destination: destination
        )

        var createdKeys: [String: String] = [:]
        var failures: [String] = []

        if template.requiresParticipant || !restrictedViewerAccountIDs.isEmpty {
            do {
                var accountIDs = [try await confluence.currentUserAccountID()]
                accountIDs.append(contentsOf: restrictedViewerAccountIDs)
                if template.requiresParticipant {
                    if let restrictToParticipantAccountID, !restrictToParticipantAccountID.isEmpty {
                        accountIDs.append(restrictToParticipantAccountID)
                    } else if let restrictToParticipantEmail, !restrictToParticipantEmail.isEmpty {
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
                }
                try await confluence.restrictAccess(pageID: page.id, accountIDs: Array(Set(accountIDs)))
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

            // Resolved once and reused for every ticket: an e-mail search
            // failure (GDPR-restricted site, unknown address…) shouldn't be
            // retried per ticket, and shouldn't cost the tickets themselves —
            // only the sharing is skipped.
            var jiraShareAccountID: String?
            if let jiraShareEmail, !jiraShareEmail.isEmpty {
                jiraShareAccountID = try? await jira.accountID(forEmail: jiraShareEmail)
                if jiraShareAccountID == nil {
                    failures.append(NSLocalizedString(
                        "Le compte Jira à qui partager les tickets n'a pas été trouvé — les tickets restent visibles de la seule personne assignée.",
                        bundle: .main,
                        value: "Le compte Jira à qui partager les tickets n'a pas été trouvé — les tickets restent visibles de la seule personne assignée.",
                        comment: ""
                    ))
                }
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
                    if let jiraShareAccountID {
                        try? await jira.addWatcher(issueKey: issue.key, accountID: jiraShareAccountID)
                    }
                } catch {
                    // A rejected ticket must not cost the already-published page.
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
                        language: language,
                        includeTranscript: includeTranscript
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

    /// Jira link listing every created ticket, displayable and shareable as is.
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

    /// Confluence refuses two pages with the same title in a space.
    ///
    /// Titles are now deterministic ("Daily Monday September 7, 2026"):
    /// republishing after a correction, or holding two meetings of the same
    /// type on the same day, runs into this rejection. Rather than failing and
    /// losing the meeting minutes, the title is suffixed.
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
