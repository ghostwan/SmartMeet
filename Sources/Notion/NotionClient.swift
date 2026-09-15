import Foundation

public struct NotionPage: Sendable, Equatable {
    public let id: String
    public let url: URL?
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

/// Minimal client for the Notion API (an internal integration, a token, a
/// parent page). No Notion database handling: only pages, as children of a
/// page already shared with the integration.
public struct NotionClient: Sendable {
    private let configuration: NotionConfiguration
    private let token: String
    private static let apiVersion = "2022-06-28"
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
    public func createPage(title: String, markdown: String) async throws -> NotionPage {
        guard !token.isEmpty else { throw NotionError.missingToken }

        let allBlocks = MarkdownToNotionBlocks.blocks(from: markdown)
        let firstBatch = Array(allBlocks.prefix(MarkdownToNotionBlocks.maxBlocksPerRequest))
        let remaining = Array(allBlocks.dropFirst(MarkdownToNotionBlocks.maxBlocksPerRequest))

        let parent: [String: Any] = configuration.isConfigured
            ? ["page_id": configuration.parentPageID]
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

        let response = try await request("POST", "/pages", body: body)
        guard let id = response["id"] as? String else { throw NotionError.unexpectedResponse }
        let url = (response["url"] as? String).flatMap(URL.init(string:))

        for batch in stride(from: 0, to: remaining.count, by: MarkdownToNotionBlocks.maxBlocksPerRequest) {
            let chunk = Array(
                remaining[batch..<min(batch + MarkdownToNotionBlocks.maxBlocksPerRequest, remaining.count)]
            )
            _ = try await request("PATCH", "/blocks/\(id)/children", body: ["children": chunk])
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
    }

    private func request(
        _ method: String, _ path: String, body: [String: Any]? = nil
    ) async throws -> [String: Any] {
        guard let url = URL(string: Self.baseURL.absoluteString + path) else {
            throw NotionError.unexpectedResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "Notion-Version")
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
