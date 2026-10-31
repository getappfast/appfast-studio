import Foundation

/// What it takes to run the claude CLI as one account: the binary, and the environment that selects
/// the account (CLAUDE_CONFIG_DIR for a non-default profile). Nil in `StudioModel` until both are ready.
struct ClaudeAccess: Sendable, Equatable {
    let cliPath: String
    let environment: [String: String]

    /// A streaming agent call in a project folder. It gets the terminal's PATH, because a Finder-launched
    /// app has a minimal one and Claude's shell would not find flutter, dart or pod.
    func agentProcess(_ call: ClaudeAgentCall, folder: String, timeout: TimeInterval) async -> ClaudeStreamProcess {
        var environment = environment
        if let path = await ShellEnvironment.terminalPATH() { environment["PATH"] = path }
        return ClaudeStreamProcess(cliPath: cliPath, arguments: call.arguments, folder: folder,
                                   environment: environment, timeout: timeout)
    }
}

/// One `claude -p` call that may edit the project, streamed as JSON. Chat and Fix differ only in the
/// fields here; the safety flags every editing call needs are added by `arguments`.
struct ClaudeAgentCall: Equatable, Sendable {
    enum Session: Equatable, Sendable {
        /// Nothing is saved, so the call can't be continued.
        case none
        case start(id: String)
        case resume(id: String)
    }

    /// Read-only tools, plus editing. Shell access is granted command by command in `allowedCommands`.
    static let tools = ["Read", "Glob", "Grep", "Edit", "Write"]

    var prompt: String
    var model = "sonnet"
    var session: Session = .none
    var systemPrompt: String?
    var jsonSchema: String?
    var maxBudgetUSD: Double
    /// Bash patterns Claude may run without asking, e.g. "flutter pub *".
    var allowedCommands: [String]

    var arguments: [String] {
        var arguments = ["-p", prompt]
        switch session {
        case .none: arguments += ["--no-session-persistence"]
        case .start(let id): arguments += ["--session-id", id]
        case .resume(let id): arguments += ["--resume", id]
        }
        arguments += [
            "--model", model,
            // Machine-wide plugins, skills, MCP servers and hooks stay off: they only add cost and risk here.
            "--safe-mode",
            "--permission-mode", "acceptEdits",
        ]
        if let systemPrompt { arguments += ["--append-system-prompt", systemPrompt] }
        arguments += ["--output-format", "stream-json", "--verbose"]
        if let jsonSchema { arguments += ["--json-schema", jsonSchema] }
        arguments += [
            // %g keeps "5" and "0.5" free of trailing zeros and of the user's decimal comma.
            "--max-budget-usd", String(format: "%g", maxBudgetUSD),
            "--tools", (Self.tools + ["Bash"]).joined(separator: ","),
        ]
        // Variadic, so it has to come last.
        arguments += ["--allowedTools"] + Self.tools + allowedCommands.map { "Bash(\($0))" }
        return arguments
    }
}
