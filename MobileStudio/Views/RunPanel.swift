import SwiftUI

/// Build output while running, the recorded failure, and Claude's fix for it. Run itself is the floating RunBar.
struct RunPanel: View {
    let project: ProjectModel
    let studio: StudioModel
    let run: FlutterRunModel
    let fix: FixModel

    /// False when there is nothing to show, so the card doesn't reserve space for it.
    var hasContent: Bool {
        (run.phase.isActive && !run.tail.isEmpty) || visibleFailure != nil || fix.phase != .idle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if run.phase.isActive, !run.tail.isEmpty { outputBox(run.tail) }
            if let failure = visibleFailure { failureSection(failure) }
            fixSection
        }
    }

    // MARK: Failure

    /// The recorded failure, shown for this folder while nothing is running or being fixed.
    private var visibleFailure: RunFailure? {
        guard let failure = run.failure, failure.folder == project.path, !run.phase.isActive, !fix.isBusy else { return nil }
        return failure
    }

    @ViewBuilder
    private func failureSection(_ failure: RunFailure) -> some View {
        StatusLine(color: .red, title: "Run failed", detail: nil)
        Text(failure.message).textSelection(.enabled)
        outputBox(Array(failure.output.suffix(10)))
        HStack(spacing: 8) {
            if let claude = studio.claude {
                Button { fix.fix(failure, using: claude, run: run) } label: {
                    Label("Fix with Claude", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
                .help("Claude (\(studio.profiles.active.name)) will find the cause, change the project, and the app runs again to check it.")
            } else {
                Text("Install the claude CLI and sign in to fix this with Claude.").foregroundStyle(.secondary)
            }
            Button("Show log") { run.revealLog() }.controlSize(.small)
        }
        Text("Recorded \(failure.date, format: .relative(presentation: .named))")
            .font(.caption).foregroundStyle(.secondary)
    }

    // MARK: Fix

    @ViewBuilder
    private var fixSection: some View {
        switch fix.phase {
        case .idle:
            EmptyView()
        case .fixing:
            Divider()
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Claude (\(studio.profiles.active.name)) is finding and fixing the error…").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { fix.cancel() }.controlSize(.small)
            }
            if !fix.activity.isEmpty { outputBox(Array(fix.activity.suffix(6))) }
            Text("This can take a few minutes while Claude builds the app to check its fix.")
                .font(.caption).foregroundStyle(.secondary)
        case .validating:
            Divider()
            Text("Claude is done. Running the app again to check the fix.").foregroundStyle(.secondary)
        case .failed(let message):
            Divider()
            StatusLine(color: .orange, title: "Claude couldn't fix it", detail: nil)
            Text(message).textSelection(.enabled)
            Button("Dismiss") { fix.dismiss() }.controlSize(.small)
        case .done(let outcome):
            Divider()
            outcomeView(outcome)
        }
    }

    @ViewBuilder
    private func outcomeView(_ outcome: FixOutcome) -> some View {
        let report = outcome.report
        switch outcome.validated {
        case true?:
            StatusLine(color: .green, title: "Fixed and verified", detail: "The app runs.")
        case false?:
            StatusLine(color: .red, title: "Changed, but it still fails", detail: "The app did not run after the fix.")
        case nil:
            StatusLine(color: .orange, title: report.fixed ? "No files changed" : "Nothing to fix in the project", detail: nil)
        }
        VStack(alignment: .leading, spacing: 4) {
            Text("Cause").foregroundStyle(.secondary)
            Text(report.rootCause).textSelection(.enabled)
        }
        VStack(alignment: .leading, spacing: 4) {
            Text("What was done").foregroundStyle(.secondary)
            Text(report.summary).textSelection(.enabled)
        }
        if !outcome.files.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Files changed (\(outcome.files.count))").foregroundStyle(.secondary)
                ForEach(outcome.files.prefix(30)) { change in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(change.kind.badge).font(.system(.body, design: .monospaced)).foregroundStyle(change.kind.tint)
                            Text(change.path).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        }
                        if let why = reason(for: change.path, in: report) {
                            Text(why).font(.callout).foregroundStyle(.secondary).padding(.leading, 18)
                        }
                    }
                }
                if outcome.files.count > 30 { Text("and \(outcome.files.count - 30) more").foregroundStyle(.secondary) }
            }
        }
        if !report.remainingIssues.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Still open").foregroundStyle(.secondary)
                ForEach(report.remainingIssues, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
        }
        HStack(spacing: 10) {
            if let cost = outcome.cost { Text(String(format: "Claude cost $%.3f", cost)).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button("Show log") { fix.revealLog() }.controlSize(.small)
            Button("Dismiss") { fix.dismiss() }.controlSize(.small)
        }
    }

    /// Claude's one-line reason for a file, matched to the files that really changed.
    private func reason(for path: String, in report: FixReport) -> String? {
        report.changes.first { $0.file == path || $0.file.hasSuffix("/" + path) || path.hasSuffix("/" + $0.file) }?.description
    }

    private func outputBox(_ lines: [String]) -> some View {
        Text(lines.joined(separator: "\n"))
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .lineLimit(10)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }
}
