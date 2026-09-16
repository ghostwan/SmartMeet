import Foundation

public struct NotionPage: Sendable, Equatable {
    public let id: String
    public let url: URL?
}

public struct NotionDataSourceSummary: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

public struct NotionTaskInput: Sendable, Equatable {
    public let title: String
    public let owner: String?
    public let dueDate: String?
    public let type: String
    public let meetingTitle: String
    public let meetingURL: URL?

    public init(
        title: String,
        owner: String? = nil,
        dueDate: String? = nil,
        type: String,
        meetingTitle: String,
        meetingURL: URL? = nil
    ) {
        self.title = title
        self.owner = owner
        self.dueDate = dueDate
        self.type = type
        self.meetingTitle = meetingTitle
        self.meetingURL = meetingURL
    }
}

public enum NotionError: LocalizedError {
    case notConfigured
    case missingToken
    case http(status: Int, body: String)
    case unexpectedResponse

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            NSLocalizedString(
                "Aucune page Notion parente configurée.",
                bundle: .main,
                value: "Aucune page Notion parente configurée.",
                comment: ""
            )
        case .missingToken:
            NSLocalizedString(
                "Jeton d'intégration Notion absent. Renseigne-le dans les réglages.",
                bundle: .main,
                value: "Jeton d'intégration Notion absent. Renseigne-le dans les réglages.",
                comment: ""
            )
        case .http(let status, let body):
            String(
                format: NSLocalizedString(
                    "Notion a répondu %d — %@", bundle: .main, value: "Notion a répondu %d — %@", comment: ""
                ),
                status, String(body.prefix(300))
            )
        case .unexpectedResponse:
            NSLocalizedString(
                "Réponse Notion inattendue.", bundle: .main, value: "Réponse Notion inattendue.", comment: ""
            )
        }
    }
}

/// Minimal client for the Notion API: minutes pages plus optional tasks in a
/// selected data source.
public struct NotionClient: Sendable {
    private let configuration: NotionConfiguration
    private let token: String
    private static let legacyPageAPIVersion = "2022-06-28"
    private static let dataSourceAPIVersion = "2026-03-11"
    private static let baseURL = URL(string: "https://api.notion.com/v1")!

    public init(configuration: NotionConfiguration, token: String) {
        self.configuration = configuration
        self.token = token
    }

    /// Creates a page under the configured parent page, with the markdown
    /// converted to Notion blocks. Without a configured parent page, the page
    /// is created at the root of the space connected to the integration (the
    /// integration's "private pages" — visible depending on the rights
    /// granted to it). Notion limits the initial creation to 100 child
    /// blocks; the rest is added via successive `PATCH` calls.
    public func createPage(
        title: String,
        markdown: String,
        parentPageID: String? = nil,
        transcript: String? = nil,
        transcriptTitle: String = "Full transcript"
    ) async throws -> NotionPage {
        guard !token.isEmpty else { throw NotionError.missingToken }

        let allBlocks = MarkdownToNotionBlocks.blocks(from: markdown)
        let firstBatch = Array(allBlocks.prefix(MarkdownToNotionBlocks.maxBlocksPerRequest))
        let remaining = Array(allBlocks.dropFirst(MarkdownToNotionBlocks.maxBlocksPerRequest))

        let effectiveParentID = parentPageID ?? configuration.parentPageID
        let parent: [String: Any] = !effectiveParentID.isEmpty
            ? ["page_id": effectiveParentID]
            : ["workspace": true]

        let body: [String: Any] = [
            "parent": parent,
            "properties": [
                "title": [
                    "title": [["text": ["content": title]]]
                ]
            ],
            "children": firstBatch,
        ]

        let response = try await request(
            "POST", "/pages", body: body, apiVersion: Self.legacyPageAPIVersion
        )
        guard let id = response["id"] as? String else { throw NotionError.unexpectedResponse }
        let url = (response["url"] as? String).flatMap(URL.init(string:))

        for batch in stride(from: 0, to: remaining.count, by: MarkdownToNotionBlocks.maxBlocksPerRequest) {
            let chunk = Array(
                remaining[batch..<min(batch + MarkdownToNotionBlocks.maxBlocksPerRequest, remaining.count)]
            )
            _ = try await request("PATCH", "/blocks/\(id)/children", body: ["children": chunk])
        }

        if let transcript,
           !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let transcriptBlocks = MarkdownToNotionBlocks.blocks(from: transcript)
            if !transcriptBlocks.isEmpty {
                let firstChildren = Array(
                    transcriptBlocks.prefix(MarkdownToNotionBlocks.maxBlocksPerRequest)
                )
                let toggleResponse = try await request(
                    "PATCH", "/blocks/\(id)/children",
                    body: ["children": [MarkdownToNotionBlocks.toggle(
                        title: transcriptTitle,
                        children: firstChildren
                    )]]
                )
                let remainingChildren = Array(
                    transcriptBlocks.dropFirst(MarkdownToNotionBlocks.maxBlocksPerRequest)
                )
                if !remainingChildren.isEmpty,
                   let results = toggleResponse["results"] as? [[String: Any]],
                   let toggleID = results.first?["id"] as? String {
                    for offset in stride(
                        from: 0,
                        to: remainingChildren.count,
                        by: MarkdownToNotionBlocks.maxBlocksPerRequest
                    ) {
                        let chunk = Array(remainingChildren[
                            offset..<min(
                                offset + MarkdownToNotionBlocks.maxBlocksPerRequest,
                                remainingChildren.count
                            )
                        ])
                        _ = try await request(
                            "PATCH", "/blocks/\(toggleID)/children",
                            body: ["children": chunk]
                        )
                    }
                }
            }
        }

