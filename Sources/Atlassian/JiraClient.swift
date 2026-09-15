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

    /// Issue types available on the project, to populate the settings.
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

    /// Creates the Jira ticket corresponding to an action item.
    ///
    /// Tickets are always written in English, regardless of the meeting
    /// minutes' language: `summaryText` and `meetingTitle` are therefore
    /// expected to already be translated by the caller. `projectKey` and
    /// `parentKey` allow choosing the destination at creation time rather than
    /// depending solely on the global settings.
    public func createIssue(
        for item: MeetingSummary.ActionItem,
        summaryText: String,
        meetingTitle: String,
        pageURL: URL?,
        projectKey: String? = nil,
        issueTypeName: String? = nil,
        parentKey: String? = nil
    ) async throws -> JiraIssue {
        var paragraphs: [[String: Any]] = [
            textParagraph(
                "Action item from meeting \"\(meetingTitle)\""
                    + (item.owner.map { ", assigned to: \($0)" } ?? "")
                    + "."
            )
        ]
        if let pageURL {
            paragraphs.append(linkParagraph(text: "Full meeting minutes", url: pageURL))
        }

        let resolvedProjectKey = projectKey?.isEmpty == false ? projectKey! : configuration.jiraProjectKey
        let resolvedIssueType = issueTypeName?.isEmpty == false
            ? issueTypeName!
            : item.issueType.defaultJiraIssueTypeName
        let resolvedParentKey = parentKey?.isEmpty == false ? parentKey! : configuration.jiraParentKey

        var fields: [String: Any] = [
            "project": ["key": resolvedProjectKey],
            "issuetype": ["name": resolvedIssueType],
            // Jira rejects a multi-line or overly long summary.
            "summary": String(summaryText.replacingOccurrences(of: "\n", with: " ").prefix(250)),
            "description": ["type": "doc", "version": 1, "content": paragraphs],
        ]
        if let dueDate = item.dueDate, !dueDate.isEmpty {
            fields["duedate"] = dueDate
        }
        if !resolvedParentKey.isEmpty {
            fields["parent"] = ["key": resolvedParentKey]
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
