import SwiftUI

/// Flutter's output under the simulator, like Xcode's debug area. Shows the run in progress, or the
/// output of the failed one.
struct LogDrawer: View {
    let workspace: Workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var lines: [String] {
        let run = workspace.run
        if run.phase.isActive { return run.output.tail(run.output.maxLines) }
        if let failure = workspace.visibleFailure { return failure.output }
        return run.output.lines
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Build Log").font(.headline)
                Spacer()
                Button("Show in Finder") { workspace.run.revealLog() }.controlSize(.small)
                Button { workspace.isLogVisible = false } label: { Label("Hide", systemImage: "xmark").labelStyle(.iconOnly) }
                    .buttonStyle(.borderless)
                    .help("Hide Build Log (⇧⌘Y)")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if lines.isEmpty {
                            Text("Nothing yet. Output appears here when you run the app.").foregroundStyle(.secondary)
                        }
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line).foregroundStyle(color(for: line))
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: lines.count) {
                    if reduceMotion { proxy.scrollTo("end") } else { withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo("end") } }
                }
                .onAppear { proxy.scrollTo("end") }
            }
        }
        .frame(height: 220)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func color(for line: String) -> Color {
        let lower = line.lowercased()
        if lower.contains("error") || lower.hasPrefix("failed") { return .red }
        if lower.contains("warning") { return .orange }
        return .primary
    }
}

/// One changed file's diff against HEAD, in a sheet.
struct DiffSheet: View {
    let folder: String
    let change: FileSnapshot.Change
    let onClose: () -> Void

    @State private var result: GitDiff.Result?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                FileChangeRow(change: change).font(.headline)
                Spacer()
                Button("Open") { NSWorkspace.shared.open(fileURL) }.disabled(change.kind == .deleted)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }
                    .disabled(change.kind == .deleted)
                Button("Done", action: onClose).keyboardShortcut(.defaultAction)
            }
            .padding(14)
            Divider()
            content
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 460, idealHeight: 620)
        .task(id: change.path) { result = await GitDiff.diff(of: change.path, in: folder) }
    }

    private var fileURL: URL { URL(fileURLWithPath: folder).appendingPathComponent(change.path) }

    @ViewBuilder
    private var content: some View {
        switch result {
        case nil:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unchanged?:
            ContentUnavailableView("No Differences", systemImage: "equal.circle",
                                   description: Text("This file matches the last commit."))
        case .unavailable(let reason)?:
            ContentUnavailableView("No Diff", systemImage: "doc.text.magnifyingglass", description: Text(reason))
        case .diff(let lines)?:
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .foregroundStyle(line.kind == .hunk ? .secondary : .primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, line.kind == .hunk ? 4 : 0)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(background(line.kind))
                    }
                }
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(.vertical, 8)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private func background(_ kind: GitDiff.Line.Kind) -> Color {
        switch kind {
        case .added: .green.opacity(0.15)
        case .removed: .red.opacity(0.15)
        case .hunk: .secondary.opacity(0.08)
        case .header, .context: .clear
        }
    }
}
