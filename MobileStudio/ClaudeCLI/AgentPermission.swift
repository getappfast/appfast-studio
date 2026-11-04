import Foundation

/// Answers a request the agent's CLI is holding. Chat and Fix both pass one into their call.
typealias AgentPermissionHandler = @Sendable (AgentPermissionRequest) async -> AgentPermissionRequest.Decision

/// A tool call outside the allow-list that the claude CLI is holding until the app answers: one `can_use_tool`
/// request of the CLI's control channel (`--permission-prompt-tool stdio`, answered on stdin).
struct AgentPermissionRequest: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case command(String)
        case readFile(String)
        case editFile(String)
        case other(tool: String)
    }

    enum Decision: Equatable, Sendable {
        case allow
        /// Claude reads the message, so it says what to do instead.
        case deny(String)
    }

    /// The CLI's id for the request; the answer repeats it.
    let id: String
    let action: Action
    /// Claude's own one-line reason for a command.
    let reason: String?
    /// The tool input as sent. An allowed call has to echo it back.
    let input: Data

    /// Nil for any other line of the stream.
    static func parse(_ line: String) -> AgentPermissionRequest? {
        guard let object = ClaudeEvents.json(line), object["type"] as? String == "control_request",
              let id = object["request_id"] as? String,
              let request = object["request"] as? [String: Any], request["subtype"] as? String == "can_use_tool",
              let tool = request["tool_name"] as? String else { return nil }
        let input = request["input"] as? [String: Any] ?? [:]
        guard JSONSerialization.isValidJSONObject(input), let data = try? JSONSerialization.data(withJSONObject: input) else { return nil }
        func text(_ key: String) -> String? { (input[key] as? String)?.nonEmpty }
        let action: Action
        switch tool {
        case "Bash": action = text("command").map(Action.command) ?? .other(tool: tool)
        case "Read": action = text("file_path").map(Action.readFile) ?? .other(tool: tool)
        case "Glob", "Grep": action = (text("path") ?? text("pattern")).map(Action.readFile) ?? .other(tool: tool)
        case "Edit", "Write", "MultiEdit", "NotebookEdit": action = text("file_path").map(Action.editFile) ?? .other(tool: tool)
        default: action = .other(tool: tool)
        }
        return AgentPermissionRequest(id: id, action: action, reason: (request["description"] as? String)?.nonEmpty ?? text("description"), input: data)
    }

    /// The line to write to the CLI's stdin.
    func response(_ decision: Decision) -> String {
        let body: [String: Any]
        switch decision {
        case .allow:
            body = ["behavior": "allow", "updatedInput": (try? JSONSerialization.jsonObject(with: input)) ?? [:]]
        case .deny(let message):
            body = ["behavior": "deny", "message": message]
        }
        return Self.controlResponse(["subtype": "success", "request_id": id, "response": body])
    }

    /// For a control request this app doesn't handle: without an answer the CLI would wait for it forever.
    static func unsupportedResponse(to line: String) -> String? {
        guard let object = ClaudeEvents.json(line), object["type"] as? String == "control_request",
              let id = object["request_id"] as? String, parse(line) == nil else { return nil }
        return controlResponse(["subtype": "error", "request_id": id, "error": "Mobile Studio doesn't handle this request."])
    }

    private static func controlResponse(_ response: [String: Any]) -> String {
        let data = try? JSONSerialization.data(withJSONObject: ["type": "control_response", "response": response], options: [.sortedKeys])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// What the log and the chat's step list say about the answer.
    func note(for decision: Decision) -> String {
        switch decision {
        case .allow: "Allowed: \(action.summary)"
        case .deny: "Declined: \(action.summary)"
        }
    }
}

extension AgentPermissionRequest.Action {
    /// One short line: the command, or what is being touched.
    var summary: String {
        switch self {
        case .command(let command): String(command.replacingOccurrences(of: "\n", with: " ").prefix(120))
        case .readFile(let path): "read \(Self.shortened(path))"
        case .editFile(let path): "change \(Self.shortened(path))"
        case .other(let tool): "use \(tool)"
        }
    }

