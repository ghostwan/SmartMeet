import Foundation

/// A publication service the app can push meeting minutes to. Deliberately
/// small and closed today (only two kinds exist), but the app treats it as an
/// open, growing list rather than hardcoding "Notion" and "Atlassian" as
/// permanent, always-visible settings tabs — adding a third service later
/// only means extending this enum and its two view builders, not restructuring
/// the settings UI.
public enum ServiceKind: String, Codable, Sendable, CaseIterable, Identifiable, Hashable {
    case notion
    case atlassian

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .notion: "Notion"
        case .atlassian: "Atlassian"
        }
    }

    public var symbol: String {
        switch self {
        case .notion: "doc.text.image"
        case .atlassian: "cloud"
        }
    }
}
