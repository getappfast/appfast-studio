import SwiftUI

/// The main window's layout. State and the rules between models live in `Workspace`; this only places the
/// panels and forwards changes to it.
struct ContentView: View {
    let workspace: Workspace

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 420)
        } detail: {
            HStack(spacing: 0) {
                SimulatorPanel(model: workspace.simulator) {
                    RunBar(project: workspace.project, simulator: workspace.simulator, run: workspace.run,
                           fix: workspace.fix, pick: workspace.pick)
                }
                .frame(minWidth: 380)

                Divider()

                ChatPanel(chat: workspace.chat, project: workspace.project, studio: workspace.studio,
                          run: workspace.run, pick: workspace.pick)
                    .frame(minWidth: 340, idealWidth: 400, maxWidth: 520)
            }
        }
        .task { await workspace.start() }
        .onChange(of: workspace.project.path) { workspace.projectPathChanged() }
        .onChange(of: workspace.project.state) { workspace.projectStateChanged() }
        .onChange(of: workspace.simulator.selected?.udid) { workspace.deviceChanged() }
        .onChange(of: workspace.simulator.selected?.isBooted) { workspace.deviceChanged() }
        .onChange(of: workspace.run.phase) { workspace.runPhaseChanged() }
        .onChange(of: workspace.studio.canRunClaude) { _, ready in workspace.claudeAvailabilityChanged(ready) }
    }

    /// Project and its status. Chat and the simulator have their own columns.
    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                ProjectCard(project: workspace.project, studio: workspace.studio, run: workspace.run,
                            fix: workspace.fix, onChoose: workspace.chooseProject)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Mobile Studio").font(.title2.bold())
                Text("Build mobile apps with a coding agent.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            SettingsLink { Label("Settings", systemImage: "gearshape").labelStyle(.iconOnly) }
                .help("Settings (⌘,)")
        }
    }
}
