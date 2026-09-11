import Foundation

/// Un moteur de complétion de texte. L'abstraction est volontairement minimale :
/// aucun provider retenu n'offre de sortie structurée native, tous reçoivent un
/// prompt et rendent du texte dont on extrait le JSON.
public protocol SummaryProvider: Sendable {
    var displayName: String { get }
    /// Vrai si le provider est utilisable sur cette machine (binaire présent,
    /// serveur joignable…).
    func isAvailable() async -> Bool
    func complete(prompt: String) async throws -> String
}

public enum SummaryProviderKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case opencode
    case ollama

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .opencode: "opencode (Copilot)"
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
            "Exécutable introuvable : \(name)."
        case .processFailed(let detail):
            "Le provider a échoué : \(detail)"
        case .emptyResponse:
            "Le provider n'a rien renvoyé."
        case .serverUnreachable(let url):
            "Serveur injoignable : \(url)"
        }
    }
}
