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
        // Where `ms-sim` lives, so the allow-listed command resolves.
        let bin = AgentBridge.binDirectory.path
        environment["PATH"] = bin + ":" + (environment["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
        return ClaudeStreamProcess(cliPath: cliPath, arguments: call.arguments, input: call.inputMessage, folder: folder,
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
    /// What Claude may use besides shell commands. Planning calls pass read-only tools.
    var tools = ClaudeAgentCall.tools
    var model = "sonnet"
    var session: Session = .none
    var systemPrompt: String?
    var jsonSchema: String?
    var maxBudgetUSD: Double
    /// Bash patterns Claude may run without asking, e.g. "flutter pub *".
    var allowedCommands: [String]
    /// Folders outside the project Claude may also read, e.g. the simulator screenshots.
    var readableFolders: [String] = []
    /// Hold a request for something outside the allow-list until the app answers, instead of refusing it. The CLI
    /// then takes the prompt as a message on stdin, because that is where it reads the answers.
    var asksForApproval = false
    /// Limits edits to the files this pattern matches, e.g. "design/**". The CLI then accepts only those edits by
    /// itself and holds any other as a permission request, which the app refuses. Nil accepts every edit in the project.
    var editablePattern: String?

    /// The prompt as the first line to write to stdin, for a call that asks for approval.
    var inputMessage: String? {
        guard asksForApproval else { return nil }
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": prompt]]
        return (try? JSONSerialization.data(withJSONObject: message)).map { String(decoding: $0, as: UTF8.self) }
    }

    var arguments: [String] {
        var arguments = asksForApproval ? ["-p"] : ["-p", prompt]
        switch session {
        case .none: arguments += ["--no-session-persistence"]
        case .start(let id): arguments += ["--session-id", id]
        case .resume(let id): arguments += ["--resume", id]
        }
        arguments += [
            "--model", model,
            // Machine-wide plugins, skills, MCP servers and hooks stay off: they only add cost and risk here.
            "--safe-mode",
            "--permission-mode", editablePattern == nil ? "acceptEdits" : "default",
        ]
        if let systemPrompt { arguments += ["--append-system-prompt", systemPrompt] }
        arguments += ["--output-format", "stream-json", "--verbose"]
        if let jsonSchema { arguments += ["--json-schema", jsonSchema] }
        arguments += [
            // %g keeps "5" and "0.5" free of trailing zeros and of the user's decimal comma.
            "--max-budget-usd", String(format: "%g", maxBudgetUSD),
            // Bash is only offered when some command is allowed, so a read-only call has no shell at all.
            "--tools", (tools + (allowedCommands.isEmpty ? [] : ["Bash"])).joined(separator: ","),
        ]
        if !readableFolders.isEmpty { arguments += ["--add-dir"] + readableFolders }
        if asksForApproval { arguments += ["--input-format", "stream-json", "--permission-prompt-tool", "stdio"] }
        // Variadic, so it has to come last.
        arguments += ["--allowedTools"] + allowedTools + allowedCommands.map { "Bash(\($0))" }
        return arguments
    }

    /// The tools allowed without asking. With `editablePattern`, one Edit rule covers every editing tool, but only for
    /// the files it matches.
    private var allowedTools: [String] {
        guard let editablePattern else { return tools }
        let editing: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]
        let others = tools.filter { !editing.contains($0) }
        return tools.contains(where: editing.contains) ? others + ["Edit(\(editablePattern))"] : others
    }
}
