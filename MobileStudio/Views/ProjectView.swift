import SwiftUI

struct ProjectCard: View {
    let project: ProjectModel
    let studio: StudioModel
    let run: FlutterRunModel
    let fix: FixModel
    let onChoose: () -> Void

    @AppStorage("project.details.expanded") private var detailsExpanded = false

    var body: some View {
        SectionCard("Flutter project", systemImage: "folder") {
            if project.path != nil {
                Button { project.recheck() } label: {
                    Label("Check again", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
                }
                .help("Check the folder again")
            }
            Button(project.path == nil ? "Choose folder…" : "Change…", action: onChoose)
        } content: {
            content
        }
    }

    // MARK: Layout

    @ViewBuilder
    private var content: some View {
        switch project.state {
        case .none:
            Text("Choose the folder of the Flutter app you want to work on.").foregroundStyle(.secondary)
        case .invalid(let path, let reason):
            StatusLine(color: .orange, title: "Can't use this folder", detail: nil)
            Text(reason).foregroundStyle(.secondary)
            details {
                Field(label: "Folder", value: path, monospaced: true)
                claudeDetails
                if case .idle = project.verification, let verifier = studio.projectVerifier {
                    Button("Verify with Claude") { project.verify(with: verifier) }.controlSize(.small)
                }
                actions
            }
        case .ready(let flutter):
            summary(flutter)
            runPanel
            details {
                Field(label: "Folder", value: flutter.path, monospaced: true)
                if let constraint = flutter.dartConstraint { Field(label: "Dart SDK", value: constraint) }
                Field(label: "Platforms", value: flutter.platforms.isEmpty ? "None yet" : flutter.platforms.joined(separator: ", "))
                if !flutter.hasMainDart { Text("lib/main.dart is missing.").foregroundStyle(.orange) }
                claudeDetails
                actions
            }
        }
    }

    /// Failure, fix and build output. Only takes space when there is something to show.
    @ViewBuilder
    private var runPanel: some View {
        let panel = RunPanel(project: project, studio: studio, run: run, fix: fix)
        if panel.hasContent { panel }
    }

    private func details<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let inner = content()
        return DisclosureGroup("Details", isExpanded: $detailsExpanded) {
            VStack(alignment: .leading, spacing: 10) { inner }
                .padding(.top, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Minimal view

    private func summary(_ flutter: FlutterProject) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            statusRow(flutter)
            HStack(spacing: 12) {
                Text(([flutter.folderName] + [flutter.platforms.joined(separator: ", ")].filter { !$0.isEmpty }).joined(separator: " · "))
                if let branch = project.branch {
                    Label(branch, systemImage: "arrow.triangle.branch").lineLimit(1).help("Current git branch")
                }
            }
            .foregroundStyle(.secondary)
            if case .done(let verdict) = project.verification, verdict.isFlutterProject {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Flavors").foregroundStyle(.secondary)
                    Text(verdict.flavors.isEmpty ? "None" : verdict.flavors.map(\.name).joined(separator: ", "))
                        .lineLimit(2)
                }
            }
            if let note = project.refreshNote { Text(note).foregroundStyle(.orange) }
        }
    }

    @ViewBuilder
    private func statusRow(_ flutter: FlutterProject) -> some View {
        HStack(alignment: .top, spacing: 8) {
            switch project.verification {
            case .idle:
                statusBlock(.secondary, flutter, "Not verified yet")
                Spacer(minLength: 4)
                if let verifier = studio.projectVerifier {
                    Button("Verify") { project.verify(with: verifier) }.controlSize(.small)
                        .help("Have Claude check this project")
                }
            case .running:
                statusBlock(.secondary, flutter, "Claude is checking…")
                Spacer(minLength: 4)
                ProgressView().controlSize(.small)
            case .done(let verdict):
                statusBlock(verdict.isFlutterProject ? .green : .red, flutter,
                            verdict.isFlutterProject ? "Valid Flutter project" : "Not a valid Flutter project")
                Spacer(minLength: 4)
                if project.refreshing { ProgressView().controlSize(.small) }
            case .failed(let message):
                statusBlock(.orange, flutter, "Claude couldn't check")
                Spacer(minLength: 4)
                if let verifier = studio.projectVerifier {
                    Button("Retry") { project.verify(with: verifier) }.controlSize(.small)
                }
                Button("Log") { project.revealLog() }.controlSize(.small).help(message)
            }
        }
        if case .failed(let message) = project.verification {
            Text(message).foregroundStyle(.secondary)
        }
    }

    /// Dot and project name, with the version and verdict underneath.
    private func statusBlock(_ color: Color, _ flutter: FlutterProject, _ status: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(color).frame(width: 9, height: 9).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(flutter.name).fontWeight(.semibold)
                Text(detail(flutter, status)).foregroundStyle(.secondary)
            }
        }
    }

    private func detail(_ flutter: FlutterProject, _ status: String) -> String {
        [flutter.version.map { "v\($0)" }, status].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Details

    /// Claude's full read of the folder: summary, problems, flavors with their run commands.
    @ViewBuilder
    private var claudeDetails: some View {
        if case .done(let verdict) = project.verification {
            Divider()
            Text(verdict.summary).textSelection(.enabled)
            if !verdict.problems.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Problems").foregroundStyle(.secondary)
                    ForEach(verdict.problems, id: \.self) { problem in
                        Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }
            }
            // With no flavors the summary already says so.
            if verdict.isFlutterProject, !verdict.flavors.isEmpty { flavorList(verdict.flavors) }
            HStack(spacing: 8) {
                if let verifier = studio.projectVerifier {
                    Button("Ask again") { project.verify(with: verifier) }
                        .controlSize(.small)
                        .disabled(project.refreshing)
                }
                if project.refreshing {
                    ProgressView().controlSize(.small)
                    Text("Re-checking with Claude…").foregroundStyle(.secondary)
                } else if let checked = project.lastChecked {
                    Text("Checked \(checked, format: .relative(presentation: .named))").foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func flavorList(_ flavors: [RunFlavor]) -> some View {
        Text("Runnable flavors").foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(flavors) { flavor in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(flavor.name).fontWeight(.semibold)
                        Text(flavor.platforms.joined(separator: ", ")).foregroundStyle(.secondary)
                    }
                    Text(flavor.runCommand)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var actions: some View {
        HStack {
            Button("Show in Finder") { project.revealInFinder() }
            Button("Remove", role: .destructive) { project.clear() }
        }
        .controlSize(.small)
    }
}
