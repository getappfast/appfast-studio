import SwiftUI

/// The sidebar: setup until everything is in place, then the project, what's wrong with it, what Claude
/// changed, its flavors and Claude's check of it.
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
                IssuesSection(workspace: workspace, flutter: flutter)
                ChangesSection(workspace: workspace)
                FlavorsSection(project: project)
                CheckSection(workspace: workspace)
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

    private var project: ProjectModel { workspace.project }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(flutter.name).font(.headline).lineLimit(1)
                if let version = flutter.version { Text(version).foregroundStyle(.secondary).font(.callout) }
                Spacer(minLength: 4)
                actions
            }
            status
            if let branch = project.branch {
                Label(branch, systemImage: "arrow.triangle.branch").foregroundStyle(.secondary).lineLimit(1)
                    .help("Current git branch")
            }
            Label(flutter.platforms.isEmpty ? "No platform folders" : flutter.platforms.joined(separator: ", "),
                  systemImage: "square.stack.3d.up")
                .foregroundStyle(.secondary).lineLimit(1)
        }
        .font(.callout)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var status: some View {
        switch project.verification {
        case .idle: StatusBadge(tone: .neutral, title: "Not checked yet")
        case .running: StatusBadge(tone: .neutral, title: "Claude is checking…")
        case .done(let verdict):
            StatusBadge(tone: verdict.isFlutterProject ? .success : .failure,
                        title: verdict.isFlutterProject ? "Valid Flutter project" : "Not a valid Flutter project")
        case .failed: StatusBadge(tone: .warning, title: "Claude couldn't check it")
        }
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

// MARK: - Issues

private struct IssuesSection: View {
    let workspace: Workspace
    let flutter: FlutterProject

    private var problems: [String] {
        guard case .done(let verdict) = workspace.project.verification else { return [] }
        return verdict.problems
    }

    private var hasIssues: Bool {
        workspace.visibleFailure != nil || !problems.isEmpty || workspace.project.refreshNote != nil
            || !flutter.hasMainDart || !flutter.platforms.contains("ios") || isCheckFailed
    }

    private var isCheckFailed: Bool {
        if case .failed = workspace.project.verification { return true }
        return false
    }

    var body: some View {
        if hasIssues {
            Section("Issues") {
                if let failure = workspace.visibleFailure {
                    Button { workspace.isLogVisible = true } label: {
                        IssueRow(tone: .failure, title: "Run failed", detail: failure.message)
                    }
                    .buttonStyle(.plain)
                    .help("Show the build log")
                }
                if !flutter.platforms.contains("ios") {
                    IssueRow(tone: .warning, title: "No ios folder", detail: "It can't run in the iOS Simulator.")
                }
                if !flutter.hasMainDart {
                    IssueRow(tone: .warning, title: "lib/main.dart is missing", detail: nil)
                }
                ForEach(problems, id: \.self) { IssueRow(tone: .warning, title: $0, detail: nil) }
                if case .failed(let message) = workspace.project.verification {
                    IssueRow(tone: .warning, title: "Claude couldn't check the project", detail: message)
                }
                if let note = workspace.project.refreshNote {
                    IssueRow(tone: .warning, title: note, detail: nil)
                }
            }
        }
    }
}

private struct IssueRow: View {
    let tone: StatusTone
    let title: String
    let detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: tone.symbol).foregroundStyle(tone.tint).imageScale(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(2)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Changes

private struct ChangesSection: View {
    let workspace: Workspace

    var body: some View {
        let changes = workspace.chat.changedFiles
        if !changes.isEmpty {
            Section("Changes (\(changes.count))") {
                ForEach(changes) { change in
                    Button { workspace.showDiff(of: change) } label: {
                        FileChangeRow(change: change).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show what changed in \(change.path)")
                    .contextMenu {
                        Button("Show Changes") { workspace.showDiff(of: change) }
                        if change.kind != .deleted, let folder = workspace.project.readyFolder {
                            let url = URL(fileURLWithPath: folder).appendingPathComponent(change.path)
                            Button("Open") { NSWorkspace.shared.open(url) }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Flavors

private struct FlavorsSection: View {
    let project: ProjectModel

    var body: some View {
        if !project.flavors.isEmpty {
            Section("Flavors") {
                ForEach(project.flavors) { flavor in
                    Button { project.selectFlavor(flavor) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "checkmark")
                                .opacity(flavor == project.runFlavor ? 1 : 0)
                                .frame(width: 12)
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(flavor.name).fontWeight(.medium)
                                    Text(flavor.platforms.joined(separator: ", ")).foregroundStyle(.secondary)
                                }
                                Text(flavor.runCommand).font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(flavor == project.runFlavor ? .isSelected : [])
                    .help("Run uses this flavor")
                }
            }
        }
    }
}

// MARK: - Check

private struct CheckSection: View {
    let workspace: Workspace

    private var project: ProjectModel { workspace.project }

    var body: some View {
        Section("Project Check") {
            VStack(alignment: .leading, spacing: 8) {
                if case .done(let verdict) = project.verification {
                    Text(verdict.summary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                } else if case .running = project.verification {
                    Text("Claude is reading the project…").foregroundStyle(.secondary)
                } else {
                    Text("Claude reads the project, without changing it, to confirm it's a Flutter app and find its flavors.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button(project.verification == .idle ? "Check with Claude" : "Check Again", action: workspace.checkProject)
                        .disabled(workspace.studio.projectVerifier == nil || project.verification == .running || project.refreshing)
                    if project.refreshing || project.verification == .running {
                        ProgressView().controlSize(.small)
                    } else if let checked = project.lastChecked {
                        Text(checked, format: .relative(presentation: .named)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button("Log") { project.revealLog() }.buttonStyle(.link)
                }
                .controlSize(.small)
            }
            .font(.callout)
            .padding(.vertical, 4)
        }
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
