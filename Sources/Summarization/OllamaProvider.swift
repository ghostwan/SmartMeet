import Foundation

/// Fully local fallback. No data leaves the machine — the right choice for a
/// sensitive meeting, at the cost of lower quality on relative date resolution
/// (measured in phase 0).
///
/// We go through the HTTP API rather than `ollama run`: the CLI emits ANSI
/// escape sequences and a "Thinking" block that make the output unusable.
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

    public func complete(prompt: String) async throws -> SummaryCompletion {
        var request = URLRequest(url: endpoint.appending(path: "api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 900
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "prompt": prompt,
            "stream": false,
            // `think: false` suppresses recent models' reasoning preamble,
            // `format: json` constrains decoding on the server side.
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
        // Ollama doesn't provide a cost (local inference) but does return exact
        // token counts in the non-streamed response.
        let usage = TokenUsage(
            input: payload["prompt_eval_count"] as? Int,
            output: payload["eval_count"] as? Int
        )
        return SummaryCompletion(text: text, usage: usage)
    }
}
