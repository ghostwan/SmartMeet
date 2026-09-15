import Foundation

/// A text completion engine. The abstraction is deliberately minimal: none of
/// the chosen providers offer native structured output, they all receive a
/// prompt and return text from which the JSON is extracted.
public protocol SummaryProvider: Sendable {
    var displayName: String { get }
    /// True if the provider is usable on this machine (binary present,
    /// server reachable…).
    func isAvailable() async -> Bool
    func complete(prompt: String) async throws -> SummaryCompletion
    /// Maximum size (in transcript characters) beyond which `SummaryGenerator`
    /// must switch to map-reduce chunking, when the provider's context window
    /// is narrower than its generic threshold. `nil` (the default) lets
    /// `SummaryGenerator` use its own threshold.
    var maxPromptCharacters: Int? { get }
}

extension SummaryProvider {
    public var maxPromptCharacters: Int? { nil }
}

public enum SummaryProviderKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case opencode
    case copilotACP
    case appleOnDevice
    case ollama

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .opencode: "opencode (Copilot)"
        case .copilotACP: "copilot (ACP)"
        case .appleOnDevice: "Apple Intelligence (local)"
        case .ollama: "ollama (local)"
        }
    }
}

public enum SummaryProviderError: LocalizedError {
    case executableNotFound(String)
    case processFailed(String)
    case emptyResponse
    case serverUnreachable(String)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound(let name):
            String(
                format: NSLocalizedString(
                    "Exécutable introuvable : %@.", bundle: .main, value: "Exécutable introuvable : %@.", comment: ""
                ),
                name
            )
        case .processFailed(let detail):
            String(
                format: NSLocalizedString(
                    "Le provider a échoué : %@", bundle: .main, value: "Le provider a échoué : %@", comment: ""
                ),
                detail
            )
        case .emptyResponse:
            NSLocalizedString(
                "Le provider n'a rien renvoyé.", bundle: .main, value: "Le provider n'a rien renvoyé.", comment: ""
            )
        case .serverUnreachable(let url):
            String(
                format: NSLocalizedString(
                    "Serveur injoignable : %@", bundle: .main, value: "Serveur injoignable : %@", comment: ""
                ),
                url
            )
        }
    }
}
