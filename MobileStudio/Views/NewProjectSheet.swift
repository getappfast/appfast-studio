import SwiftUI

/// File ▸ New Flutter Project…: three short steps, then progress while the project is made.
struct NewProjectSheet: View {
    let workspace: Workspace

    private enum Step: Int, CaseIterable { case about, location, platforms }

    @State private var step: Step = .about
    @State private var name = ""
    @State private var description = ""
    @State private var appID = ""
    @State private var packageOverride: String?
    @State private var parent = NewProjectDefaults.initialParent()
    @State private var usesGit = true
    @State private var platforms: Set<ProjectPlatform> = [.ios, .android]
    /// Missing tools found before Create, shown as warnings on the last step.

    private var creator: NewProjectModel { workspace.creator }

    init(workspace: Workspace) {
        self.workspace = workspace
        #if DEBUG
        // Snapshot runs open the sheet on a given step with a name filled in (MOBILE_STUDIO_SNAPSHOT_SHEET=0|1|2).
        if let raw = ProcessInfo.processInfo.environment["MOBILE_STUDIO_SNAPSHOT_SHEET"], let index = Int(raw), let start = Step(rawValue: index) {
            _step = State(initialValue: start)
            _name = State(initialValue: "Water Tracker")
            _description = State(initialValue: "Reminds me to drink water and shows my day.")
        }
        #endif
    }

    private var packageName: String { packageOverride ?? PackageName.derive(from: name) }

    private var request: NewProjectRequest {
        NewProjectRequest(
            displayName: name, packageName: packageName,
            description: description, appID: appID.trimmingCharacters(in: .whitespaces).nonEmpty,
            parentFolder: parent, platforms: platforms, usesGit: usesGit)
    }

    var body: some View {
        VStack(spacing: 0) {
            if creator.phase == .idle {
                form
            } else {
                NewProjectProgress(workspace: workspace)
            }
        }
        .frame(width: 500)
        .interactiveDismissDisabled(creator.isWorking)
    }

    // MARK: Steps

