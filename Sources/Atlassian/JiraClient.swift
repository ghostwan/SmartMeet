import Foundation
import Summarization

public struct JiraIssue: Sendable, Equatable {
    public let key: String
    public let url: URL?
}

public struct JiraClient: Sendable {
    private let client: AtlassianClient
    private let configuration: AtlassianConfiguration

    public init(configuration: AtlassianConfiguration, token: String) {
        self.configuration = configuration
        self.client = AtlassianClient(configuration: configuration, token: token)
    }

    /// Types d'issue disponibles sur le projet, pour peupler les réglages.
    public func issueTypes() async throws -> [String] {
        let payload = try await client.request(
            "GET",
            "/rest/api/3/issue/createmeta/\(configuration.jiraProjectKey)/issuetypes"
        )
        let types = payload["issueTypes"] as? [[String: Any]] ?? []
        return types.compactMap { type in
            guard let name = type["name"] as? String,
                  (type["subtask"] as? Bool) == false
            else { return nil }
            return name
        }
    }

    public func createIssue(
        for item: MeetingSummary.ActionItem,
        meetingTitle: String,
        pageURL: URL?
    ) async throws -> JiraIssue {
        var paragraphs: [[String: Any]] = [
            textParagraph(
                "Action item issu de la réunion « \(meetingTitle) »"
                    + (item.owner.map { ", responsable désigné : \($0)" } ?? "")
                    + "."
            )
        ]
        if let pageURL {
            paragraphs.append(linkParagraph(text: "Compte rendu complet", url: pageURL))
        }

        var fields: [String: Any] = [
            "project": ["key": configuration.jiraProjectKey],
            "issuetype": ["name": configuration.jiraIssueType],
            // Jira refuse un résumé multi-ligne ou trop long.
            "summary": String(item.description.replacingOccurrences(of: "\n", with: " ").prefix(250)),
            "description": ["type": "doc", "version": 1, "content": paragraphs],
        ]
        if let dueDate = item.dueDate, !dueDate.isEmpty {
            fields["duedate"] = dueDate
        }
        if !configuration.jiraParentKey.isEmpty {
            fields["parent"] = ["key": configuration.jiraParentKey]
        }

        let payload = try await client.request("POST", "/rest/api/3/issue", body: ["fields": fields])
        guard let key = payload["key"] as? String else { throw AtlassianError.unexpectedResponse }
        let url = configuration.baseURL.map { $0.appending(path: "browse/\(key)") }
        return JiraIssue(key: key, url: url)
    }

    public func deleteIssue(key: String) async throws {
        _ = try await client.request("DELETE", "/rest/api/3/issue/\(key)")
    }

    private func textParagraph(_ text: String) -> [String: Any] {
        ["type": "paragraph", "content": [["type": "text", "text": text]]]
    }

    private func linkParagraph(text: String, url: URL) -> [String: Any] {
        [
            "type": "paragraph",
            "content": [[
                "type": "text",
                "text": text,
                "marks": [["type": "link", "attrs": ["href": url.absoluteString]]],
            ]],
        ]
    }
}
