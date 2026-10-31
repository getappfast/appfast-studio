import Foundation

/// A long-running `claude -p … --output-format stream-json` call. Lines are reported as they arrive so the
/// UI can show what Claude is doing, and all of them are returned at the end.
final class ClaudeStreamProcess: @unchecked Sendable {
    struct Finished: Sendable {
        let status: Int32
        let lines: [String]
        let stderr: String
        let timedOut: Bool
    }

    private let process = Process()
    private let output = Pipe()
    private let errors = Pipe()
    private let timeout: TimeInterval
    private let state = State()

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = ""
        private(set) var lines: [String] = []
        private(set) var timedOut = false

        func append(_ chunk: String) -> [String] {
            lock.withLock {
                pending += chunk
                var complete = pending.components(separatedBy: "\n")
                pending = complete.removeLast()
                lines += complete.filter { !$0.isEmpty }
                return complete.filter { !$0.isEmpty }
            }
        }
        func flush() -> [String] {
            lock.withLock {
                guard !pending.isEmpty else { return [] }
                lines.append(pending)
                defer { pending = "" }
                return [pending]
            }
        }
        func markTimedOut() { lock.withLock { timedOut = true } }
    }

    init(cliPath: String, arguments: [String], folder: String, environment: [String: String], timeout: TimeInterval) {
        self.timeout = timeout
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: folder)
        process.environment = ProcessRunner.environment(for: cliPath, extra: environment)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
    }

    func run(onLine: @escaping @Sendable (String) -> Void) async throws -> Finished {
        let state = self.state
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                state.append(String(decoding: data, as: UTF8.self)).forEach(onLine)
            }
        }
        let errorTask = Task.detached { [errors] in
            String(decoding: (try? errors.fileHandleForReading.readToEnd()) ?? Data(), as: UTF8.self)
        }
        let process = self.process
        let timeout = self.timeout
        let watchdog = Task {
            try await Task.sleep(for: .seconds(timeout))
            state.markTimedOut()
            process.terminate()
        }
        defer { watchdog.cancel() }

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                output.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
        // The pipe may still hold output written just before exit.
        let rest = (try? output.fileHandleForReading.readToEnd()).map { String(decoding: $0, as: UTF8.self) } ?? ""
        output.fileHandleForReading.readabilityHandler = nil
        state.append(rest).forEach(onLine)
        state.flush().forEach(onLine)
        return Finished(status: status, lines: state.lines, stderr: await errorTask.value, timedOut: state.timedOut)
    }

    func cancel() {
        if process.isRunning { process.terminate() }
    }
}
