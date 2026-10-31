import SwiftUI

/// The sidebar: setup until everything is in place, then the project, its screens, and the history of what
/// Claude changed, each step undoable. Project health lives in a popover off the header.
struct ProjectSidebar: View {
    let workspace: Workspace

    private var project: ProjectModel { workspace.project }

    var body: some View {
        List {
            if !SetupChecklist.isComplete(workspace) {
                Section("Get Started") { SetupChecklist(workspace: workspace) }
            }
            switch project.state {
            case .none:
                EmptyView()
            case .invalid(let path, let reason):
                Section("Project") { invalidProject(path: path, reason: reason) }
            case .ready(let flutter):
                Section("Project") { ProjectHeader(workspace: workspace, flutter: flutter) }
                ScreensSection(workspace: workspace)
                HistorySection(workspace: workspace)
            }
        }
        .listStyle(.sidebar)
    }

    private func invalidProject(path: String, reason: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            StatusBadge(tone: .warning, title: "Can't use this folder")
            Text(reason).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(path).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            HStack {
                Button("Choose Another…", action: workspace.chooseProject)
                Button("Remove", role: .destructive) { project.clear() }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Project

private struct ProjectHeader: View {
    let workspace: Workspace
    let flutter: FlutterProject

    @State private var showingHealth = false

    private var project: ProjectModel { workspace.project }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(flutter.name).font(.headline).lineLimit(1)
                Spacer(minLength: 4)
                actions
            }
            Button { showingHealth.toggle() } label: { health }
                .buttonStyle(.plain)
                .help("Project health")
                .popover(isPresented: $showingHealth, arrowEdge: .trailing) {
                    ProjectHealthView(workspace: workspace, flutter: flutter)
                }
        }
        .padding(.vertical, 4)
    }

    /// One line: healthy, being checked, or how many things need attention.
    @ViewBuilder
    private var health: some View {
        let issues = workspace.issues
        HStack(spacing: 4) {
            switch (issues.first?.tone, project.verification) {
            case (let tone?, _):
                StatusBadge(tone: tone, title: issues.count == 1 ? "1 issue" : "\(issues.count) issues")
            case (nil, .running):
                StatusBadge(tone: .neutral, title: "Checking…")
            case (nil, .done(let verdict)) where verdict.isFlutterProject:
                StatusBadge(tone: .success, title: "Ready")
            default:
                StatusBadge(tone: .neutral, title: "Not checked yet")
            }
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }
        .font(.callout)
        .contentShape(Rectangle())
    }

