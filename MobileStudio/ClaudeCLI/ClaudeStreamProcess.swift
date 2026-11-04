import Foundation

/// A long-running `claude -p … --output-format stream-json` call. Lines are reported as they arrive so the
/// UI can show what Claude is doing, and all of them are returned at the end.
///
/// A call that asks for approval also has a stdin: the prompt goes in as the first message, and each
/// `can_use_tool` request is answered there once `onPermission` has decided.
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
    /// What to write first. Nil for a call that takes its prompt as an argument and has no stdin.
    private let firstMessage: String?
    private let input: InputChannel?

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = ""
        private(set) var lines: [String] = []
        private(set) var timedOut = false
        private var answers: [Task<Void, Never>] = []

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
        func track(_ task: Task<Void, Never>) { lock.withLock { answers.append(task) } }
        func cancelAnswers() {
            let tasks = lock.withLock { defer { answers = [] }; return answers }
            tasks.forEach { $0.cancel() }
        }
    }

    /// The write end of the CLI's stdin. Writing after the CLI is gone, or after the input was closed, does nothing.
    private final class InputChannel: @unchecked Sendable {
        private let lock = NSLock()
        private let pipe = Pipe()
        private var isClosed = false

        var readEnd: FileHandle { pipe.fileHandleForReading }

        init() {
            // A write to a pipe nobody reads must fail with an error, not take the app down with SIGPIPE.
            _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        }

        func write(_ line: String) {
            lock.withLock {
                guard !isClosed else { return }
                try? pipe.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
            }
        }

        /// The CLI reads messages until its stdin ends, so this is what lets it finish.
        func close() {
            lock.withLock {
                guard !isClosed else { return }
                isClosed = true
                try? pipe.fileHandleForWriting.close()
            }
        }
    }

    init(cliPath: String, arguments: [String], input firstMessage: String? = nil, folder: String, environment: [String: String], timeout: TimeInterval) {
        self.timeout = timeout
        self.firstMessage = firstMessage
        input = firstMessage == nil ? nil : InputChannel()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: folder)
        process.environment = ProcessRunner.environment(for: cliPath, extra: environment)
        process.standardInput = input?.readEnd ?? FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
    }

    /// `onPermission` answers the CLI's requests to use a tool outside its allow-list. Without it they are declined.
    func run(onLine: @escaping @Sendable (String) -> Void, onPermission: AgentPermissionHandler? = nil) async throws -> Finished {
        let state = self.state
        let deliver: @Sendable (String) -> Void = { [weak self] line in
            onLine(line)
            self?.respond(to: line, onPermission: onPermission)
        }
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                state.append(String(decoding: data, as: UTF8.self)).forEach(deliver)
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
                if let firstMessage { input?.write(firstMessage) }
            } catch {
                output.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
        // Whatever is still waiting for an answer has no process to answer to.
        state.cancelAnswers()
        input?.close()
        // The pipe may still hold output written just before exit.
        let rest = (try? output.fileHandleForReading.readToEnd()).map { String(decoding: $0, as: UTF8.self) } ?? ""
        output.fileHandleForReading.readabilityHandler = nil
        state.append(rest).forEach(onLine)
        state.flush().forEach(onLine)
        return Finished(status: status, lines: state.lines, stderr: await errorTask.value, timedOut: state.timedOut)
    }

    func cancel() {
        state.cancelAnswers()
        input?.close()
        if process.isRunning { process.terminate() }
    }

    /// Answers a permission request, and ends the input once the result is in so the CLI can exit.
    private func respond(to line: String, onPermission: AgentPermissionHandler?) {
        guard let input else { return }
        if let request = AgentPermissionRequest.parse(line) {
            let task = Task { [weak self] in
                let decision = await onPermission?(request) ?? .deny("Mobile Studio can't ask the user here.")
                self?.input?.write(request.response(decision))
            }
            state.track(task)
        } else if let reply = AgentPermissionRequest.unsupportedResponse(to: line) {
            input.write(reply)
        } else if line.contains("\"type\":\"result\""), ClaudeEvents.json(line)?["type"] as? String == "result" {
            input.close()
        }
    }
}
