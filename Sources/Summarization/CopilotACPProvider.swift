import Foundation

/// Goes through the `copilot --acp` binary, which exposes Copilot as an ACP
/// server (Agent Client Protocol: JSON-RPC 2.0, one message per line, over stdio).
///
/// Unlike `OpencodeProvider`, we don't spawn a process per prompt and don't
/// parse a best-effort output: ACP requires a handshake (`initialize` then
/// `session/new`) and responds in a structured way at each turn
/// (`session/prompt`), with an exact token count in the response — no need for
/// NDJSON parsing heuristics. In exchange, each `complete(prompt:)` call spawns
/// its own process: the startup cost (~1 s) is negligible compared to that of
/// an LLM generation, and it avoids keeping shared state across the chunks of
/// a split meeting.
public struct CopilotACPProvider: SummaryProvider {
    public let model: String
    public let executableURL: URL

    public var displayName: String { "copilot · \(model)" }

    public init(
        model: String = "claude-sonnet-5",
        executableURL: URL? = nil
    ) {
        self.model = model
        self.executableURL = executableURL ?? Self.locateExecutable()
    }

    /// The app runs inside a bundle: the PATH inherited from LaunchServices is
    /// minimal and contains neither Homebrew nor `~/.local/bin` (same constraint
    /// as `OpencodeProvider.locateExecutable()`).
    static func locateExecutable() -> URL {
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/copilot",
            "/opt/homebrew/bin/copilot",
            "/usr/local/bin/copilot",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(filePath: path)
        }
        return URL(filePath: "/usr/local/bin/copilot")
    }

    public func isAvailable() async -> Bool {
        FileManager.default.isExecutableFile(atPath: executableURL.path)
    }

    public func complete(prompt: String) async throws -> SummaryCompletion {
        guard await isAvailable() else {
            throw SummaryProviderError.executableNotFound(executableURL.path)
        }
        let session = ACPSession(executableURL: executableURL, model: model)
        return try await session.run(prompt: prompt)
    }
}

