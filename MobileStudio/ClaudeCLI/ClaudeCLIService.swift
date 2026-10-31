import Foundation

/// Shape of `claude auth status` (JSON). Everything except `loggedIn` is optional
/// because the CLI omits account fields when signed out.
struct ClaudeAuthStatus: Decodable, Equatable, Sendable {
    let loggedIn: Bool
    let authMethod: String?
    let apiProvider: String?
    let email: String?
    let orgName: String?
    let subscriptionType: String?

    static let signedOut = ClaudeAuthStatus(
        loggedIn: false, authMethod: nil, apiProvider: nil,
        email: nil, orgName: nil, subscriptionType: nil
    )
}

/// What we know about one profile's login.
enum AccountState: Equatable, Sendable {
    case checking
    case signedIn(ClaudeAuthStatus)
    case signedOut
    case failed(String)
}

enum ClaudeCLIError: Error, LocalizedError, Sendable {
    case notInstalled
    case commandFailed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .notInstalled: "The claude CLI was not found on this Mac."
        case .commandFailed(let detail): detail
        case .timedOut: "The claude CLI did not respond in time."
        }
    }
}

struct ClaudeCLIService: Sendable {
    var runner: ProcessRunner

    /// `environment` selects the account: CLAUDE_CONFIG_DIR points the CLI at a profile's login.
    init(environment: [String: String] = [:]) {
        runner = ProcessRunner(timeout: 15, extraEnvironment: environment)
    }

    // MARK: Public

    func accountState(at path: String) async -> AccountState {
        do {
            let status = try await authStatus(at: path)
            return status.loggedIn ? .signedIn(status) : .signedOut
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Best effort: drops the stored credential for this profile.
    func logout(at path: String) async {
        _ = try? await runner.run(path, ["auth", "logout"])
    }

    // MARK: Locating

    /// A GUI app launched from Finder gets a minimal PATH, so look in the usual install
    /// locations first and only then ask the user's login shell.
    func locate() async -> String? {
        let fm = FileManager.default
        for candidate in Self.candidatePaths() where fm.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return await locateViaLoginShell()
    }

    static func candidatePaths() -> [String] {
        let home = NSHomeDirectory()
        var paths = [
            "\(home)/.local/bin/claude",          // native installer
            "\(home)/.claude/local/claude",       // legacy local install
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/.bun/bin/claude",
            "\(home)/.volta/bin/claude",
        ]
        let nvm = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            paths += versions.sorted(by: >).map { "\(nvm)/\($0)/bin/claude" }
        }
        return paths
    }

    private func locateViaLoginShell() async -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard let out = try? await runner.run(shell, ["-ilc", "command -v claude"]) else { return nil }
        // rc files may print noise; the answer is the last absolute path line.
        let line = out.stdout
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") }
        guard let line, FileManager.default.isExecutableFile(atPath: line) else { return nil }
        return line
    }

    // MARK: Commands

    func version(at path: String) async throws -> String {
        let out = try await runner.run(path, ["--version"])
        guard out.status == 0 else {
            throw ClaudeCLIError.commandFailed(out.failureDetail(fallback: "claude --version failed"))
        }
        return out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func authStatus(at path: String) async throws -> ClaudeAuthStatus {
        let out = try await runner.run(path, ["auth", "status"])
        // `auth status` exits non-zero when signed out but still prints JSON, so decode first.
        if let data = out.stdout.data(using: .utf8),
           let status = try? JSONDecoder().decode(ClaudeAuthStatus.self, from: data) {
            return status
        }
        if out.status != 0 { return .signedOut }
        throw ClaudeCLIError.commandFailed("Could not read the output of `claude auth status`.")
    }
}
