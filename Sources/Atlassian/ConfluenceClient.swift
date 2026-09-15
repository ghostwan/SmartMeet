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
/// `acli` n'expose que `confluence page view` : la création passe obligatoirement
/// par l'API REST.
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

        // L'espace peut différer de celui des réglages : un type de réunion peut
        // publier ailleurs, et la page de sprint impose le sien.
        let key = spaceKey ?? configuration.spaceKey
        let url = configuration.baseURL
            .map { $0.appending(path: "wiki/spaces/\(key)/pages/\(id)") }
        return ConfluencePage(id: id, title: title, url: url)
    }

    /// Relit une page pour confirmer qu'elle existe et récupérer son titre. Sert à
    /// valider la page de sprint saisie par l'utilisateur.
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

    /// Espace auquel appartient une page, pour rattacher la page de sprint au bon
    /// espace sans obliger l'utilisateur à le saisir.
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

    /// Compte associé au jeton API utilisé pour publier — la façon la plus fiable de
    /// résoudre « moi » en `accountId`, sans dépendre d'une recherche par e-mail
    /// potentiellement bridée (voir `accountID(forEmail:)`).
    public func currentUserAccountID() async throws -> String {
        let payload = try await client.request("GET", "/wiki/rest/api/user/current")
        let id = payload["accountId"] as? String ?? ""
        guard !id.isEmpty else { throw AtlassianError.unexpectedResponse }
        return id
    }

    /// Résout un e-mail en `accountId` Confluence Cloud, pour restreindre une page à
    /// une personne précise.
    ///
    /// Non garanti : certains sites Cloud bornent la recherche d'utilisateurs par
    /// e-mail pour des raisons de confidentialité (RGPD), en particulier si le jeton
    /// utilisé n'a pas de droits d'administration. On renvoie alors `nil` plutôt que
    /// de faire échouer toute la publication — restreindre la page à l'utilisateur
    /// seul reste préférable à ne pas la restreindre du tout.
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

    /// Restreint la lecture d'une page aux seuls comptes indiqués — le reste de
    /// l'espace ne la voit plus. Utilisé pour les types « one-to-one », dont la
    /// page n'a de sens que pour l'utilisateur et un·e seul·e interlocuteur·rice.
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

    /// Réécrit le corps d'une page. Confluence exige le numéro de version suivant,
    /// d'où la relecture préalable.
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

    /// L'API v2 renvoie les identifiants tantôt en nombre, tantôt en chaîne.
    private func string(_ value: Any?) -> String {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }
}