    private var form: some View {
        let issues = request.validate()
        return VStack(spacing: 0) {
            Form {
                switch step {
                case .about: about(issues)
                case .location: location(issues)
                case .platforms: platformsStep(issues)
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: 330)

            Divider()
            HStack {
                Button("Cancel", role: .cancel, action: workspace.closeNewProjectSheet)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if step != .about { Button("Back") { move(-1) } }
                if step == .platforms {
                    Button("Create") { workspace.creator.create(request) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(issues.contains { $0.severity == .error })
                } else {
                    Button("Next") { move(1) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(blocked(in: step, issues))
                }
            }
            .padding(16)
        }
    }

    private func move(_ delta: Int) {
        step = Step(rawValue: step.rawValue + delta) ?? step
    }

    /// Errors in this step's own fields keep Next off.
    private func blocked(in step: Step, _ issues: [NewProjectRequest.Issue]) -> Bool {
        let fields: [NewProjectRequest.Issue.Field] = switch step {
        case .about: [.name, .appID]
        case .location: [.folder]
        case .platforms: [.platforms]
        }
        return issues.contains { $0.severity == .error && fields.contains($0.field) }
    }

    private func about(_ issues: [NewProjectRequest.Issue]) -> some View {
        Group {
            Section {
                TextField("App name", text: $name, prompt: Text("Water Tracker"))
                TextField("What does it do?", text: $description, prompt: Text("Reminds me to drink water and shows my day."), axis: .vertical)
                    .lineLimit(3...5)
                Text("One to three sentences. Claude uses this to ask better questions later.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                TextField("App ID (optional)", text: $appID, prompt: Text(AppID.standard(forPackage: packageName)))
                    .autocorrectionDisabled()
                IssueList(issues: issues, fields: [.name, .appID])
                DisclosureGroup("Package name: \(packageName)") {
                    TextField("Package name", text: Binding(get: { packageName }, set: { packageOverride = $0 }))
                        .autocorrectionDisabled()
                    Button("Use the name above") { packageOverride = nil }.disabled(packageOverride == nil)
                }
            }
        }
    }

    private func location(_ issues: [NewProjectRequest.Issue]) -> some View {
        Section {
            LabeledContent("Folder") {
                HStack {
                    Text(parent).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Button("Choose…", action: chooseParent)
                }
            }
            LabeledContent("Your app will be at") { MonospacedValue(request.path) }
            Toggle("Track changes with git", isOn: $usesGit)
            Text(usesGit ? "Saved on this Mac only. Nothing is uploaded." : "History and diffs need git.")
                .font(.caption).foregroundStyle(.secondary)
            IssueList(issues: issues, fields: [.folder])
        }
    }

    private func platformsStep(_ issues: [NewProjectRequest.Issue]) -> some View {
        Group {
            Section("Platforms") {
                ForEach(ProjectPlatform.allCases, id: \.self) { platform in
                    Toggle(isOn: Binding(
                        get: { platforms.contains(platform) },
                        set: { isOn in if isOn { platforms.insert(platform) } else { platforms.remove(platform) } }
                    )) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(platform.title)
                            if platform.isRequired {
                                Text("The preview runs in the iOS Simulator.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(platform.isRequired)
                    .help("Adds the \(platform.rawValue) folder")
                }
                IssueList(issues: issues, fields: [.platforms])
            }
            Section("Summary") {
                Text(summary).fixedSize(horizontal: false, vertical: true)
                IssueList(issues: issues, fields: [.name, .appID, .folder])
                ForEach(workspace.toolchainProblems, id: \.self) { StatusBadge(tone: .warning, title: $0).fontWeight(.regular).font(.callout) }
            }
        }
    }

    private var summary: String {
        let names = ProjectPlatform.allCases.filter { platforms.contains($0) }.map { $0 == .ios ? "iPhone" : $0.title }
        let list = ListFormatter.localizedString(byJoining: names)
        let place = (request.path as NSString).abbreviatingWithTildeInPath
        return "Create \(name.isEmpty ? "your app" : name) in \(place) for \(list), \(usesGit ? "with git" : "without git")."
    }

    private func chooseParent() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the folder that will hold your new app."
        panel.directoryURL = URL(fileURLWithPath: parent)
        if panel.runModal() == .OK, let url = panel.url { parent = url.path }
    }
}

/// Errors and warnings for some fields, each with a symbol as well as a colour.
private struct IssueList: View {
    let issues: [NewProjectRequest.Issue]
    let fields: [NewProjectRequest.Issue.Field]

    var body: some View {
        ForEach(Array(issues.filter { fields.contains($0.field) }.enumerated()), id: \.offset) { _, issue in
            StatusBadge(tone: issue.severity == .error ? .failure : .warning, title: issue.message)
                .fontWeight(.regular)
                .font(.callout)
        }
    }
}

/// The checklist shown while the project is made, with what to do when a step fails.
private struct NewProjectProgress: View {
    let workspace: Workspace

    private var creator: NewProjectModel { workspace.creator }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Creating \(creator.request?.displayName ?? "your app")").font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 10) {
                ForEach(creator.steps, id: \.self) { step in
                    HStack(spacing: 8) {
                        icon(for: step)
                        Text(step.title).foregroundStyle(isPending(step) ? .secondary : .primary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(state(of: step))
                }
            }
            if case .failed(_, let message) = creator.phase {
                StatusBadge(tone: .failure, title: message).fixedSize(horizontal: false, vertical: true)
                Text("The folder was kept. Retry continues from where it stopped.").font(.caption).foregroundStyle(.secondary)
            }
            if let note = creator.note {
                Text(note).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack {
                Button("Show Log") { creator.log.reveal() }
                if let path = creator.request?.path, FileManager.default.fileExists(atPath: path) {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                }
                Spacer()
                if case .failed = creator.phase {
                    Button("Close", action: workspace.closeNewProjectSheet)
                    Button("Start Over", action: creator.reset)
                        .help("Go back to the form. The folder already made stays where it is.")
                    Button("Retry", action: creator.retry).buttonStyle(.borderedProminent)
                } else {
                    Button("Stop", action: workspace.closeNewProjectSheet)
                        .help("Stops creating the app. You can pick up again from here.")
                }
            }
        }
        .padding(20)
    }

    private func state(of step: CreateStep) -> String {
        switch creator.phase {
        case .working(let current) where current == step: return "In progress"
        case .failed(let failed, _) where failed == step: return "Failed"
        default: return creator.completed.contains(step) ? "Done" : "Waiting"
        }
    }

    private func isPending(_ step: CreateStep) -> Bool {
        if creator.completed.contains(step) { return false }
        switch creator.phase {
        case .working(let current), .failed(let current, _): return step > current
        default: return false
        }
    }

    @ViewBuilder
    private func icon(for step: CreateStep) -> some View {
        switch creator.phase {
        case .working(let current) where current == step:
            ProgressView().controlSize(.small).frame(width: 16)
        case .failed(let failed, _) where failed == step:
            Image(systemName: StatusTone.failure.symbol).foregroundStyle(StatusTone.failure.tint).frame(width: 16)
        default:
            if creator.completed.contains(step) {
                Image(systemName: StatusTone.success.symbol).foregroundStyle(StatusTone.success.tint).frame(width: 16)
            } else {
                Image(systemName: "circle").foregroundStyle(.secondary).frame(width: 16)
            }
        }
    }
}

/// Shown over the device while no project is open.
struct NoProjectView: View {
    let workspace: Workspace

    var body: some View {
        ContentUnavailableView {
            Label("Start an App", systemImage: "iphone.gen3")
        } description: {
            Text(workspace.createProjectBlocker ?? "Make a new Flutter app, or open one you already have.")
        } actions: {
            Button("New Project…", action: workspace.newProject)
                .buttonStyle(.borderedProminent)
                .disabled(!workspace.canCreateProject)
            Button("Open Project…", action: workspace.chooseProject)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}
