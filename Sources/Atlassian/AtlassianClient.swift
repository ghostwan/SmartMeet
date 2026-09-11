import Foundation

/// Page Confluence servant de parent commun, typiquement la page qui agrège un sprint.
/// Elle se fixe une fois en début de sprint : toutes les réunions du sprint s'y
/// rattachent ensuite automatiquement.
public struct SprintPage: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var spaceKey: String
    public var setAt: Date

    public init(id: String, title: String, spaceKey: String, setAt: Date = .now) {
        self.id = id
        self.title = title
        self.spaceKey = spaceKey
        self.setAt = setAt
    }

    /// Accepte un identifiant nu ou une URL Confluence copiée depuis le navigateur.
    ///
    /// Les URL prennent plusieurs formes selon l'ancienneté de la page :
    /// `/wiki/spaces/KEY/pages/12345/Titre`, `/wiki/pages/viewpage.action?pageId=12345`.
    public static func extractPageID(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.allSatisfy(\.isNumber) { return trimmed }

        if let components = URLComponents(string: trimmed) {
            if let pageId = components.queryItems?.first(where: { $0.name == "pageId" })?.value,
               pageId.allSatisfy(\.isNumber) {
                return pageId
            }
            let parts = components.path.split(separator: "/").map(String.init)
            if let index = parts.firstIndex(of: "pages"),
               parts.indices.contains(index + 1),
               parts[index + 1].allSatisfy(\.isNumber) {
                return parts[index + 1]
            }
        }
        return nil
    }
}

/// Réglages de publication. Les identifiants vivent dans le trousseau, jamais ici.
public struct AtlassianConfiguration: Codable, Sendable, Equatable {
    public var site: String
    public var email: String
    public var spaceKey: String
    /// Page sous laquelle publier. Vide = page d'accueil de l'espace.
    public var parentPageID: String
    public var jiraProjectKey: String
    public var jiraIssueType: String
    /// Certains projets imposent un epic parent via un validateur de workflow, ce que
    /// `/createmeta` ne déclare pas. Sans lui, la création échoue en 400.
    public var jiraParentKey: String
    /// Page de sprint courante, parent commun des réunions qui s'y rattachent.
    public var sprintPage: SprintPage?

    public init(
        site: String = ProcessInfo.processInfo.environment["CONFLUENCE_SITE"] ?? "",
        email: String = ProcessInfo.processInfo.environment["ATLASSIAN_EMAIL"] ?? "",
        spaceKey: String = "",
        parentPageID: String = "",
        jiraProjectKey: String = ProcessInfo.processInfo.environment["JIRA_DEFAULT_PROJECT"] ?? "",
        jiraIssueType: String = "Task",
        jiraParentKey: String = "",
        sprintPage: SprintPage? = nil
    ) {
        self.site = site
        self.email = email
        self.spaceKey = spaceKey
        self.parentPageID = parentPageID
        self.jiraProjectKey = jiraProjectKey
        self.jiraIssueType = jiraIssueType
        self.jiraParentKey = jiraParentKey
        self.sprintPage = sprintPage
    }

    public var baseURL: URL? {
        URL(string: "https://\(site).atlassian.net")
    }

    public var isConfluenceReady: Bool {
        !site.isEmpty && !email.isEmpty && !spaceKey.isEmpty
    }

    public var isJiraReady: Bool {
        !site.isEmpty && !email.isEmpty && !jiraProjectKey.isEmpty
    }
}

public enum AtlassianError: LocalizedError {
    case notConfigured(String)
    case missingToken
    case http(status: Int, body: String)
    case unexpectedResponse

    public var errorDescription: String? {
        switch self {
        case .notConfigured(let what):
            "Configuration incomplète : \(what)."
        case .missingToken:
            "Jeton d'API Atlassian absent. Renseigne-le dans les réglages."
        case .http(let status, let body):
            "Atlassian a répondu \(status) — \(body.prefix(300))"
        case .unexpectedResponse:
            "Réponse Atlassian inattendue."
        }
    }
}

/// Client HTTP commun à Confluence et Jira : même hôte, même authentification Basic.
public struct AtlassianClient: Sendable {
    let configuration: AtlassianConfiguration
    let token: String

    public init(configuration: AtlassianConfiguration, token: String) {
        self.configuration = configuration
        self.token = token
    }

    func request(
        _ method: String,
        _ path: String,
        body: [String: Any]? = nil
    ) async throws -> [String: Any] {
        guard let baseURL = configuration.baseURL else {
            throw AtlassianError.notConfigured("site Atlassian")
        }
        guard !token.isEmpty else { throw AtlassianError.missingToken }

        // Concaténation explicite et non `appending(path:)` : cette dernière encode le
        // « ? » en %3F et transforme la query en segment de chemin.
        guard let url = URL(string: baseURL.absoluteString + path) else {
            throw AtlassianError.notConfigured("URL invalide : \(path)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60
        let credentials = Data("\(configuration.email):\(token)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AtlassianError.unexpectedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AtlassianError.http(
                status: http.statusCode,
                body: String(decoding: data, as: UTF8.self)
            )
        }
        guard !data.isEmpty else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
