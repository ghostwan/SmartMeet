import Foundation

/// Confluence page acting as a common parent, typically the page that
/// aggregates a sprint. It's set once at the start of a sprint: every meeting
/// of the sprint then attaches to it automatically.
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

    /// Accepts a bare identifier or a Confluence URL copied from the browser.
    ///
    /// URLs take several forms depending on the page's age:
    /// `/wiki/spaces/KEY/pages/12345/Title`, `/wiki/pages/viewpage.action?pageId=12345`.
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

/// Publication settings. Identifiers live in the keychain, never here.
public struct AtlassianConfiguration: Codable, Sendable, Equatable {
    public var site: String
    public var email: String
    public var spaceKey: String
    /// Page under which to publish. Empty = the space's home page.
    public var parentPageID: String
    public var jiraProjectKey: String
    public var jiraIssueType: String
    /// Some projects require a parent epic via a workflow validator, which
    /// `/createmeta` doesn't declare. Without it, creation fails with a 400.
    public var jiraParentKey: String
    /// Current sprint page, the common parent for meetings attached to it.
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
    /// The targeted page (sprint or explicit parent) no longer exists on
    /// Confluence's side.
    case pageNotFound(id: String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured(let what):
            String(
                format: NSLocalizedString(
                    "Configuration incomplète : %@.", bundle: .main, value: "Configuration incomplète : %@.", comment: ""
                ),
                what
            )
        case .missingToken:
            NSLocalizedString(
                "Jeton d'API Atlassian absent. Renseigne-le dans les réglages.",
                bundle: .main,
                value: "Jeton d'API Atlassian absent. Renseigne-le dans les réglages.",
                comment: ""
            )
        case .http(let status, let body):
            String(
                format: NSLocalizedString(
                    "Atlassian a répondu %d — %@", bundle: .main, value: "Atlassian a répondu %d — %@", comment: ""
                ),
                status, String(body.prefix(300))
            )
        case .unexpectedResponse:
            NSLocalizedString(
                "Réponse Atlassian inattendue.", bundle: .main, value: "Réponse Atlassian inattendue.", comment: ""
            )
        case .pageNotFound(let id):
            String(
                format: NSLocalizedString(
                    "La page Confluence %@ est introuvable (supprimée ou déplacée). Vérifie la page de sprint dans les réglages.",
                    bundle: .main,
                    value: "La page Confluence %@ est introuvable (supprimée ou déplacée). Vérifie la page de sprint dans les réglages.",
                    comment: ""
                ),
                id
            )
        }
    }
}

/// HTTP client common to Confluence and Jira: same host, same Basic authentication.
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
            throw AtlassianError.notConfigured(NSLocalizedString("site Atlassian", bundle: .main, value: "site Atlassian", comment: ""))
        }
        guard !token.isEmpty else { throw AtlassianError.missingToken }

        // Explicit concatenation rather than `appending(path:)`: the latter
        // encodes "?" as %3F and turns the query into a path segment.
        guard let url = URL(string: baseURL.absoluteString + path) else {
            throw AtlassianError.notConfigured(String(format: NSLocalizedString("URL invalide : %@", bundle: .main, value: "URL invalide : %@", comment: ""), path))
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
