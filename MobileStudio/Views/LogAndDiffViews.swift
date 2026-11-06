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

/// One changed file in a sheet: its diff against HEAD, or its text to change by hand. A hand edit is saved as a
/// change of its own, so it shows in History, can be undone and reloads the running app.
struct DiffSheet: View {
    let workspace: Workspace
    let folder: String
    let change: FileSnapshot.Change
    let onClose: () -> Void

    private enum Mode: String, CaseIterable, Identifiable {
        case diff = "Diff", edit = "Edit"
        var id: Self { self }
    }

    @State private var mode: Mode = {
        #if DEBUG
        // A snapshot run opens the sheet in Edit mode when asked to (see `Snapshot`).
        if ProcessInfo.processInfo.environment["MOBILE_STUDIO_SNAPSHOT_DIFF_EDIT"] == "1" { return .edit }
        #endif
        return .diff
    }()
    @State private var result: GitDiff.Result?
    /// The file as it was when the editor opened or was last saved, and what is typed now.
    @State private var original: String?
    @State private var draft = ""
    @State private var loadError: String?
    @State private var saveError: String?
    @State private var isSaving = false
    @State private var justSaved = false
    @State private var confirmsClose = false

    private var isModified: Bool { original != nil && draft != original }
    private var canSave: Bool { isModified && !isSaving && workspace.manualEditBlocker == nil }
    private var isEditable: Bool { change.kind != .deleted }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if mode == .edit, let line = status {
                line.padding(.horizontal, 14).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }
            content
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 460, idealHeight: 620)
        .task(id: change.path) { result = await GitDiff.diff(of: change.path, in: folder) }
        .task(id: mode) { if mode == .edit, original == nil, loadError == nil { await load() } }
        // Esc would drop the edits without asking, so only Done (which asks) closes the sheet while there are any.
        .interactiveDismissDisabled(isModified)
        .confirmationDialog("Save your changes to \(FriendlyName.of(change.path))?", isPresented: $confirmsClose) {
            Button("Save") { save(thenClose: true) }.disabled(!canSave)
            Button("Don't Save", role: .destructive, action: onClose)
            Button("Cancel", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            FileChangeRow(change: change).font(.headline)
            Spacer()
            if isEditable {
                Picker("View", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if mode == .edit {
                Button("Revert") { draft = original ?? draft; saveError = nil }
                    .disabled(!isModified)
                    .help("Throw away what you typed since the last save")
                Button("Save") { save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!canSave)
                    .help("Save (⌘S). The running app updates, and Undo is in History.")
            }
            Button("Open") { workspace.openInEditor(file: change.path, line: result?.firstChangedLine) }
                .disabled(!isEditable)
                .help(workspace.editorTitle + (result?.firstChangedLine.map { ", at line \($0)" } ?? ""))
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }
                .disabled(!isEditable)
            Button("Done") { isModified ? (confirmsClose = true) : onClose() }
                .keyboardShortcut(mode == .diff ? KeyboardShortcut.defaultAction : nil)
        }
        .padding(14)
    }

    private var fileURL: URL { URL(fileURLWithPath: folder).appendingPathComponent(change.path) }

    /// One line under the header while editing: what went wrong, why saving waits, or what saving did.
    private var status: Text? {
        if let saveError { return Text(Image(systemName: "exclamationmark.triangle")) + Text(" \(saveError)").foregroundStyle(.red) }
        if loadError != nil { return nil }
        if let blocker = workspace.manualEditBlocker, isModified { return Text(blocker).foregroundStyle(.secondary) }
        if isModified { return Text("Unsaved changes. ⌘S saves them.").foregroundStyle(.secondary) }
        if justSaved { return Text("Saved. It is in History, where Undo puts the file back.").foregroundStyle(.secondary) }
        return nil
    }

    @ViewBuilder
    private var content: some View {
        if mode == .edit {
            editor
        } else {
            diff
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let loadError {
            ContentUnavailableView("Can't Edit Here", systemImage: "pencil.slash", description: Text(loadError))
        } else if original == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            CodeTextView(text: $draft)
                .accessibilityLabel("Text of \(FriendlyName.of(change.path))")
        }
    }

    @ViewBuilder
    private var diff: some View {
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

    private func load() async {
        do {
            let text = try await ManualEdit.text(of: change.path, in: folder)
            original = text
            draft = text
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func save(thenClose close: Bool = false) {
        guard canSave, let baseline = original else { return }
        isSaving = true
        saveError = nil
        let text = draft
        Task {
            do {
                try await workspace.saveManualEdit(path: change.path, content: text, replacing: baseline)
                original = text
                justSaved = true
                result = await GitDiff.diff(of: change.path, in: folder)
                if close { onClose() }
            } catch {
                saveError = error.localizedDescription
            }
            isSaving = false
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
