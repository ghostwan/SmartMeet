import Foundation

public struct ConfluencePage: Sendable, Equatable {
    public let id: String
    public let title: String
    public let url: URL?
}

public struct ConfluenceSpaceSummary: Sendable, Identifiable, Equatable {
    public let id: String
    public let key: String
    public let name: String
    public let homepageID: String
}

/// Confluence Cloud, API v2.
///
/// `acli` only exposes `confluence page view`: creation necessarily goes
/// through the REST API.
public struct ConfluenceClient: Sendable {
    private let client: AtlassianClient
    private let configuration: AtlassianConfiguration

    public init(configuration: AtlassianConfiguration, token: String) {
        self.configuration = configuration
        self.client = AtlassianClient(configuration: configuration, token: token)
    }

    public func spaces(limit: Int = 250) async throws -> [ConfluenceSpaceSummary] {
        let payload = try await client.request("GET", "/wiki/api/v2/spaces?limit=\(limit)")
        let results = payload["results"] as? [[String: Any]] ?? []
        return results.compactMap { item in
            guard let key = item["key"] as? String, let name = item["name"] as? String
            else { return nil }
            return ConfluenceSpaceSummary(
                id: string(item["id"]),
                key: key,
                name: name,
                homepageID: string(item["homepageId"])
            )
        }
    }

    public func space(key: String) async throws -> ConfluenceSpaceSummary {
        let payload = try await client.request("GET", "/wiki/api/v2/spaces?keys=\(key)")
        guard let first = (payload["results"] as? [[String: Any]])?.first else {
            throw AtlassianError.notConfigured(String(format: NSLocalizedString("espace %@ introuvable", bundle: .main, value: "espace %@ introuvable", comment: ""), key))
        }
        return ConfluenceSpaceSummary(
            id: string(first["id"]),
            key: key,
            name: first["name"] as? String ?? key,
            homepageID: string(first["homepageId"])
        )
    }

    public func createPage(
        title: String,
        storageBody: String,
        spaceID: String,
        parentID: String?,
        spaceKey: String? = nil
    ) async throws -> ConfluencePage {
        var body: [String: Any] = [
            "spaceId": spaceID,
            "status": "current",
            "title": title,
            "body": ["representation": "storage", "value": storageBody],
        ]
        if let parentID, !parentID.isEmpty { body["parentId"] = parentID }

        let payload = try await client.request("POST", "/wiki/api/v2/pages", body: body)
        let id = string(payload["id"])
        guard !id.isEmpty else { throw AtlassianError.unexpectedResponse }

        // The space may differ from the settings' one: a meeting type can
        // publish elsewhere, and the sprint page imposes its own.
        let key = spaceKey ?? configuration.spaceKey
        let url = configuration.baseURL
            .map { $0.appending(path: "wiki/spaces/\(key)/pages/\(id)") }
        return ConfluencePage(id: id, title: title, url: url)
    }

    /// Re-reads a page to confirm it exists and retrieve its title. Used to
    /// validate the sprint page entered by the user.
    public func page(id: String) async throws -> ConfluencePage {
        let payload: [String: Any]
        do {
            payload = try await client.request("GET", "/wiki/api/v2/pages/\(id)")
        } catch AtlassianError.http(404, _) {
            throw AtlassianError.pageNotFound(id: id)
        }
        let title = payload["title"] as? String ?? ""
        guard !title.isEmpty else { throw AtlassianError.unexpectedResponse }
        let spaceID = string(payload["spaceId"])
        let url = configuration.baseURL.map { $0.appending(path: "wiki/spaces/\(spaceID)/pages/\(id)") }
        return ConfluencePage(id: id, title: title, url: url)
    }

    /// Space a page belongs to, used to attach the sprint page to the right
    /// space without requiring the user to enter it.
    public func spaceKey(forPage id: String) async throws -> String {
        let payload = try await client.request("GET", "/wiki/api/v2/pages/\(id)")
        let spaceID = string(payload["spaceId"])
        guard !spaceID.isEmpty else { return configuration.spaceKey }
        let space = try await client.request("GET", "/wiki/api/v2/spaces/\(spaceID)")
        return space["key"] as? String ?? configuration.spaceKey
    }

    public func deletePage(id: String) async throws {
        _ = try await client.request("DELETE", "/wiki/api/v2/pages/\(id)")
    }

    /// Account tied to the API token used to publish — the most reliable way to
    /// resolve "me" into an `accountId`, without relying on an e-mail search
    /// that could potentially be restricted (see `accountID(forEmail:)`).
    public func currentUserAccountID() async throws -> String {
        let payload = try await client.request("GET", "/wiki/rest/api/user/current")
        let id = payload["accountId"] as? String ?? ""
        guard !id.isEmpty else { throw AtlassianError.unexpectedResponse }
        return id
    }

    /// Resolves an e-mail into a Confluence Cloud `accountId`, to restrict a
    /// page to a specific person.
    ///
    /// Not guaranteed: some Cloud sites limit user search by e-mail for
    /// privacy reasons (GDPR), especially if the token used lacks admin
    /// rights. `nil` is then returned rather than failing the whole
    /// publication — restricting the page to the user alone is still
    /// preferable to not restricting it at all.
    public func accountID(forEmail email: String) async throws -> String? {
        guard let encodedCQL = "user.emailAddress=\"\(email)\""
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else { return nil }
        guard let payload = try? await client.request(
            "GET", "/wiki/rest/api/search/user?cql=\(encodedCQL)"
        ) else { return nil }
        let results = payload["results"] as? [[String: Any]] ?? []
        guard let first = results.first else { return nil }
        let user = (first["user"] as? [String: Any]) ?? first
        return user["accountId"] as? String
    }

    /// Restricts read access of a page to the given accounts only — the rest
    /// of the space no longer sees it. Used for "one-to-one" types, whose
    /// page only makes sense for the user and a single counterpart.
    public func restrictReadAccess(pageID: String, accountIDs: [String]) async throws {
        let users = accountIDs.map { ["type": "known", "accountId": $0] }
        let body: [String: Any] = [
            "results": [
                [
                    "operation": "read",
                    "restrictions": [
                        "user": users,
                        "group": ["results": []],
                    ],
                ]
            ]
        ]
        _ = try await client.request(
            "PUT", "/wiki/rest/api/content/\(pageID)/restriction", body: body
        )
    }

    /// Rewrites a page's body. Confluence requires the next version number,
    /// hence the preliminary re-read.
    public func updatePage(id: String, title: String, storageBody: String) async throws {
        let current = try await client.request("GET", "/wiki/api/v2/pages/\(id)")
        let version = (current["version"] as? [String: Any])?["number"] as? Int ?? 1

        _ = try await client.request(
            "PUT",
            "/wiki/api/v2/pages/\(id)",
            body: [
                "id": id,
                "status": "current",
                "title": title,
                "body": ["representation": "storage", "value": storageBody],
                "version": ["number": version + 1, "message": "Clés Jira ajoutées par SmartMeet"],
            ]
        )
    }

    /// The v2 API returns identifiers sometimes as a number, sometimes as a string.
    private func string(_ value: Any?) -> String {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }
}
