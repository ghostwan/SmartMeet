import Foundation

/// A person configured once in Settings for recurring one-to-one meetings,
/// so recording only requires picking them from a list instead of retyping
/// their e-mail and publication page every time.
public struct OneToOnePerson: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    /// Restricts the published Confluence page to the user and this person
    /// only, resolved to an `accountId` at publish time — same mechanism as
    /// the ad hoc e-mail field it replaces.
    public var email: String
    /// `accountId` resolved ahead of time (typically via the "search
    /// Confluence users" picker when first configuring this person). Takes
    /// priority over `email` at publish time: it's already an exact match.
    public var confluenceAccountID: String
    /// Where this person's one-to-one minutes are published, overriding the
    /// meeting type's own destination. `.profileDefault` defers to the
    /// meeting type, exactly like a template with no override.
    public var destination: PublicationDestination
    /// E-mail of the account to add as a watcher on every Jira ticket created
    /// from this person's one-to-one action items — e.g. sharing tickets
    /// with a manager or a shared inbox, regardless of who's assigned.
    public var jiraShareEmail: String

    public init(
        id: String = UUID().uuidString,
        name: String,
        email: String = "",
        confluenceAccountID: String = "",
        destination: PublicationDestination = .profileDefault,
        jiraShareEmail: String = ""
    ) {
        self.id = id
        self.name = name
        self.email = email
        self.confluenceAccountID = confluenceAccountID
        self.destination = destination
        self.jiraShareEmail = jiraShareEmail
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, email, confluenceAccountID, destination, jiraShareEmail
    }

    // Tolerant decoding: a person saved before a field existed should still
    // load, with a sensible default rather than failing the whole array.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        email = try container.decodeIfPresent(String.self, forKey: .email) ?? ""
        confluenceAccountID = try container.decodeIfPresent(
            String.self, forKey: .confluenceAccountID
        ) ?? ""
        destination = try container.decodeIfPresent(
            PublicationDestination.self, forKey: .destination
        ) ?? .profileDefault
        jiraShareEmail = try container.decodeIfPresent(
            String.self, forKey: .jiraShareEmail
        ) ?? ""
    }
}
