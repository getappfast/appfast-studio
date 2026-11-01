import Foundation

struct ProcessOutput: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String

    func failureDetail(fallback: String) -> String {
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? fallback : text
    }
}

/// Runs a child process off the main thread with a timeout. Used for every claude CLI call.
struct ProcessRunner: Sendable {
    var timeout: TimeInterval
    /// Added on top of the app's environment, e.g. CLAUDE_CONFIG_DIR to select an account.
    var extraEnvironment: [String: String] = [:]

    func run(_ executable: String, _ arguments: [String], currentDirectory: URL? = nil) async throws -> ProcessOutput {
        let timeout = self.timeout
        let extra = self.extraEnvironment
        let handle = ProcessHandle()
        // Cancelling the calling task stops the child too; the result then carries its non-zero status.
        return try await withTaskCancellationHandler {
            try await Task.detached {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.environment = Self.environment(for: executable, extra: extra)
                process.currentDirectoryURL = currentDirectory
                process.standardInput = FileHandle.nullDevice

                let outPipe = Pipe(), errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                try process.run()
                handle.set(process)

                // Drain both pipes concurrently so a chatty process can't fill a buffer and hang.
                async let stdout = Self.drain(outPipe)
                async let stderr = Self.drain(errPipe)

                let timedOut = TimedOutFlag()
                let watchdog = Task {
                    try await Task.sleep(for: .seconds(timeout))
                    timedOut.set()
                    process.terminate()
                }
                process.waitUntilExit()
                watchdog.cancel()

                let result = ProcessOutput(status: process.terminationStatus, stdout: await stdout, stderr: await stderr)
                if timedOut.value { throw ClaudeCLIError.timedOut }
                return result
            }.value
        } onCancel: {
            handle.terminate()
        }
    }

    private static func drain(_ pipe: Pipe) async -> String {
        await Task.detached {
            let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }.value
    }

    /// Prepend the CLI's own directory so a node-based install can find `node` next to it,
    /// and keep the usual locations that a Finder-launched app doesn't inherit.
    static func environment(for executable: String, extra overrides: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let dir = (executable as NSString).deletingLastPathComponent
        let dirs = [dir, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let existing = env["PATH"]?.split(separator: ":").map(String.init) ?? []
        var seen = Set<String>()
        env["PATH"] = (dirs + existing).filter { seen.insert($0).inserted }.joined(separator: ":")
        env.merge(overrides) { _, new in new }
        return env
    }
}

private final class TimedOutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}

/// Lets a cancelled task reach the child process, which is created inside a detached task.
private final class ProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func set(_ process: Process) {
        lock.withLock {
            self.process = process
            if cancelled { process.terminate() }
        }
    }

    func terminate() {
        lock.withLock {
            cancelled = true
            if process?.isRunning == true { process?.terminate() }
        }
    }
}
