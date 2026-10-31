import Foundation

/// A `flutter run --flavor <name>` target.
struct RunFlavor: Equatable, Sendable, Codable, Identifiable {
    let name: String
    /// Platforms that define it: "android", "ios".
    let platforms: [String]
    /// Separate entry point passed with `-t`, empty when the flavor uses lib/main.dart.
    let entryPoint: String

    var id: String { name }

    var runCommand: String {
        "flutter run --flavor \(name)" + (entryPoint.isEmpty ? "" : " -t \(entryPoint)")
    }
}

struct ProjectVerdict: Equatable, Sendable, Codable {
    let isFlutterProject: Bool
    let summary: String
    let problems: [String]
    let flavors: [RunFlavor]
}

enum VerificationState: Equatable, Sendable {
    case idle
    case running
    case done(ProjectVerdict)
    case failed(String)
}

/// Asks Claude Code, run read-only inside the project folder, whether it is a valid Flutter codebase.
struct ProjectVerifier: Sendable {
    let access: ClaudeAccess

    private static let schema = """
    {"type":"object","properties":{"isFlutterProject":{"type":"boolean"},"summary":{"type":"string"},\
    "problems":{"type":"array","items":{"type":"string"}},\
    "flavors":{"type":"array","items":{"type":"object","properties":{"name":{"type":"string"},\
    "platforms":{"type":"array","items":{"type":"string"}},"entryPoint":{"type":"string"}},\
    "required":["name","platforms","entryPoint"]}}},"required":["isFlutterProject","summary","problems","flavors"]}
    """

    private static let prompt = """
    You are checking whether the current directory is the root of a valid Flutter application codebase. \
    Only read files; never modify anything. Look at pubspec.yaml (a Flutter app depends on the Flutter SDK), \
    lib/ with an entry point such as lib/main.dart, and the platform folders (android, ios, macos, web, linux, \
    windows). Be quick: a few reads are enough. Answer with isFlutterProject (true only for a Flutter app or \
    package that builds with Flutter), a one sentence summary a developer would read, and problems: concrete \
    issues that would stop it from running (empty if none; do not list optional things such as platform folders it simply does not target). \
    Also find the run flavors a developer can pass to `flutter run --flavor`. Check android/app/build.gradle or \
    build.gradle.kts (productFlavors), the Xcode schemes in ios/Runner.xcodeproj/xcshareddata/xcschemes and \
    build configurations named like Debug-<flavor>, a flutter_flavorizr section in pubspec.yaml, and \
    .vscode/launch.json. Return one entry per flavor name, merged across platforms, with the platforms that \
    define it (android, ios) and entryPoint, the separate file passed with -t if one is used (empty string \
    otherwise). A scheme that is not tied to a flavor, such as the default Runner, is not a flavor. Only list \
    flavors you saw evidence for; return an empty list when the project has none.
    """

    private struct Envelope: Decodable {
        let is_error: Bool?
        let subtype: String?
        let terminal_reason: String?
        let result: String?
        let structured_output: ProjectVerdict?
        let errors: Lenient<[String]>?
    }

    /// Decodes to nil instead of failing the whole envelope when the shape is unexpected.
    private struct Lenient<Value: Decodable & Sendable>: Decodable, Sendable {
        let value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }

    static let log = DiagnosticLog(name: "project-check")

    func verify(folder: String) async throws -> ProjectVerdict {
        do {
            let verdict = try await run(folder: folder)
            // Claude proposes flavors; only the ones the files back up are shown.
            let flavors = FlavorValidator.validate(verdict.flavors, in: folder)
            if !flavors.rejected.isEmpty {
                Self.log.append("Flavors dropped as not runnable in \(folder):\n" + flavors.rejected.joined(separator: "\n"))
            }
            return ProjectVerdict(isFlutterProject: verdict.isFlutterProject, summary: verdict.summary,
                                  problems: verdict.problems, flavors: flavors.runnable)
        } catch {
            Self.log.append("FAILED for \(folder): \(error.localizedDescription)")
            throw error
        }
    }

    private func run(folder: String) async throws -> ProjectVerdict {
        let runner = ProcessRunner(timeout: 120, extraEnvironment: access.environment)
        let arguments = [
            "-p", Self.prompt,
            "--model", "haiku",
            // Read-only: the check must never be able to change the user's code.
            "--tools", "Read,Glob,Grep",
            "--allowedTools", "Read,Glob,Grep",
            // Safe mode switches off the machine's plugins, skills, MCP servers, hooks and the project's
            // CLAUDE.md. Left on, they are all loaded into the prompt and one check can cost over $0.50.
            "--safe-mode",
            "--no-session-persistence",
            "--output-format", "json",
            "--json-schema", Self.schema,
            "--max-budget-usd", "0.5",
        ]
        Self.log.append("RUN in \(folder)\n\(access.cliPath) \(arguments.map { "'\($0)'" }.joined(separator: " "))\nenv overrides: \(access.environment)")
        let out = try await runner.run(access.cliPath, arguments, currentDirectory: URL(fileURLWithPath: folder))
        Self.log.append("EXIT \(out.status)\n--- stdout ---\n\(out.stdout)\n--- stderr ---\n\(out.stderr)")

        guard let data = out.stdout.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw ClaudeCLIError.commandFailed(out.failureDetail(fallback: "Claude returned an unreadable answer."))
        }
        if let verdict = envelope.structured_output, envelope.is_error != true { return verdict }
        if envelope.is_error != true, let text = envelope.result?.data(using: .utf8),
           let verdict = try? JSONDecoder().decode(ProjectVerdict.self, from: text) { return verdict }
        // stderr is often unrelated noise (MCP warnings), so describe the failure from the envelope first.
        let reason = [envelope.subtype, envelope.terminal_reason].compactMap { $0 }.joined(separator: ", ")
        let detail = envelope.errors?.value?.joined(separator: " ")
            ?? envelope.result.flatMap { $0.isEmpty ? nil : $0 }
            ?? "Claude did not give a verdict" + (reason.isEmpty ? "." : " (\(reason)).")
        throw ClaudeCLIError.commandFailed(detail)
    }
}
