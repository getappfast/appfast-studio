import Foundation

/// A model the user can ask the CLI for, by alias ("opus") or full ID ("claude-opus-5-5").
struct ModelProbeTarget: Identifiable, Hashable, Sendable {
    let name: String
    var id: String { name }

    static let aliases = ["fable", "opus", "sonnet", "haiku"].map(ModelProbeTarget.init(name:))
}

struct ModelProbeResult: Equatable, Sendable {
    let resolvedID: String
    let contextWindow: Int?
    let maxOutputTokens: Int?
    let latency: TimeInterval
}

enum ModelProbeState: Equatable, Sendable {
    case idle
    case checking
    case available(ModelProbeResult)
    /// The CLI accepted the request but a different model answered, which is how it
    /// behaves for models the account can't use.
    case substituted(requested: String, ModelProbeResult)
    case unavailable(String)
}

/// The claude CLI has no "list models" command, so availability is probed: send one tiny
/// prompt with `--model <name>`. A model the account can use answers and reports the ID it
/// resolved to; one it can't use comes back as an API error (404).
struct ClaudeModelService: Sendable {
    let cliPath: String
    var runner: ProcessRunner

    init(cliPath: String, environment: [String: String] = [:]) {
        self.cliPath = cliPath
        runner = ProcessRunner(timeout: 60, extraEnvironment: environment)
    }

    func probe(_ target: ModelProbeTarget) async -> ModelProbeState {
        let started = Date()
        do {
            let out = try await runner.run(
                cliPath,
                ["-p", "Reply with the single word OK",
                 "--model", target.name,
                 "--output-format", "json",
                 "--tools", "",
                 "--no-session-persistence",
                 "--safe-mode"],
                // Run somewhere empty so no project CLAUDE.md or settings are picked up.
                currentDirectory: FileManager.default.temporaryDirectory
            )
            guard let response = Self.decode(out.stdout) else {
                return .unavailable(out.failureDetail(fallback: "Unexpected output from the claude CLI."))
            }
            if response.isError {
                return .unavailable(response.result ?? "The model returned an error.")
            }
            guard let (id, usage) = response.modelUsage?.first else {
                return .unavailable("The CLI did not report which model answered.")
            }
            let result = ModelProbeResult(
                resolvedID: id,
                contextWindow: usage.contextWindow,
                maxOutputTokens: usage.maxOutputTokens,
                latency: Date().timeIntervalSince(started)
            )
            return Self.answered(id, matches: target.name)
                ? .available(result)
                : .substituted(requested: target.name, result)
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    /// True when the model that answered is the one asked for: either the same ID, or an
    /// alias ("opus") that appears in the ID ("claude-opus-5-5"). Suffixes like "[1m]" are ignored.
    static func answered(_ resolvedID: String, matches requested: String) -> Bool {
        let wanted = requested.lowercased().split(separator: "[").first.map(String.init) ?? ""
        return !wanted.isEmpty && resolvedID.lowercased().contains(wanted)
    }

    // MARK: Decoding

    private struct Response: Decodable {
        struct Usage: Decodable {
            let contextWindow: Int?
            let maxOutputTokens: Int?
        }
        let isError: Bool
        let result: String?
        let modelUsage: [String: Usage]?

        enum CodingKeys: String, CodingKey {
            case isError = "is_error", result, modelUsage
        }
    }

    /// The CLI can print a diagnostic line before the JSON result, so decode the last JSON line.
    private static func decode(_ text: String) -> Response? {
        let line = text.split(whereSeparator: \.isNewline).last { $0.hasPrefix("{") }
        guard let data = line.map(String.init)?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Response.self, from: data)
    }
}
