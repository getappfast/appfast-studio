import Foundation

/// The steps of creating a project, in order. Each can be retried on its own.
enum CreateStep: Int, CaseIterable, Comparable, Sendable {
    case flutterCreate, appID, architecture, packages, git

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .flutterCreate: "Creating the Flutter project"
        case .appID: "Setting the app ID"
        case .architecture: "Adding the starter screens"
        case .packages: "Downloading packages"
        case .git: "Saving the first version"
        }
    }

    /// The steps a request needs: no app-ID rewrite when Flutter derives the ID, no git when it is off.
    static func steps(for request: NewProjectRequest) -> [CreateStep] {
        allCases.filter { step in
            switch step {
            case .appID: isRewrite(request)
            case .git: request.usesGit
            default: true
            }
        }
    }

    private static func isRewrite(_ request: NewProjectRequest) -> Bool {
        if case .rewrite = FlutterCreateCommand.appIDPlan(for: request) { return true }
        return false
    }
}

enum NewProjectError: LocalizedError, Equatable {
    case toolFailed(command: String, detail: String)
    case offline
    case flutterNotFound

    var errorDescription: String? {
        switch self {
        case .toolFailed(let command, let detail): "\(command) didn't finish. \(detail)"
        case .offline: "Couldn't download packages. Check your connection and try again."
        case .flutterNotFound: "Flutter wasn't found. Install it first, then try again."
        }
    }

    /// What `flutter pub` prints when the network is the problem.
    static func looksOffline(_ output: String) -> Bool {
        ["Failed host lookup", "SocketException", "Could not resolve host", "Connection refused", "Network is unreachable", "timed out"]
            .contains { output.localizedCaseInsensitiveContains($0) }
    }
}

/// Runs the I/O of each creation step. No UI state: the model decides what to show.
struct NewProjectService: Sendable {
    var log = DiagnosticLog(name: "new-project")
    var runner = ProcessRunner(timeout: 900)
    var gitRunner = ProcessRunner(timeout: 60)

    /// What the git step left behind besides a commit.
    struct GitResult: Equatable, Sendable {
        var committed: Bool
        var note: String?
    }

    func perform(_ step: CreateStep, for request: NewProjectRequest) async throws -> GitResult? {
        switch step {
        case .flutterCreate: try await flutterCreate(request)
        case .appID: try appID(request)
        case .architecture: try architecture(request)
        case .packages: try await packages(request)
        case .git: return try await git(request)
        }
        return nil
    }

    func flutterCreate(_ request: NewProjectRequest) async throws {
        try FileManager.default.createDirectory(atPath: request.parentFolder, withIntermediateDirectories: true)
        _ = try await flutter(FlutterCreateCommand.arguments(for: request), in: request.parentFolder)
    }

    func appID(_ request: NewProjectRequest) throws {
        guard case .rewrite(let id) = FlutterCreateCommand.appIDPlan(for: request) else { return }
        let changed = try AppIDWriter.apply(id, inProjectAt: request.path)
        log.append("App ID \(id) written to: \(changed.joined(separator: ", "))")
    }

    func architecture(_ request: NewProjectRequest) throws {
        let files = try StarterTemplate.write(values: StarterTemplate.values(for: request), to: request.path)
        log.append("Starter written: \(files.joined(separator: ", "))")
    }

    func packages(_ request: NewProjectRequest) async throws {
        do {
            _ = try await flutter(["pub", "add", "go_router", "flutter_riverpod"], in: request.path)
        } catch NewProjectError.toolFailed(_, let detail) where NewProjectError.looksOffline(detail) {
            throw NewProjectError.offline
        }
    }

    /// Local only: no remote is added and nothing is pushed.
    func git(_ request: NewProjectRequest) async throws -> GitResult {
        let folder = request.path
        _ = try await runGit(["init", "-b", "main"], in: folder)
        try ensureIgnored(".DS_Store", in: folder)
        _ = try await runGit(["add", "-A"], in: folder)

        let name = try await runGit(["config", "user.name"], in: folder, allowFailure: true)
        let email = try await runGit(["config", "user.email"], in: folder, allowFailure: true)
        guard name.status == 0, email.status == 0,
              !name.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !email.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return GitResult(committed: false, note: "Set your name in git to save the first version: git config --global user.name \"Your Name\" and git config --global user.email you@example.com")
        }
        let title = request.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        // Unsigned and without hooks: a signing prompt or a slow hook would hang a step the user can't see into.
        _ = try await runGit(["-c", "commit.gpgsign=false", "commit", "--no-verify", "-m", "Create \(title) with AppFast Studio"], in: folder)
        return GitResult(committed: true, note: nil)
    }

    // MARK: Running tools

    /// Through the login shell, like `FlutterRunProcess`, so Flutter finds CocoaPods, Ruby and Xcode tools.
    /// The folder and arguments travel as shell arguments, never spliced into the command text.
    private func flutter(_ arguments: [String], in folder: String) async throws -> ProcessOutput {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let command = "flutter " + arguments.joined(separator: " ")
        let output = try await runner.run(shell, ["-ilc", "cd \"$1\" && shift && exec flutter \"$@\"", "flutter", folder] + arguments)
        record(command, in: folder, output)
        guard output.status == 0 else {
            if output.status == 127 || output.stderr.contains("flutter: command not found") { throw NewProjectError.flutterNotFound }
            throw NewProjectError.toolFailed(command: "flutter \(arguments.first ?? "")", detail: Self.tail(output))
        }
        return output
    }

    @discardableResult
    private func runGit(_ arguments: [String], in folder: String, allowFailure: Bool = false) async throws -> ProcessOutput {
        let output = try await gitRunner.run("/usr/bin/git", arguments, currentDirectory: URL(fileURLWithPath: folder))
        record("git " + arguments.joined(separator: " "), in: folder, output)
        guard output.status == 0 || allowFailure else {
            throw NewProjectError.toolFailed(command: "git \(arguments.first ?? "")", detail: Self.tail(output))
        }
        return output
    }

    private func ensureIgnored(_ pattern: String, in folder: String) throws {
        let url = URL(fileURLWithPath: folder).appendingPathComponent(".gitignore")
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        guard !existing.split(separator: "\n").contains(where: { $0 == pattern }) else { return }
        let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        try (existing + separator + pattern + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func record(_ command: String, in folder: String, _ output: ProcessOutput) {
        let text = (output.stdout + output.stderr).suffix(20_000)
        log.append("$ \(command)   (in \(folder))\nexit \(output.status)\n\(text)")
    }

    /// The last lines of a failed tool's output: where the reason usually is.
    static func tail(_ output: ProcessOutput) -> String {
        let text = (output.stderr.isEmpty ? output.stdout : output.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.split(whereSeparator: \.isNewline).suffix(6).joined(separator: "\n")
    }
}