        return NotionPage(id: id, url: url)
    }

    /// Verifies that the token is valid — and, if a parent page is configured,
    /// that it's accessible to the integration. Without a parent page, only
    /// the token is verified: creation will happen at the root of the space.
    /// Used to validate the settings without creating anything.
    public func verifyAccess() async throws {
        guard !token.isEmpty else { throw NotionError.missingToken }
        if configuration.isConfigured {
            _ = try await request("GET", "/pages/\(configuration.parentPageID)")
        } else {
            _ = try await request("GET", "/users/me")
        }
        if configuration.isTaskDataSourceConfigured {
            _ = try await request("GET", "/data_sources/\(configuration.taskDataSourceID)")
        }
    }

    public func dataSources() async throws -> [NotionDataSourceSummary] {
        guard !token.isEmpty else { throw NotionError.missingToken }
        let response = try await request("POST", "/search", body: [
            "filter": ["property": "object", "value": "data_source"],
            "page_size": 100,
        ])
        let results = response["results"] as? [[String: Any]] ?? []
        return results.compactMap(Self.dataSourceSummary(from:)).sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    public func createTaskDataSource(title: String) async throws -> NotionDataSourceSummary {
        guard !token.isEmpty else { throw NotionError.missingToken }
        guard configuration.isConfigured else { throw NotionError.notConfigured }
        let response = try await request("POST", "/databases", body: [
            "parent": ["type": "page_id", "page_id": configuration.parentPageID],
            "title": [["type": "text", "text": ["content": title]]],
            "is_inline": false,
            "initial_data_source": [
                "properties": [
                    "Name": ["title": [String: Any]()],
                    "Owner": ["rich_text": [String: Any]()],
                    "Due": ["date": [String: Any]()],
                    "Type": ["select": ["options": [Any]()]],
                    "Meeting": ["url": [String: Any]()],
                ],
            ],
        ])
        guard let dataSources = response["data_sources"] as? [[String: Any]],
              let first = dataSources.first,
              let id = first["id"] as? String
        else { throw NotionError.unexpectedResponse }
        return NotionDataSourceSummary(id: id, title: title)
    }

    public func createTask(
        _ input: NotionTaskInput,
        dataSourceID: String
    ) async throws -> NotionPage {
        guard !token.isEmpty else { throw NotionError.missingToken }
        let source = try await request("GET", "/data_sources/\(dataSourceID)")
        let schema = source["properties"] as? [String: [String: Any]] ?? [:]
        guard let titleProperty = schema.first(where: {
            $0.value["type"] as? String == "title"
        })?.key else { throw NotionError.unexpectedResponse }

        var properties: [String: Any] = [
            titleProperty: ["type": "title", "title": [["text": ["content": input.title]]]],
        ]
        Self.setProperty(
            in: &properties, schema: schema, names: ["Owner", "Responsable"],
            type: "rich_text",
            value: input.owner.map {
                ["type": "rich_text", "rich_text": [["text": ["content": $0]]]]
            }
        )
        Self.setProperty(
            in: &properties, schema: schema, names: ["Due", "Due date", "Échéance"],
            type: "date",
            value: input.dueDate.map { ["type": "date", "date": ["start": $0]] }
        )
        Self.setProperty(
            in: &properties, schema: schema, names: ["Type"], type: "select",
            value: ["type": "select", "select": ["name": input.type]]
        )
        Self.setProperty(
            in: &properties, schema: schema, names: ["Meeting", "Réunion"], type: "url",
            value: input.meetingURL.map { ["type": "url", "url": $0.absoluteString] }
        )

        let children: [[String: Any]] = input.meetingURL.map {
            [["object": "block", "type": "bookmark", "bookmark": ["url": $0.absoluteString]]]
        } ?? []
        let response = try await request("POST", "/pages", body: [
            "parent": ["type": "data_source_id", "data_source_id": dataSourceID],
            "properties": properties,
            "children": children,
        ])
        guard let id = response["id"] as? String else { throw NotionError.unexpectedResponse }
        return NotionPage(
            id: id,
            url: (response["url"] as? String).flatMap(URL.init(string:))
        )
    }

    static func dataSourceSummary(from object: [String: Any]) -> NotionDataSourceSummary? {
        guard let id = object["id"] as? String else { return nil }
        let titleItems = object["title"] as? [[String: Any]] ?? []
        let title = titleItems.compactMap { $0["plain_text"] as? String }.joined()
        return NotionDataSourceSummary(id: id, title: title.isEmpty ? id : title)
    }

    private static func setProperty(
        in values: inout [String: Any],
        schema: [String: [String: Any]],
        names: [String],
        type: String,
        value: [String: Any]?
    ) {
        guard let value,
              let name = names.first(where: { schema[$0]?["type"] as? String == type })
        else { return }
        values[name] = value
    }

    private func request(
        _ method: String,
        _ path: String,
        body: [String: Any]? = nil,
        apiVersion: String = Self.dataSourceAPIVersion
    ) async throws -> [String: Any] {
        guard let url = URL(string: Self.baseURL.absoluteString + path) else {
            throw NotionError.unexpectedResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(apiVersion, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NotionError.unexpectedResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw NotionError.http(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        guard !data.isEmpty else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
