import SwiftUI

/// The sidebar, in two tabs. Project: setup until everything is in place, then the project, its screens, and the
/// history of what Claude changed, each step undoable; project health lives in a popover off the header. Design:
/// Claude's design chat, while the canvas shows the mockups.
struct ProjectSidebar: View {
    let workspace: Workspace

    private var project: ProjectModel { workspace.project }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Sidebar", selection: Binding(get: { workspace.sidebarTab }, set: { workspace.showSidebarTab($0) })) {
                Text("Project").tag(Workspace.SidebarTab.project)
                Text("Design").tag(Workspace.SidebarTab.design)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            if workspace.sidebarTab == .design {
                DesignChatPanel(workspace: workspace)
            } else {
                projectList
            }
        }
    }

    private var projectList: some View {
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
                PlanSection(workspace: workspace)
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
            if let record = workspace.newProjectRecord, record.changed != true {
                StatusBadge(tone: .neutral, title: "New project").font(.callout)
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
    private var approved: [String] { workspace.approvals.approvedCommands(in: flutter.path) }

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
            if !approved.isEmpty {
                Section("Commands Claude May Always Run") {
                    ForEach(approved, id: \.self) { command in
                        HStack {
                            MonospacedValue(command)
                            Spacer()
                            Button { workspace.approvals.forget(command, in: flutter.path) } label: {
                                Label("Ask Again", systemImage: "xmark.circle").labelStyle(.iconOnly)
                            }
                            .buttonStyle(.borderless)
                            .help("Ask before Claude runs this command again")
                        }
                    }
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

// MARK: - Plan

/// The plan's milestones in build order: what is built, what comes next, and a button to build it.
private struct PlanSection: View {
    let workspace: Workspace

    var body: some View {
        if let progress = workspace.milestoneProgress, !progress.plan.milestones.isEmpty {
            Section {
                ForEach(Array(progress.plan.milestones.enumerated()), id: \.offset) { index, milestone in
                    MilestoneRow(workspace: workspace, index: index, milestone: milestone, state: progress.state(of: index))
                }
                Button("Open PLAN.md", systemImage: "doc.text") {
                    if let folder = workspace.project.readyFolder {
                        NSWorkspace.shared.open(URL(fileURLWithPath: folder).appendingPathComponent(ProductPlan.fileName))
                    }
                }
                .buttonStyle(.link)
                .controlSize(.small)
            } header: {
                HStack {
                    Text("Plan")
                    Spacer()
                    Text(progress.summary).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct MilestoneRow: View {
    let workspace: Workspace
    let index: Int
    let milestone: ProductPlan.Milestone
    let state: MilestoneProgress.State

    private var blocker: String? { workspace.buildMilestoneBlocker }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // A symbol as well as a colour: built, next up, or later.
            Image(systemName: symbol).foregroundStyle(state == .done ? Color.green : state == .next ? Color.accentColor : .secondary)
                .imageScale(.small)
            VStack(alignment: .leading, spacing: 1) {
                Text(milestone.title).lineLimit(2)
                if !milestone.doneWhen.isEmpty {
                    Text(milestone.doneWhen).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            if state == .next {
                Button("Build") { workspace.buildMilestone(index) }
                    .controlSize(.small)
                    .disabled(blocker != nil || workspace.chat.isSending)
                    .help(blocker ?? "Claude builds this milestone, and you watch it appear")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(state == .done ? "Built" : state == .next ? "Next" : "Later")
        .contextMenu {
            Button("Build This Milestone") { workspace.buildMilestone(index) }.disabled(blocker != nil || workspace.chat.isSending)
            if state == .done {
                Button("Mark as Not Built") { workspace.setMilestone(index, done: false) }
            } else {
                Button("Mark as Built") { workspace.setMilestone(index, done: true) }
            }
        }
    }

    private var symbol: String {
        switch state {
        case .done: "checkmark.circle.fill"
        case .next: "arrow.right.circle"
        case .later: "circle"
        }
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

    /// The first commit made by New Project is where the history starts.
    private var created: NewProjectRecord? {
        workspace.newProjectRecord.flatMap { $0.request.usesGit && $0.gitNote == nil ? $0 : nil }
    }

    var body: some View {
        if !entries.isEmpty || created != nil {
            Section("History") {
                ForEach(entries) { entry in
                    HistoryRow(workspace: workspace, entry: entry, isLatest: entry.id == workspace.chat.undoable.first?.id)
                }
                if let created {
                    VStack(alignment: .leading, spacing: 1) {
                        Label("Created the app", systemImage: "sparkles")
                        Text(created.created.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
                    }
                    .help("The first version, saved in git when the project was made")
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

/// What has to be in place before AppFast Studio can do its job. Every tool the app can install has an Install
/// button, and Set Up Everything does them all in order; only Xcode needs the user, in the App Store.
struct SetupChecklist: View {
    let workspace: Workspace

    static func isComplete(_ workspace: Workspace) -> Bool {
        let setup = workspace.setup
        // Before the first check, go by what the simulator model already knows, so a set-up Mac doesn't flash the list.
        let tools = setup.requiredReady ?? !workspace.deviceModel.devices.isEmpty
        let busy: Bool = switch setup.phase {
        case .idle: false
        case .working, .waitingForXcode: true
        case .failed(let item, _): item.isRequired
        }
        return tools && !busy && workspace.studio.claude != nil && workspace.project.readyFolder != nil
    }

    private var studio: StudioModel { workspace.studio }
    private var setup: SetupModel { workspace.setup }

    var body: some View {
        if !setup.pendingItems.isEmpty || setup.phase.isWorking { everything }
        tool(.claude)
        step(studio.claude != nil ? .success : .neutral, "Signed in to Claude",
             studio.claude != nil ? studio.profiles.active.name : "Sign in with your Claude account.") {
            if studio.cliPath != nil, studio.claude == nil { SettingsLink { Text("Sign In…") } }
        }
        tool(.xcode)
        tool(.simulator)
        tool(.flutter)
        tool(.cocoapods)
        step(workspace.project.readyFolder != nil ? .success : .neutral, "Flutter project",
             workspace.project.readyFolder == nil ? "Make a new app, or open one you have." : workspace.flutterProject?.name ?? "") {
            if workspace.project.readyFolder == nil {
                Button("New…", action: workspace.newProject).disabled(!workspace.canCreateProject)
                    .help(workspace.createProjectBlocker ?? "Make a new Flutter app")
                Button("Open…", action: workspace.chooseProject)
            }
        }
    }

    // MARK: Set Up Everything

    @ViewBuilder
    private var everything: some View {
        VStack(alignment: .leading, spacing: 6) {
            if setup.phase.isWorking {
                Button("Stop Setup", action: setup.cancel)
                    .help("Stops after the current command. Nothing already installed is removed.")
            } else {
                Button("Set Up Everything", action: setup.installEverything)
                    .buttonStyle(.borderedProminent)
                    .help("Installs each missing tool in order")
                Text(everythingNote).font(.caption).foregroundStyle(.secondary).lineLimit(4)
            }
        }
        .controlSize(.small)
        .padding(.vertical, 2)
    }

    private var everythingNote: String {
        var note = "About \(SetupError.size(setup.pendingDownloadBytes)) to download."
        if case .needed(.getXcode) = setup.status(of: .xcode) { note += " Xcode comes from the App Store: click Get there." }
        if setup.asksForPassword { note += " Your Mac will ask for your password." }
        return note
    }

    // MARK: Tool rows

    @ViewBuilder
    private func tool(_ item: SetupItem) -> some View {
        let status = setup.status(of: item)
        switch setup.phase {
        case .working(item, let progress):
            progressRow(item, progress)
        case .waitingForXcode(let flutter) where item == .xcode:
            waitingRow(flutter)
        case .failed(item, let message):
            step(.warning, item.title, message, lines: 4) {
                Button("Try Again", action: setup.retry)
                Button("Log") { setup.revealLog() }.help("Show the setup log in Finder")
            }
        default:
            step(tone(status, item), title(item), detail(status, item)) {
                if let action = status.action, !setup.phase.isWorking {
                    Button(action.buttonTitle) { setup.install(item) }
                        .help(action.needsPassword ? "Your Mac will ask for your password." : action.explanation)
                }
            }
        }
    }

    private func title(_ item: SetupItem) -> String {
        item.isRequired ? item.title : "\(item.title) (optional)"
    }

    private func tone(_ status: SetupStatus, _ item: SetupItem) -> StatusTone {
        switch status {
        case .ready: .success
        case .needed, .blocked, .checking: .neutral
        }
    }

    private func detail(_ status: SetupStatus, _ item: SetupItem) -> String {
        switch status {
        case .checking: "Looking for it…"
        case .ready(let detail): detail
        case .needed(let action): action.explanation
        case .blocked(let reason): reason
        }
    }

    private func progressRow(_ item: SetupItem, _ progress: InstallProgress) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ProgressView().controlSize(.mini)
            VStack(alignment: .leading, spacing: 3) {
                Text(title(item))
                if let fraction = progress.fraction {
                    ProgressView(value: fraction).controlSize(.small)
                        .accessibilityLabel("\(item.title) progress")
                }
                Text(progressText(progress)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func waitingRow(_ flutter: InstallProgress?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ProgressView().controlSize(.mini)
            VStack(alignment: .leading, spacing: 3) {
                Text("Xcode")
                Text("Click Get in the App Store. Setup carries on by itself when Xcode has arrived.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                if let flutter {
                    Text("Meanwhile: \(progressText(flutter))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Button("Open App Store", action: setup.reopenAppStore).controlSize(.small)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func progressText(_ progress: InstallProgress) -> String {
        guard let fraction = progress.fraction else { return progress.text }
        return "\(progress.text) \(Int((fraction * 100).rounded())) %"
    }

    private func step<Action: View>(_ tone: StatusTone, _ title: String, _ detail: String, lines: Int = 2,
                                    @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: tone == .success ? "checkmark.circle.fill" : tone == .warning ? tone.symbol : "circle")
                .foregroundStyle(tone == .neutral ? Color.secondary : tone.tint)
                .imageScale(.small)
                .accessibilityLabel(tone == .success ? "Done" : tone == .warning ? "Problem" : "To do")
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(lines)
            }
            Spacer(minLength: 4)
            action().controlSize(.small)
        }
        .accessibilityElement(children: .contain)
    }
}