/// A minimal, single-use ACP client: one ACP session for a single conversation
/// turn, then the process is terminated. Isolated in an `actor` since it holds
/// mutable state (pending requests, accumulated text) touched from both the
/// pipe-reading task and the provider's calls.
actor ACPSession {
    private let process = Process()
    private let stdinHandle: FileHandle
    private let stdoutPipe: Pipe

    private var nextRequestID = 1
    private var pendingRequests: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var readTask: Task<Void, Never>?

    private var messageText = ""
    private var usage: TokenUsage?
    private let model: String

    init(executableURL: URL, model: String) {
        process.executableURL = executableURL
        process.arguments = ["--acp"]
        // `copilot --acp` behaves differently depending on the current
        // directory (skills/agents `.github` loaded as trusted configuration):
        // isolated in a neutral directory, like `OpencodeProvider`.
        process.currentDirectoryURL = URL(filePath: NSTemporaryDirectory())

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        environment["NO_COLOR"] = "1"
        process.environment = environment

        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        // stderr isn't captured: `copilot`'s diagnostic messages have no
        // contractual format and aren't needed for the client to work — only
        // the ACP stream on stdout matters.
        process.standardError = FileHandle.nullDevice

        self.stdinHandle = stdin.fileHandleForWriting
        self.stdoutPipe = stdout
        self.model = model
    }

    func run(prompt: String) async throws -> SummaryCompletion {
        do {
            try process.run()
        } catch {
            throw SummaryProviderError.processFailed(error.localizedDescription)
        }
        defer {
            if process.isRunning { process.terminate() }
        }

        startReading()

        _ = try await send(method: "initialize", params: [
            "protocolVersion": 1,
            "clientCapabilities": [String: Any](),
            "clientInfo": ["name": "SmartMeet", "version": "1.0"],
        ])

        let sessionResult = try await send(method: "session/new", params: [
            "cwd": NSTemporaryDirectory(),
            "mcpServers": [Any](),
        ])
        guard let sessionId = sessionResult["sessionId"] as? String else {
            throw SummaryProviderError.processFailed("session/new n'a pas renvoyé de sessionId.")
        }

        // A session's default model isn't configurable at creation time: it's
        // set afterward via `session/set_config_option`, the only method the
        // protocol exposes for that.
        _ = try? await send(method: "session/set_config_option", params: [
            "sessionId": sessionId,
            "configId": "model",
            "value": model,
        ])

        let promptResult = try await send(method: "session/prompt", params: [
            "sessionId": sessionId,
            "prompt": [["type": "text", "text": prompt]],
        ])

        if let stopReason = promptResult["stopReason"] as? String, stopReason != "end_turn" {
            // `refusal`, `max_tokens`…: the turn stopped without a complete
            // response. Whatever partial text was already accumulated (if any)
            // is more useful to `SummaryGenerator` than a hard error — it can
            // reject it during JSON decoding if needed.
            if messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw SummaryProviderError.processFailed("Tour arrêté : \(stopReason)")
            }
        }

        if let usageDict = promptResult["usage"] as? [String: Any] {
            usage = Self.usage(from: usageDict)
        }

        guard !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SummaryProviderError.emptyResponse
        }
        return SummaryCompletion(text: messageText, usage: usage)
    }

    // MARK: - JSON-RPC transport

    private func startReading() {
        let handle = stdoutPipe.fileHandleForReading
        readTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await line in handle.bytes.lines {
                    await self.handle(line: line)
                }
            } catch {
                // Pipe closed or read error: the process has terminated, any
                // requests still pending are settled by `failPendingRequests`.
            }
            await self.failPendingRequests(
                SummaryProviderError.processFailed("Le process copilot s'est arrêté avant de répondre.")
            )
        }
    }

    /// Unblocks any request still pending when the stdout stream closes
    /// (crash, unexpected process termination) — without this,
    /// `withCheckedThrowingContinuation` would stay suspended indefinitely.
    private func failPendingRequests(_ error: Error) {
        let requests = pendingRequests
        pendingRequests.removeAll()
        for (_, continuation) in requests {
            continuation.resume(throwing: error)
        }
    }

    private func send(method: String, params: [String: Any]) async throws -> [String: Any] {
        let id = nextRequestID
        nextRequestID += 1

        let envelope: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        ]
        try write(envelope)

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = continuation
        }
    }

    private func write(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        var line = data
        line.append(0x0A)
        try stdinHandle.write(contentsOf: line)
    }

    /// Handles an NDJSON line received from `copilot --acp`: either the
    /// response to a pending request, a notification (`session/update`), or an
    /// incoming request from the server to the client (permissions, files…).
    private func handle(line: String) {
        guard let data = line.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        if let id = message["id"] as? Int, message["method"] == nil {
            // Response to a request we sent.
            guard let continuation = pendingRequests.removeValue(forKey: id) else { return }
            if let error = message["error"] as? [String: Any] {
                let detail = (error["message"] as? String) ?? "erreur ACP inconnue"
                continuation.resume(throwing: SummaryProviderError.processFailed(detail))
            } else {
                continuation.resume(returning: (message["result"] as? [String: Any]) ?? [:])
            }
            return
        }

        guard let method = message["method"] as? String else { return }
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "session/update":
            handleSessionUpdate(params)
        case "session/request_permission":
            // No tool execution is expected for a simple minutes generation:
            // requests are systematically rejected rather than opening a door
            // to side effects (files, commands) that no review window covers
            // at this layer — cf. the `ReviewWindow` principle in AGENTS.md,
            // which only applies to publication, not this layer.
            if let id = message["id"] {
                respondToPermissionRequest(id: id, params: params)
            }
        default:
            // Unsupported optional requests (fs/*, terminal/*…): the
            // capabilities declared to `initialize` are all `false`/absent, so
            // a protocol-compliant agent shouldn't emit them. If one arrives
            // anyway and expects a response, a standard JSON-RPC error is
            // returned rather than leaving the turn stuck indefinitely.
            if let id = message["id"] {
                try? write([
                    "jsonrpc": "2.0",
                    "id": id,
                    "error": ["code": -32601, "message": "Method not supported: \(method)"],
                ])
            }
        }
    }

    private func handleSessionUpdate(_ params: [String: Any]) {
        guard let update = params["update"] as? [String: Any] else { return }
        if let chunk = Self.textChunk(from: update) { messageText += chunk }
    }

    private func respondToPermissionRequest(id: Any, params: [String: Any]) {
        let options = params["options"] as? [[String: Any]] ?? []
        let response: [String: Any]
        if let optionId = Self.rejectOptionId(among: options) {
            response = ["outcome": ["outcome": "selected", "optionId": optionId]]
        } else {
            response = ["outcome": ["outcome": "cancelled"]]
        }
        try? write(["jsonrpc": "2.0", "id": id, "result": response])
    }

    // MARK: - Pure parsing helpers (testable without spawning a process)

    /// Extracts the text fragment from a `session/update` of type
    /// `agent_message_chunk`. Other types (`plan`, `tool_call`, `usage_update`…)
    /// carry no response text and are ignored: this provider only returns the
    /// final message, not the execution trace.
    static func textChunk(from update: [String: Any]) -> String? {
        guard update["sessionUpdate"] as? String == "agent_message_chunk",
              let content = update["content"] as? [String: Any],
              content["type"] as? String == "text",
              let text = content["text"] as? String
        else { return nil }
        return text
    }

    /// Converts the token count returned by `session/prompt` (ACP schema,
    /// field names differ from opencode's) into `TokenUsage`.
    static func usage(from dict: [String: Any]) -> TokenUsage {
        TokenUsage(
            input: dict["inputTokens"] as? Int,
            output: dict["outputTokens"] as? Int,
            reasoning: dict["thoughtTokens"] as? Int,
            cacheWrite: dict["cachedWriteTokens"] as? Int,
            cacheRead: dict["cachedReadTokens"] as? Int
        )
    }

    /// Picks the rejection option among those offered by
    /// `session/request_permission` (`reject_once` or `reject_always`): no tool
    /// execution is expected for a simple minutes generation, so requests are
    /// systematically rejected rather than opening a door to side effects
    /// (files, commands) that no review window covers at this layer — cf. the
    /// `ReviewWindow` principle in AGENTS.md, which only applies to
    /// publication, not this layer.
    static func rejectOptionId(among options: [[String: Any]]) -> String? {
        options.first { ($0["kind"] as? String)?.hasPrefix("reject") == true }?["optionId"] as? String
    }
}
