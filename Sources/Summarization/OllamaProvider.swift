import Foundation

/// Repli entièrement local. Aucune donnée ne quitte la machine — le bon choix pour
/// une réunion sensible, au prix d'une qualité inférieure sur la résolution des dates
/// relatives (mesuré en phase 0).
///
/// On passe par l'API HTTP et non par `ollama run` : le CLI émet des séquences
/// d'échappement ANSI et un bloc « Thinking » qui rendent la sortie inexploitable.
public struct OllamaProvider: SummaryProvider {
    public let model: String
    public let endpoint: URL

    public var displayName: String { "ollama · \(model)" }

    public init(
        model: String = "gemma4",
        endpoint: URL = URL(string: "http://localhost:11434")!
    ) {
        self.model = model
        self.endpoint = endpoint
    }

    public func isAvailable() async -> Bool {
        var request = URLRequest(url: endpoint.appending(path: "api/tags"))
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse
        else { return false }
        return http.statusCode == 200
    }

    public func complete(prompt: String) async throws -> String {
        var request = URLRequest(url: endpoint.appending(path: "api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 900
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "prompt": prompt,
            "stream": false,
            // `think: false` supprime le préambule de raisonnement des modèles récents,
            // `format: json` contraint le décodage côté serveur.
            "think": false,
            "format": "json",
            "options": ["temperature": 0.2, "num_ctx": 16384],
        ])

        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            throw SummaryProviderError.serverUnreachable(endpoint.absoluteString)
        }

        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = payload["response"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw SummaryProviderError.emptyResponse
        }
        return text
    }
}