    static func shortened(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

/// What the app decides about a request before it bothers the user. The hard rules of `AGENTS.md` live here:
/// a command that breaks one is refused whatever the user could click.
enum AgentPermissionPolicy {
    enum Verdict: Equatable, Sendable {
        /// The user already said "Always allow" to this exact command.
        case allow
        /// Never, and why. Claude is told, so it doesn't just stop.
        case refuse(String)
        case ask
    }

    static func verdict(for request: AgentPermissionRequest, approvedCommands: Set<String>) -> Verdict {
        switch request.action {
        case .command(let command):
            if let reason = refusal(forCommand: command) { return .refuse(reason) }
            return approvedCommands.contains(normalized(command)) ? .allow : .ask
        case .readFile(let path):
            if isSecret(path) { return .refuse("Mobile Studio doesn't let Claude read passwords, keys or other credentials.") }
            return .ask
        case .editFile:
            // Edits inside the project are accepted before they get here, so this is outside it, or a protected folder.
            return .refuse("Mobile Studio only lets Claude change files inside the project.")
        case .other(let tool):
            return .refuse("Mobile Studio doesn't let Claude use \(tool).")
        }
    }

    /// Design mode only changes `design/`, and the CLI accepts those edits itself, so an edit that gets here is
    /// anywhere else. Nil when the usual rules decide.
    static func designRefusal(for request: AgentPermissionRequest) -> String? {
        switch request.action {
        case .editFile: "In design mode Claude only changes files in design/. To change the app itself, ask in the main chat."
        case .command: "Design mode has no shell."
        case .readFile, .other: nil
        }
    }

    static func normalized(_ command: String) -> String { command.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Why a command is never run, nil when it may be asked about. Looks at every part of a compound command.
    static func refusal(forCommand command: String) -> String? {
        for words in segments(of: command) {
            guard let program = words.first.map({ ($0 as NSString).lastPathComponent }) else { continue }
            let rest = Array(words.dropFirst())
            switch program {
            case "rm": return "Mobile Studio never lets Claude delete files with rm."
            case "sudo", "su", "doas": return "Mobile Studio never lets Claude run commands as an administrator."
            case "sh", "bash", "zsh", "dash", "eval": return "Mobile Studio doesn't let Claude start another shell. Run the command itself."
            case "flutter" where rest.first(where: { !$0.hasPrefix("-") }) == "run":
                return "The app runs `flutter run` itself and reloads on its own. Don't run it."
            case "git":
                if let subcommand = gitSubcommand(rest), gitWrites.contains(subcommand) {
                    return "Mobile Studio never lets Claude change git. Leave committing to the user."
                }
            default: break
            }
        }
        return nil
    }

    /// Whether "Always allow" may be offered: one plain command, so what is remembered is exactly what was shown.
    static func canRemember(_ command: String) -> Bool {
        let command = normalized(command)
        return !command.isEmpty && command.count <= 300 && refusal(forCommand: command) == nil
            && command.rangeOfCharacter(from: unsafeToRemember) == nil
    }

    private static let unsafeToRemember = CharacterSet(charactersIn: ";&|<>`$(){}*\\\n\r")

    private static let gitWrites: Set<String> = [
        "add", "commit", "push", "pull", "merge", "rebase", "reset", "checkout", "switch", "restore", "clean", "stash",
        "tag", "cherry-pick", "revert", "apply", "am", "rm", "mv", "init", "config",
    ]

    /// The words of each simple command in a compound one, without leading `VAR=x` and `env`-style prefixes.
    private static func segments(of command: String) -> [[String]] {
        var separated = command
        for separator in ["&&", "||", "$(", ";", "|", "&", "`", "(", ")", "{", "}"] {
            separated = separated.replacingOccurrences(of: separator, with: "\n")
        }
        return separated.split(whereSeparator: \.isNewline).map { segment in
            var words = segment.split(whereSeparator: \.isWhitespace).map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
            while let first = words.first, isAssignment(first) || ["env", "command", "exec", "time", "nohup", "nice"].contains(first) {
                words.removeFirst()
            }
            return words
        }
    }

    private static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        return word[..<equals].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// `git -C dir status` is `status`; options before the subcommand are skipped, with the value of the ones that take one.
    private static func gitSubcommand(_ words: [String]) -> String? {
        var index = 0
        while index < words.count {
            let word = words[index]
            if word == "-C" || word == "-c" { index += 2 } else if word.hasPrefix("-") { index += 1 } else { return word }
        }
        return nil
    }

    private static func isSecret(_ path: String) -> Bool {
        let path = path.lowercased()
        return ["/.ssh/", "/.aws/", "/.gnupg/", "/library/keychains/", "/.netrc", "/.config/gh/", "/.kube/"].contains { path.contains($0) }
            || path.hasSuffix("/.ssh") || path.hasSuffix("/.aws") || path.hasSuffix("/.gnupg")
    }
}

/// The commands the user chose "Always allow" for, per project folder. Exact commands only, so what is remembered
/// is what the user saw.
struct ApprovedCommandStore {
    static let key = "agent.approvedCommands.v1"

    var defaults: UserDefaults = .standard

    func commands(in folder: String) -> [String] { all[folder] ?? [] }

    func add(_ command: String, in folder: String) {
        var all = all
        let command = AgentPermissionPolicy.normalized(command)
        guard !(all[folder] ?? []).contains(command) else { return }
        all[folder, default: []].append(command)
        defaults.setEncoded(all, forKey: Self.key)
    }

    func remove(_ command: String, in folder: String) {
        var all = all
        all[folder]?.removeAll { $0 == command }
        if all[folder]?.isEmpty == true { all[folder] = nil }
        defaults.setEncoded(all, forKey: Self.key)
    }

    private var all: [String: [String]] { defaults.decoded([String: [String]].self, forKey: Self.key) ?? [:] }
}
