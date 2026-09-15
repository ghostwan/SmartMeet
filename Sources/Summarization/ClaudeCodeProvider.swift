import Foundation

/// Goes through the `claude` binary (Claude Code CLI) in non-interactive
/// print mode.
///
/// Unlike `CopilotACPProvider`, no ACP handshake is needed here: `claude -p
/// "…" --output-format json` prints a single JSON object to stdout once the
/// turn completes (`result` for the text, `usage` for the token count),
/// which is simpler to parse than the ACP or NDJSON event streams the other
/// providers use — Claude Code's print mode is designed exactly for this
/// kind of one-shot, non-interactive completion.
public struct ClaudeCodeProvider: SummaryProvider {
    public let model: String
    public let executableURL: URL

    public var displayName: String { "Claude Code · \(model)" }

    public init(
        model: String = "sonnet",
        executableURL: URL? = nil
    ) {
        self.model = model
        self.executableURL = executableURL ?? Self.locateExecutable()
    }

    /// The app runs inside a bundle: the PATH inherited from LaunchServices is
    /// minimal and contains neither Homebrew nor `~/.local/bin` (same
    /// constraint as `OpencodeProvider.locateExecutable()`).
    static func locateExecutable() -> URL {
        let candidates = [
            "\(NSHomeDirectory())/.claude/local/claude",
            "\(NSHomeDirectory())/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(filePath: path)
        }
        return URL(filePath: "/usr/local/bin/claude")
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
        process.arguments = [
            "-p", prompt,
            "--output-format", "json",
            "--model", model,
            "--tools", "",
            "--permission-prompts", "none",
            "--no-session-persistence",
        ]
        // `claude` behaves differently depending on the current directory
        // (project `CLAUDE.md`, local settings, MCP servers): isolated in a
        // neutral directory with nothing in it, like `OpencodeProvider` and
        // `CopilotACPProvider`. Tools are also disabled explicitly above: a
        // minutes-generation prompt only needs text completion and must never
        // gain an accidental path to files, commands, hooks or MCP side
        // effects through the user's Claude Code configuration.
        process.currentDirectoryURL = URL(filePath: NSTemporaryDirectory())

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        environment["NO_COLOR"] = "1"
        process.environment = environment

        let raw = try await Self.run(process)
        return try Self.parseResult(raw)
    }

    /// `claude -p … --output-format json` prints a single JSON object once
    /// the turn completes — not one event per line like `opencode run
    /// --format json` or the ACP providers' NDJSON stream.
    static func parseResult(_ raw: String) throws -> SummaryCompletion {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            // Unparseable JSON (unexpected CLI version, truncated output…):
            // the raw text is still more useful to `SummaryGenerator` than a
            // hard failure — it can reject it during JSON decoding if needed.
            return SummaryCompletion(text: raw, usage: nil)
        }

        if object["is_error"] as? Bool == true {
            let detail = (object["result"] as? String) ?? "erreur claude inconnue"
            throw SummaryProviderError.processFailed(detail)
        }

        guard let text = object["result"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw SummaryProviderError.emptyResponse
        }

        let usage = (object["usage"] as? [String: Any]).map(Self.usage(from:))
        return SummaryCompletion(text: text, usage: usage)
    }

    /// Converts the token count from Claude Code's `usage` object (field
    /// names follow the Anthropic Messages API, distinct from opencode's or
    /// ACP's) into `TokenUsage`.
    static func usage(from dict: [String: Any]) -> TokenUsage {
        TokenUsage(
            input: dict["input_tokens"] as? Int,
            output: dict["output_tokens"] as? Int,
            reasoning: nil,
            cacheWrite: dict["cache_creation_input_tokens"] as? Int,
            cacheRead: dict["cache_read_input_tokens"] as? Int
        )
    }

    static func run(_ process: Process) async throws -> String {
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        try process.run()

        // Concurrent reading: a saturated pipe would block the child process.
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
