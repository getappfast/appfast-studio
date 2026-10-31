import Foundation

/// Runs `claude auth login` for one config directory. The CLI opens the browser itself and then
/// waits, so this streams its output (the sign-in link) and accepts a pasted code on stdin for
/// the case where the browser shows a code instead of redirecting back.
final class ClaudeLoginProcess: @unchecked Sendable {
    private let process = Process()
    private let stdin = Pipe()
    private let output = Pipe()
    private let onOutput: @Sendable (String) -> Void

    init(cliPath: String, configDir: String, email: String?, onOutput: @escaping @Sendable (String) -> Void) {
        self.onOutput = onOutput
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = ["auth", "login"] + (email.map { ["--email", $0] } ?? [])
        process.environment = ProcessRunner.environment(for: cliPath, extra: ["CLAUDE_CONFIG_DIR": configDir])
        process.standardInput = stdin
        process.standardOutput = output
        process.standardError = output
    }

    /// Returns the exit status once the CLI finishes (or is cancelled).
    func run() async throws -> Int32 {
        let onOutput = self.onOutput
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                onOutput(String(decoding: data, as: UTF8.self))
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                output.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    func send(_ text: String) {
        try? stdin.fileHandleForWriting.write(contentsOf: Data((text + "\n").utf8))
    }

    func cancel() {
        if process.isRunning { process.terminate() }
    }
}