    private var actions: some View {
        Menu {
            Button("Change Folder…", action: workspace.chooseProject)
            Button("Show in Finder") { project.revealInFinder() }
            Button("Check Folder Again") { project.recheck() }
            Divider()
            Button("Remove Project", role: .destructive) { project.clear() }
        } label: {
            Label("Project Actions", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Project actions")
    }
}

/// Everything about the project's health and setup: issues, flavors, Claude's check, version and branch.
private struct ProjectHealthView: View {
    let workspace: Workspace
    let flutter: FlutterProject

    private var project: ProjectModel { workspace.project }

    var body: some View {
        Form {
            Section {
                if workspace.issues.isEmpty {
                    StatusBadge(tone: .success, title: "No issues")
                }
                ForEach(workspace.issues, id: \.self) { issue in
                    VStack(alignment: .leading, spacing: 2) {
                        StatusBadge(tone: issue.tone, title: issue.title)
                        if let detail = issue.detail {
                            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(4).textSelection(.enabled)
                        }
                    }
                }
            }
            if !project.flavors.isEmpty {
                Section("Run Flavor") {
                    Picker("Flavor", selection: Binding(get: { project.runFlavor?.name ?? "" },
                                                        set: { name in project.flavors.first { $0.name == name }.map(project.selectFlavor) })) {
                        ForEach(project.flavors) { Text($0.name).tag($0.name) }
                    }
                    .labelsHidden()
                    if let flavor = project.runFlavor {
                        Text(flavor.runCommand).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Claude's Check") {
                if case .done(let verdict) = project.verification {
                    Text(verdict.summary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                } else {
                    Text("Claude reads the project, without changing it, to confirm it's a Flutter app and find its flavors.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button(project.verification == .idle ? "Check with Claude" : "Check Again", action: workspace.checkProject)
                        .disabled(workspace.studio.projectVerifier == nil || project.verification == .running || project.refreshing)
                    if project.refreshing || project.verification == .running {
                        ProgressView().controlSize(.small)
                    } else if let checked = project.lastChecked {
                        Text(checked, format: .relative(presentation: .named)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Log") { project.revealLog() }.buttonStyle(.link)
                }
            }
            Section("Details") {
                if let version = flutter.version { LabeledContent("Version", value: version) }
                if let branch = project.branch { LabeledContent("Git branch", value: branch) }
                LabeledContent("Platforms", value: flutter.platforms.isEmpty ? "None" : flutter.platforms.joined(separator: ", "))
                LabeledContent("Folder") { MonospacedValue(flutter.path) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .frame(minHeight: 300, idealHeight: 460)
    }
}

// MARK: - Screens

private struct ScreensSection: View {
    let workspace: Workspace

    var body: some View {
        if !workspace.screens.isEmpty {
            Section("Screens") {
                ForEach(workspace.screens) { screen in
                    Button { workspace.mention(screen) } label: {
                        Label(screen.name, systemImage: "rectangle.portrait")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Ask Claude to change the \(screen.name) screen (\(screen.file))")
                    .contextMenu { ScreenMenu(workspace: workspace, screen: screen) }
                }
            }
        }
    }
}

// MARK: - History

/// Each answer that changed files, newest first. The newest can be undone; an older one undoes everything after it.
private struct HistorySection: View {
    let workspace: Workspace

    private var entries: [ChatMessage] {
        workspace.chat.messages.filter { $0.role == .assistant && !$0.files.isEmpty }.reversed()
    }

    var body: some View {
        if !entries.isEmpty {
            Section("History") {
                ForEach(entries) { entry in
                    HistoryRow(workspace: workspace, entry: entry, isLatest: entry.id == workspace.chat.undoable.first?.id)
                }
            }
        }
    }
}

private struct HistoryRow: View {
    let workspace: Workspace
    let entry: ChatMessage
    let isLatest: Bool

    @State private var expanded = false

    private var title: String {
        let request = workspace.chat.request(for: entry)?.text ?? "Change"
        return request.count > 60 ? request.prefix(60) + "…" : request
    }

    private var canUndo: Bool { entry.checkpointID != nil && entry.undone != true && !workspace.chat.isSending && !workspace.fix.isBusy }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(entry.files) { change in
                Button { workspace.showDiff(of: change) } label: {
                    FileChangeRow(change: change).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show what changed in \(change.path)")
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).lineLimit(2).strikethrough(entry.undone == true)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if isLatest, canUndo {
                    Button("Undo") { workspace.undo(entry) }
                        .controlSize(.small)
                        .help("Put back the files as they were before this change")
                }
            }
            .foregroundStyle(entry.undone == true ? .secondary : .primary)
        }
        .contextMenu {
            if canUndo {
                Button(isLatest ? "Undo This Change" : "Undo Back to Before This") { workspace.undo(entry) }
            }
        }
    }

    private var subtitle: String {
        let files = entry.files.count == 1 ? "1 file" : "\(entry.files.count) files"
        let when = entry.date.formatted(.relative(presentation: .named))
        if entry.undone == true { return "Undone · \(files)" }
        if entry.checkpointID == nil { return "\(files) · \(when) · can't be undone" }
        return "\(files) · \(when)"
    }
}

// MARK: - Setup

/// What has to be in place before Mobile Studio can do its job, each with the way to fix it.
struct SetupChecklist: View {
    let workspace: Workspace

    static func isComplete(_ workspace: Workspace) -> Bool {
        workspace.studio.claude != nil && !workspace.simulator.devices.isEmpty && workspace.project.readyFolder != nil
    }

    private var studio: StudioModel { workspace.studio }

    var body: some View {
        step(cliTone, "Claude CLI", cliDetail) {
            if case .notInstalled = studio.install { SettingsLink { Text("Install…") } }
        }
        step(studio.claude != nil ? .success : .neutral, "Signed in to Claude",
             studio.claude != nil ? studio.profiles.active.name : "Sign in from Settings.") {
            if studio.cliPath != nil, studio.claude == nil { SettingsLink { Text("Settings…") } }
        }
        step(workspace.simulator.devices.isEmpty ? .neutral : .success, "iOS Simulator",
             workspace.simulator.devices.isEmpty ? "Add an iOS runtime in Xcode." : "\(workspace.simulator.devices.count) available") {
            EmptyView()
        }
        step(workspace.project.readyFolder != nil ? .success : .neutral, "Flutter project",
             workspace.project.readyFolder == nil ? "The folder with pubspec.yaml." : workspace.flutterProject?.name ?? "") {
            if workspace.project.readyFolder == nil { Button("Choose…", action: workspace.chooseProject) }
        }
    }

    private var cliTone: StatusTone {
        switch studio.install {
        case .installed: .success
        case .notInstalled, .failed: .warning
        case .checking: .neutral
        }
    }

    private var cliDetail: String {
        switch studio.install {
        case .checking: "Looking for it…"
        case .notInstalled: "Not installed."
        case .failed(let message): message
        case .installed(_, let version): version
        }
    }

    private func step<Action: View>(_ tone: StatusTone, _ title: String, _ detail: String,
                                    @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: tone == .success ? "checkmark.circle.fill" : tone == .warning ? tone.symbol : "circle")
                .foregroundStyle(tone == .neutral ? Color.secondary : tone.tint)
                .imageScale(.small)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 4)
            action().controlSize(.small)
        }
        .accessibilityElement(children: .contain)
    }
}
