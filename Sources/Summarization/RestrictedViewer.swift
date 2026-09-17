import Foundation

/// A person allowed to see a published Confluence page in addition to its
/// author — independent of the one-to-one mechanism (`MeetingTemplate.
/// requiresParticipant`), which restricts to exactly one fixed counterpart.
/// This one applies to any meeting type: a Daily or a Synchro can carry
/// sensitive material just as well as a one-to-one, and the whole space
/// shouldn't always see it by default.
public struct RestrictedViewer: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: String { accountID }
    public var displayName: String
    /// Not always available (profile visibility settings): display only,
    /// `accountID` is what actually restricts the page.
    public var email: String?
    /// Confluence Cloud `accountId`, resolved via the "search Confluence
    /// users" picker at the time this person was added — the only thing
    /// `ConfluenceClient.restrictReadAccess` needs.
    public var accountID: String

    public init(displayName: String, email: String? = nil, accountID: String) {
        self.displayName = displayName
        self.email = email
        self.accountID = accountID
    }

    private enum CodingKeys: String, CodingKey {
        case displayName, email, accountID
    }

    // Tolerant decoding: a viewer saved before a field existed should still
    // load, with a sensible default rather than failing the whole array.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        email = try container.decodeIfPresent(String.self, forKey: .email)
        accountID = try container.decodeIfPresent(String.self, forKey: .accountID) ?? ""
    }
}
