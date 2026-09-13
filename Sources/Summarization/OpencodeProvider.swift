import Foundation

/// Passe par le binaire `opencode`, qui est un client Copilot authentifié.
///
/// Il n'existe pas d'API publique permettant de consommer un abonnement GitHub
/// Copilot depuis une application tierce : l'endpoint `copilot_internal` est privé et
/// renvoie 403, et GitHub Models est en cours de retrait. Déléguer à `opencode` est la
/// seule voie qui exploite l'abonnement sans reverse-engineering.
public struct OpencodeProvider: SummaryProvider {
    public let model: String
    public let executableURL: URL

    public var displayName: String { "opencode · \(model)" }

    public init(
        model: String = "github-copilot/claude-sonnet-5",
        executableURL: URL? = nil
    ) {
        self.model = model
        self.executableURL = executableURL ?? Self.locateExecutable()
    }

    /// L'app tourne dans un bundle : le PATH hérité de LaunchServices est minimal et
    /// ne contient ni Homebrew ni `~/.local/bin`.
    static func locateExecutable() -> URL {
        let candidates = [
            "\(NSHomeDirectory())/.opencode/bin/opencode",
            "\(NSHomeDirectory())/.local/bin/opencode",
            "/opt/homebrew/bin/opencode",
            "/usr/local/bin/opencode",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(filePath: path)
        }
        return URL(filePath: "/usr/local/bin/opencode")
    }

    public func isAvailable() async -> Bool {
        FileManager.default.isExecutableFile(atPath: executableURL.path)
    }

    public func complete(prompt: String) async throws -> SummaryCompletion {
        guard await isAvailable() else {
            throw SummaryProviderError.executableNotFound(executableURL.path)
        }

        let process = Process()
        process.executableURL = executableURL
        // `--format json` donne accès aux tokens/coût consommés (événement
        // `step_finish`), invisibles en sortie texte par défaut.
        process.arguments = ["run", "--format", "json", "--model", model, prompt]
        // `opencode run` se comporte différemment selon le dossier courant (agents et
        // réglages du projet) : on l'isole dans un répertoire neutre.
        process.currentDirectoryURL = URL(filePath: NSTemporaryDirectory())

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        environment["NO_COLOR"] = "1"
        process.environment = environment

        let raw = try await Self.run(process)
        return Self.parseEvents(raw)
    }

    /// `opencode run --format json` émet une suite d'événements NDJSON (un objet JSON
    /// par ligne). On assemble le texte des parts `type: "text"` et on cumule les
    /// tokens/coût des parts `type: "step-finish"`.
    static func parseEvents(_ raw: String) -> SummaryCompletion {
        var text = ""
        var usage: TokenUsage?

        for line in raw.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let part = event["part"] as? [String: Any],
                  let partType = part["type"] as? String
            else { continue }

            switch partType {
            case "text":
                if let chunk = part["text"] as? String { text += chunk }
            case "step-finish":
                if let tokens = part["tokens"] as? [String: Any] {
                    let cache = tokens["cache"] as? [String: Any]
                    let entry = TokenUsage(
                        input: tokens["input"] as? Int,
                        output: tokens["output"] as? Int,
                        reasoning: tokens["reasoning"] as? Int,
                        cacheWrite: cache?["write"] as? Int,
                        cacheRead: cache?["read"] as? Int,
                        costUSD: part["cost"] as? Double
                    )
                    usage = (usage ?? TokenUsage()) + entry
                }
            default:
                break
            }
        }

        // Le format JSON n'a pas pu être interprété (version d'opencode différente,
        // sortie inattendue…) : on retombe sur le texte brut plutôt que d'échouer.
        guard !text.isEmpty else {
            return SummaryCompletion(text: raw, usage: usage)
        }
        return SummaryCompletion(text: text, usage: usage)
    }

    static func run(_ process: Process) async throws -> String {
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        try process.run()

        // Lecture concurrente : un pipe saturé bloquerait le processus fils.
        async let stdout = readToEnd(output)
        async let stderr = readToEnd(errors)
        let (outputData, errorData) = await (stdout, stderr)
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let detail = String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw SummaryProviderError.processFailed(
                detail.isEmpty ? "code \(process.terminationStatus)" : detail
            )
        }

        let text = String(decoding: outputData, as: UTF8.self)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SummaryProviderError.emptyResponse
        }
        return text
    }

    private static func readToEnd(_ pipe: Pipe) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                continuation.resume(returning: data)
            }
        }
    }
}
