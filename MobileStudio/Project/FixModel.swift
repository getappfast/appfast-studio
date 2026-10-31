import Foundation
import Observation

struct FixChange: Equatable, Sendable, Codable {
    let file: String
    let description: String
}

struct FixReport: Equatable, Sendable, Codable {
    let fixed: Bool
    let rootCause: String
    let summary: String
    let changes: [FixChange]
    let remainingIssues: [String]
}

struct FixOutcome: Equatable, Sendable {
    let report: FixReport
    /// Files that actually differ on disk, found by comparing before and after.
    let files: [FileSnapshot.Change]
    /// Whether the app ran after the fix. Nil when nothing changed, so there was nothing to re-run.
    let validated: Bool?
    let cost: Double?
}

enum FixPhase: Equatable {
    case idle
    case fixing
    case validating
    case done(FixOutcome)
    case failed(String)
}

/// Hands a failed run to Claude Code, lets it fix the project, then re-runs the app to check the fix.
@MainActor
@Observable
final class FixModel {
    private(set) var phase: FixPhase = .idle
    /// What Claude is doing, newest last.
    private(set) var activity: [String] = []

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var process: ClaudeStreamProcess?
    @ObservationIgnored private var run: FlutterRunModel?

    static let log = DiagnosticLog(name: "claude-fix")

    var isBusy: Bool { phase == .fixing || phase == .validating }

    func fix(_ failure: RunFailure, using claude: ClaudeAccess, run: FlutterRunModel) {
        guard !isBusy else { return }
        self.run = run
        activity = []
        phase = .fixing
        task = Task { await perform(failure, claude: claude, run: run) }
    }

    func cancel() {
        guard isBusy else { return }
        task?.cancel()
        process?.cancel()
        if phase == .validating { run?.stop() }
        phase = .idle
    }

    func revealLog() { Self.log.reveal() }

    func dismiss() {
        if !isBusy { phase = .idle; activity = [] }
    }

    // MARK: Work

    private func perform(_ failure: RunFailure, claude: ClaudeAccess, run: FlutterRunModel) async {
        let folder = failure.folder
        let before = await FileSnapshot.taken(of: folder)
        let process = await claude.agentProcess(Self.call(for: failure), folder: folder, timeout: 20 * 60)
        self.process = process
        Self.log.append("FIX START in \(folder)\nerror: \(failure.message)")

        let finished: ClaudeStreamProcess.Finished
        do {
            finished = try await process.run { [weak self] line in
                Task { @MainActor in self?.noteActivity(line, folder: folder) }
            }
        } catch {
            self.process = nil
            finish(.failed(error.localizedDescription), note: "could not start: \(error.localizedDescription)")
            return
        }
        self.process = nil
        guard !Task.isCancelled else { Self.log.append("FIX CANCELLED"); return }
        Self.log.append("CLAUDE EXIT \(finished.status)\n" + finished.lines.joined(separator: "\n") + "\n--- stderr ---\n" + finished.stderr)

        guard let result = ClaudeEvents.result(in: finished.lines) else {
            let reason = finished.timedOut ? "Claude took longer than 20 minutes and was stopped."
                : finished.stderr.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Claude did not return a result."
            finish(.failed(reason), note: reason)
            return
        }
        guard !result.isError, let report = result.structured(as: FixReport.self) else {
            let reason = result.errors.nonEmpty ?? result.text.nonEmpty ?? "Claude did not return a report (\(result.subtype ?? "unknown"))."
            finish(.failed(reason), note: reason)
            return
        }

        let after = await FileSnapshot.taken(of: folder)
        let files = after.changes(since: before)

        var validated: Bool?
        if !files.isEmpty {
            phase = .validating
            run.start(folder: folder, deviceID: failure.deviceID, deviceName: failure.deviceName)
            validated = await Self.outcome(of: run)
            guard !Task.isCancelled else { return }
        }
        finish(.done(FixOutcome(report: report, files: files, validated: validated, cost: result.cost)),
               note: "fixed=\(report.fixed) files=\(files.count) validated=\(validated.map(String.init) ?? "not attempted")")
    }

    private func finish(_ phase: FixPhase, note: String) {
        Self.log.append("FIX RESULT: \(note)")
        self.phase = phase
    }

    /// Waits for the re-run to either come up or fail.
    private static func outcome(of run: FlutterRunModel) async -> Bool {
        while run.phase == .starting {
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return run.phase == .running
    }

    // MARK: Claude call

    private static let schema = """
    {"type":"object","properties":{"fixed":{"type":"boolean"},"rootCause":{"type":"string"},"summary":{"type":"string"},\
    "changes":{"type":"array","items":{"type":"object","properties":{"file":{"type":"string"},"description":{"type":"string"}},\
    "required":["file","description"]}},"remainingIssues":{"type":"array","items":{"type":"string"}}},\
    "required":["fixed","rootCause","summary","changes","remainingIssues"]}
    """

    private static func call(for failure: RunFailure) -> ClaudeAgentCall {
        let output = failure.output.suffix(120).joined(separator: "\n").suffix(12_000)
        let prompt = """
        A Flutter app failed to run on an iOS Simulator. Find the root cause and fix it with the smallest change \
        that makes it run. The project is the current directory.

        Command that failed: flutter run -d \(failure.deviceID)   (\(failure.deviceName))
        Reported error: \(failure.message)

        Last output:
        \(output)

        Rules:
        - Change files only inside this folder. Do not commit, do not touch git, do not delete the user's code or assets, \
        do not edit generated folders (build/, ios/Pods, .dart_tool) and do not upgrade packages beyond what the fix needs.
        - Never run `flutter run`, it does not exit. To check a fix use `flutter build ios --simulator --debug`, plus \
        `flutter pub get` or `pod install --project-directory=ios` when needed.
        - If the cause is outside the project (Xcode, the simulator, the network, a missing tool), change nothing, set \
        fixed to false and explain it in remainingIssues.
        When done, report: fixed (true only if your own build check passed), rootCause, summary, changes (each file you \
        changed with one sentence on why) and remainingIssues.
        """
        return ClaudeAgentCall(
            prompt: prompt,
            jsonSchema: schema,
            maxBudgetUSD: 3,
            allowedCommands: ["flutter pub *", "flutter build *", "flutter clean", "flutter analyze *", "pod *"]
        )
    }

    // MARK: Progress

    private func noteActivity(_ line: String, folder: String) {
        for item in ClaudeEvents.items(in: line, folder: folder) {
            switch item {
            case .text(let text): activity.append(String(text.prefix(160)).replacingOccurrences(of: "\n", with: " "))
            case .activity(let text): activity.append(text)
            }
        }
        if activity.count > 40 { activity.removeFirst(activity.count - 40) }
    }
}
