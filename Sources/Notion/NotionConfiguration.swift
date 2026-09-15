import Foundation

/// Notion publication settings. The integration token lives in the keychain,
/// never here.
public struct NotionConfiguration: Codable, Sendable, Equatable {
    /// Notion page under which to create the meeting minutes.
    public var parentPageID: String
    /// Human-readable label, shown in the settings (title of the pasted page).
    public var parentPageTitle: String

    public init(parentPageID: String = "", parentPageTitle: String = "") {
        self.parentPageID = parentPageID
        self.parentPageTitle = parentPageTitle
    }

    public var isConfigured: Bool { !parentPageID.isEmpty }

    /// Accepts a bare identifier (with or without dashes) or a Notion URL
    /// copied from the browser.
    ///
    /// Notion URLs end with a 32-character hex identifier, with or without
    /// dashes: `.../Page-Title-2ac1f5c4a1b34e6c9a9d8f6f6f6f6f6f`. We take the
    /// last 32 hex characters of the last path segment: simpler and more
    /// robust than splitting on dashes, which would break an identifier
    /// that's already dashed (standard UUID format).
    public static func extractPageID(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate: String
        if let url = URL(string: trimmed), let last = url.path.split(separator: "/").last {
            candidate = String(last)
        } else {
            candidate = trimmed
        }

        let hexOnly = candidate.filter(\.isHexDigit)
        guard hexOnly.count >= 32 else { return nil }
        return format(String(hexOnly.suffix(32)))
    }

    /// Notion accepts the identifier with or without dashes; it's formatted
    /// as a standard UUID, more readable in the settings.
    private static func format(_ hex: String) -> String {
        let chars = Array(hex)
        let groups = [8, 4, 4, 4, 12]
        var index = 0
        var parts: [String] = []
        for length in groups {
            parts.append(String(chars[index..<(index + length)]))
            index += length
        }
        return parts.joined(separator: "-")
    }
}
