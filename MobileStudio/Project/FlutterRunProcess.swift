import Foundation

/// `flutter run -d <device> [--flavor <name>]` in a project folder. It goes through the user's login shell so Flutter's own
/// tools (CocoaPods, Ruby, Xcode command line tools) resolve the way they do in a terminal.
final class FlutterRunProcess: @unchecked Sendable {
    private let process = Process()
    private let stdin = Pipe()
    private let output = Pipe()

    /// Starts the app (`flutter run`), or with `attachURL` connects to one that is already running (`flutter attach`).
    init(folder: String, deviceID: String, flavor: RunFlavor? = nil, attachURL: URL? = nil) {
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        var flutter = attachURL.map { ["attach", "-d", deviceID, "--debug-url", $0.absoluteString] } ?? ["run", "-d", deviceID]
        if let flavor {
            flutter += ["--flavor", flavor.name]
            if !flavor.entryPoint.isEmpty { flutter += ["-t", flavor.entryPoint] }
        }
        // The folder and Flutter's arguments travel as shell arguments ($1, then "$@"), never spliced into the
        // command text.
        process.arguments = ["-ilc", "cd \"$1\" && shift && exec flutter \"$@\"", "flutter", folder] + flutter
        process.standardInput = stdin
        process.standardOutput = output
        process.standardError = output
    }

    /// Streams output chunks, then returns the exit status.
    func run(onOutput: @escaping @Sendable (String) -> Void) async throws -> Int32 {
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

    /// Flutter's interactive keys: "r" hot reload, "R" hot restart, "q" quit.
    func send(_ key: String) {
        try? stdin.fileHandleForWriting.write(contentsOf: Data(key.utf8))
    }

    var isRunning: Bool { process.isRunning }

    /// For a tool that is not answering to "q", such as an attach that never connected.
    func kill() { if process.isRunning { process.terminate() } }

    /// Asks Flutter to quit cleanly (it detaches from the app), then makes sure it is gone.
    func stop() {
        guard process.isRunning else { return }
        send("q")
        let process = self.process
        DispatchQueue.global().asyncAfter(deadline: .now() + 4) {
            if process.isRunning { process.terminate() }
        }
    }
}
