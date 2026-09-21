import Foundation

public struct ConfluencePage: Sendable, Equatable {
    public let id: String
    public let title: String
    public let spaceID: String
    public let spaceKey: String
    public let url: URL?
}

public struct ConfluenceSpaceSummary: Sendable, Identifiable, Equatable {
    public let id: String
    public let key: String
    public let name: String
    public let homepageID: String
}

/// A Confluence account found while searching users by name — used to let
/// the user pick the one-to-one counterpart from a quick list instead of
/// typing their e-mail (which the search-by-email endpoint can silently fail
/// to resolve, see `accountID(forEmail:)`).
public struct ConfluenceUserMatch: Sendable, Identifiable, Equatable {
    public var id: String { accountID }
    public let accountID: String
    public let displayName: String
    /// Not always returned (profile visibility settings): the caller falls
    /// back to restricting by `accountID` directly rather than requiring it.
    public let email: String?
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
        return ConfluencePage(
            id: id, title: title, spaceID: spaceID, spaceKey: key, url: url
        )
    }

    /// Re-reads a page to confirm it exists and retrieve its title. Used to
    /// validate the destination page entered by the user.
    ///
    /// Falls back to the folders endpoint if the ID doesn't match a page:
    /// a Confluence *folder* is a distinct content type from a page in the
    /// v2 API (`/wiki/api/v2/folders/{id}` rather than `/pages/{id}`), but
    /// the create-page endpoint accepts either one as `parentId` — nothing
    /// stops minutes from being published as a child of a folder.
    public func page(id: String) async throws -> ConfluencePage {
        do {
            return try await fetchPage(id: id)
        } catch AtlassianError.http(404, _) {
            return try await fetchFolder(id: id)
        }
    }

    private func fetchPage(id: String) async throws -> ConfluencePage {
        let payload = try await client.request("GET", "/wiki/api/v2/pages/\(id)")
        let title = payload["title"] as? String ?? ""
        guard !title.isEmpty else { throw AtlassianError.unexpectedResponse }
        let spaceID = string(payload["spaceId"])
        let spacePayload = try await client.request("GET", "/wiki/api/v2/spaces/\(spaceID)")
        let spaceKey = spacePayload["key"] as? String ?? ""
        let url = configuration.baseURL.map {
            $0.appending(path: "wiki/spaces/\(spaceKey)/pages/\(id)")
        }
        return ConfluencePage(
            id: id, title: title, spaceID: spaceID, spaceKey: spaceKey, url: url
        )
    }

    private func fetchFolder(id: String) async throws -> ConfluencePage {
        let payload: [String: Any]
        do {
            payload = try await client.request("GET", "/wiki/api/v2/folders/\(id)")
        } catch AtlassianError.http(404, _) {
            throw AtlassianError.pageNotFound(id: id)
        }
        let title = payload["title"] as? String ?? ""
        guard !title.isEmpty else { throw AtlassianError.unexpectedResponse }
        let spaceID = string(payload["spaceId"])
        let spacePayload = try await client.request("GET", "/wiki/api/v2/spaces/\(spaceID)")
        let spaceKey = spacePayload["key"] as? String ?? ""
        let url = configuration.baseURL.map {
            $0.appending(path: "wiki/spaces/\(spaceKey)/folder/\(id)")
        }
        return ConfluencePage(
            id: id, title: title, spaceID: spaceID, spaceKey: spaceKey, url: url
        )
    }

    public func personalSpace() async throws -> ConfluenceSpaceSummary {
        let payload = try await client.request(
            "GET", "/wiki/rest/api/user/current?expand=personalSpace,personalSpace.homepage"
        )
        guard let personal = payload["personalSpace"] as? [String: Any] else {
            throw AtlassianError.notConfigured(NSLocalizedString(
                "page Confluence par défaut ou espace personnel",
                bundle: .main,
                value: "page Confluence par défaut ou espace personnel",
                comment: ""
            ))
        }
        let homepage = personal["homepage"] as? [String: Any]
        let id = string(personal["id"])
        let key = personal["key"] as? String ?? ""
        let homepageID = string(homepage?["id"])
        guard !id.isEmpty, !key.isEmpty, !homepageID.isEmpty else {
            throw AtlassianError.unexpectedResponse
        }
        return ConfluenceSpaceSummary(
            id: id,
            key: key,
            name: personal["name"] as? String ?? key,
            homepageID: homepageID
        )
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

    /// Quick "who is this" search, for a one-to-one counterpart picker or any
    /// other "restrict this page to…" picker — faster and more forgiving than
    /// requiring the exact e-mail up front.
    ///
    /// Two searches are combined rather than picking one field: the `~` fuzzy
    /// operator is only supported on `user.fullname` (see Confluence's CQL
    /// field reference), so typing a full e-mail address into the same field
    /// as a name — which every UI using this method invites the user to do,
    /// since the field sits right next to a plain e-mail `TextField` — would
    /// otherwise silently never match anything. `user.emailAddress` only
    /// supports exact equality, so it only ever contributes a result once the
    /// address is fully typed; until then the fullname search alone carries
    /// the as-you-type results.
    ///
    /// Best effort like `accountID(forEmail:)`: an empty array is returned
    /// rather than throwing if the query is too short or a search is
    /// unavailable, so a keystroke-by-keystroke search field never surfaces a
    /// hard error.
    public func searchUsers(matching query: String, limit: Int = 8) async throws -> [ConfluenceUserMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return [] }

        async let byName = matches(cql: "user.fullname~\"\(trimmed)\"", limit: limit)
        async let byEmail = matches(cql: "user.emailAddress=\"\(trimmed)\"", limit: limit)

        // E-mail results first: an exact match is a stronger signal than a
        // fuzzy name match, and deduplication below keeps only the first
        // occurrence of each account.
        var seen = Set<String>()
        var merged: [ConfluenceUserMatch] = []
        for match in await byEmail + (await byName) {
            guard seen.insert(match.accountID).inserted else { continue }
            merged.append(match)
        }
        return Array(merged.prefix(limit))
    }

    /// Runs one CQL user search and maps the raw payload into
    /// `ConfluenceUserMatch`. Shared by both branches of `searchUsers(matching:)`.
    /// Best effort: an invalid CQL (e.g. `emailAddress="not an e-mail"`) or an
    /// unavailable search returns an empty array rather than throwing.
    private func matches(cql: String, limit: Int) async -> [ConfluenceUserMatch] {
        guard let encodedCQL = cql.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else { return [] }
        guard let payload = try? await client.request(
            "GET", "/wiki/rest/api/search/user?cql=\(encodedCQL)&limit=\(limit)"
        ) else { return [] }
        let results = payload["results"] as? [[String: Any]] ?? []
        return results.compactMap { result in
            let user = (result["user"] as? [String: Any]) ?? result
            guard let accountID = user["accountId"] as? String, !accountID.isEmpty else { return nil }
            let displayName = user["displayName"] as? String ?? user["publicName"] as? String ?? accountID
            return ConfluenceUserMatch(accountID: accountID, displayName: displayName, email: user["email"] as? String)
        }
    }

    /// Restricts a page to the given accounts only — the rest of the space no
    /// longer sees it. Used for "one-to-one" types and for `RestrictedViewer`
    /// lists, whose page only makes sense for the author and a chosen few.
    ///
    /// Sets both the `read` and `update` operations to the same accounts:
    /// leaving `update` untouched (as an earlier version of this method did)
    /// results in an empty restriction on it, which Confluence treats as
    /// "nobody can edit" — not "unrestricted" — locking the author themselves
    /// out of the very page they just published (see the incident this fixed:
    /// the account tied to the API token, not necessarily the author, was the
    /// only one able to write).
    public func restrictAccess(pageID: String, accountIDs: [String]) async throws {
        let users = accountIDs.map { ["type": "known", "accountId": $0] }
        let restrictions: [String: Any] = ["user": users, "group": ["results": []]]
        let body: [String: Any] = [
            "results": [
                ["operation": "read", "restrictions": restrictions],
                ["operation": "update", "restrictions": restrictions],
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
