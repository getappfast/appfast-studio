import SwiftUI

/// The main window's layout. State and the rules between models live in `Workspace`; this places the
/// panels and forwards changes to it.
struct ContentView: View {
    @Bindable var workspace: Workspace
    let menuBridge: MenuBridge
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        NavigationSplitView {
            ProjectSidebar(workspace: workspace)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 380)
        } detail: {
            VStack(spacing: 0) {
                // Above the device rather than over it, so it never hides the app being worked on.
                WorkspaceBanner(workspace: workspace)
                    .padding([.horizontal, .top], 16)
                    .frame(maxWidth: .infinity)
                    .background(Color(nsColor: .underPageBackgroundColor))
                SimulatorCanvas(model: workspace.simulator)
                if workspace.isLogVisible {
                    Divider()
                    LogDrawer(workspace: workspace)
                }
            }
            // No minimum width here: on macOS 26 the detail column also reserves the floating sidebar's width,
            // so a minimum on the content is paid twice and pushes the inspector off the window.
            .inspector(isPresented: $workspace.isChatVisible) {
                ChatPanel(workspace: workspace)
                    .inspectorColumnWidth(min: 300, ideal: 360, max: 540)
            }
        }
        .navigationTitle(workspace.flutterProject?.name ?? "Mobile Studio")
        .navigationSubtitle(workspace.project.branch ?? "")
        .toolbar { WorkspaceToolbar(workspace: workspace) }
        .onChange(of: workspace.menuState, initial: true) { _, state in menuBridge.state = state }
        .sheet(item: $workspace.diffFile) { change in
            if let folder = workspace.project.readyFolder {
                DiffSheet(folder: folder, change: change) { workspace.diffFile = nil }
            }
        }
        .task { await workspace.start() }
        .onChange(of: workspace.project.path) { workspace.projectPathChanged() }
        .onChange(of: workspace.project.state) { workspace.projectStateChanged() }
        .onChange(of: workspace.simulator.selected?.udid) { workspace.deviceChanged() }
        .onChange(of: workspace.simulator.selected?.isBooted) { workspace.deviceChanged() }
        .onChange(of: workspace.simulator.phase) { workspace.simulatorPhaseChanged() }
        .onChange(of: workspace.run.phase) { workspace.runPhaseChanged() }
        .onChange(of: workspace.fix.phase) { workspace.fixPhaseChanged() }
        .onChange(of: workspace.fix.activity) { workspace.fixActivityChanged() }
        .onChange(of: workspace.studio.canRunClaude) { _, ready in workspace.claudeAvailabilityChanged(ready) }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: Snapshot.openSettingsNotification)) { _ in openSettings() }
        .onReceive(NotificationCenter.default.publisher(for: Snapshot.runNotification)) { _ in
            Task {
                for _ in 0..<60 where !workspace.canRun { try? await Task.sleep(for: .seconds(1)) }
                workspace.runApp()
                guard ProcessInfo.processInfo.environment["MOBILE_STUDIO_SNAPSHOT_FIX"] == "1" else { return }
                for _ in 0..<300 where workspace.visibleFailure == nil { try? await Task.sleep(for: .seconds(1)) }
                workspace.fixFailure()
            }
        }
        #endif
    }
}

/// The one notice that matters most right now, floating over the device.
private struct WorkspaceBanner: View {
    let workspace: Workspace

    var body: some View {
        if workspace.fix.phase == .fixing || workspace.fix.phase == .validating {
            Banner(tone: .neutral,
                   title: workspace.fix.phase == .fixing ? "Claude is fixing the project" : "Checking the fix",
                   message: workspace.fix.activity.last ?? "This can take a few minutes while Claude builds the app.",
                   showsProgress: true) {
                Button("Cancel", action: workspace.cancelFix)
                if !workspace.isChatVisible { Button("Show in Chat") { workspace.isChatVisible = true } }
            }
        } else if let failure = workspace.visibleFailure, !workspace.isFailureDismissed {
            Banner(tone: .failure, title: "Run failed", message: failure.message, onDismiss: workspace.dismissFailure) {
                Button(action: workspace.fixFailure) { Label("Fix with Claude", systemImage: "wand.and.stars") }
                    .buttonStyle(.borderedProminent)
                    .disabled(workspace.fixBlocker != nil)
                    .help(workspace.fixBlocker ?? "Claude finds the cause, changes the project, and the app runs again to check it.")
                Button("Show Log") { workspace.isLogVisible = true }
            }
        } else if let app = workspace.run.existing, !workspace.run.phase.isActive {
            Banner(tone: .neutral, title: "\(workspace.flutterProject?.name ?? "The app") is already running",
                   message: "It was started by an earlier run (\(app.bundleID)). Reconnect to use Hot Reload and Pick again.") {
                Button("Reconnect", action: workspace.reconnect).buttonStyle(.borderedProminent)
                Button("Stop It", action: workspace.stopExistingApp)
            }
        } else if let error = workspace.run.reconnectError, !workspace.run.phase.isActive {
            Banner(tone: .warning, title: "Couldn't reconnect", message: error)
        } else if case .picking = workspace.pick.phase {
            Banner(tone: .neutral, title: "Tap an element in the app", message: "It will be attached to your next chat message.") {
                Button("Cancel") { workspace.pick.cancel() }
            }
        }
    }
}
