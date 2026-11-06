import SwiftUI

/// The main window's layout. State and the rules between models live in `Workspace`; this places the
/// panels and forwards changes to it.
struct ContentView: View {
    @Bindable var workspace: Workspace
    let menuBridge: MenuBridge
    @Environment(\.openSettings) private var openSettings
    /// The right edge of the floating sidebar and the left edge of the canvas, in window coordinates.
    @State private var sidebarEdge: CGFloat = 0
    @State private var canvasEdge: CGFloat = 0

    var body: some View {
        NavigationSplitView {
            ProjectSidebar(workspace: workspace)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 380)
                .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .global).maxX }) { sidebarEdge = $0 }
        } detail: {
            VStack(spacing: 0) {
                // Above the device rather than over it, so it never hides the app being worked on.
                WorkspaceBanner(workspace: workspace)
                    .padding([.horizontal, .top], 16)
                    .frame(maxWidth: .infinity)
                    .background(Color(nsColor: .underPageBackgroundColor))
                // The device stays underneath the map: removing it would stop its display stream.
                SimulatorCanvas(model: workspace.deviceModel, isPicking: workspace.pick.isPicking,
                                showsFrame: workspace.showsDeviceFrame)
                    .contextMenu { DeviceRedesignMenu(workspace: workspace) }
                    .opacity(workspace.canvas == .device ? 1 : 0)
                    .accessibilityHidden(workspace.canvas != .device || workspace.project.readyFolder == nil)
                    .overlay {
                        if workspace.project.readyFolder == nil {
                            NoProjectView(workspace: workspace)
                        } else if workspace.canvas == .flow {
                            FlowCanvas(workspace: workspace, leadingInset: max(sidebarEdge - canvasEdge, 0))
                        } else if workspace.canvas == .design {
                            DesignView(workspace: workspace)
                        }
                    }
                    .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .global).minX }) { canvasEdge = $0 }
                    .overlay(alignment: .bottom) { ToastView(workspace: workspace).padding(.bottom, 52) }
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
        .navigationTitle(workspace.flutterProject?.name ?? "AppFast Studio")
        .navigationSubtitle(workspace.project.branch ?? "")
        .toolbar { WorkspaceToolbar(workspace: workspace) }
        .onChange(of: workspace.menuState, initial: true) { _, state in menuBridge.state = state }
        .sheet(isPresented: $workspace.isNewProjectSheetVisible) { NewProjectSheet(workspace: workspace) }
        .sheet(item: $workspace.diffFile) { change in
            if let folder = workspace.project.readyFolder {
                DiffSheet(workspace: workspace, folder: folder, change: change) { workspace.diffFile = nil }
            }
        }
        .modifier(WorkspaceEvents(workspace: workspace))
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: Snapshot.openSettingsNotification)) { _ in openSettings() }
        .onReceive(NotificationCenter.default.publisher(for: Snapshot.runNotification)) { _ in
            Task {
                for _ in 0..<60 where !workspace.canRun { try? await Task.sleep(for: .seconds(1)) }
                workspace.runApp()
                let env = ProcessInfo.processInfo.environment
                if let message = env["MOBILE_STUDIO_SNAPSHOT_CHAT"] {
                    // Send a chat message once the app runs, then optionally undo its edits.
                    for _ in 0..<300 where workspace.run.phase != .running { try? await Task.sleep(for: .seconds(1)) }
                    workspace.chatDraft = message
                    if let folder = workspace.project.readyFolder, let claude = workspace.studio.claude {
                        workspace.chat.send(message, folder: folder, claude: claude, profile: workspace.studio.profiles.active,
                                            approve: workspace.approvalHandler(folder: folder))
                        workspace.chatDraft = ""
                    }
                    if env["MOBILE_STUDIO_SNAPSHOT_CHOOSE"] == "1" {
                        // Pick the recommended options of the answer's choice card, as a click on Do This would.
                        for _ in 0..<120 where workspace.chat.isSending { try? await Task.sleep(for: .seconds(1)) }
                        try? await Task.sleep(for: .seconds(4))
                        if let reply = workspace.chat.messages.last, let choices = ChoiceSet.extract(from: reply.text).choices {
                            workspace.choose(choices.options.filter { $0.recommended == true }.map(\.label), in: reply)
                        }
                        return
                    }
                    guard let delay = env["MOBILE_STUDIO_SNAPSHOT_UNDO_AFTER"].flatMap(Double.init) else { return }
                    for _ in 0..<120 where workspace.chat.isSending { try? await Task.sleep(for: .seconds(1)) }
                    try? await Task.sleep(for: .seconds(delay))
                    if let latest = workspace.chat.undoable.first { workspace.undo(latest) }
                    return
                }
                guard env["MOBILE_STUDIO_SNAPSHOT_FIX"] == "1" else { return }
                for _ in 0..<300 where workspace.visibleFailure == nil { try? await Task.sleep(for: .seconds(1)) }
                workspace.fixFailure()
            }
        }
        #endif
    }
}

/// Forwards model changes to `Workspace`, which decides what each one means. Split out of `ContentView`
/// so its body stays small enough for the type checker.
private struct WorkspaceEvents: ViewModifier {
    let workspace: Workspace

    func body(content: Content) -> some View {
        content
            .task { await workspace.start() }
            .onChange(of: workspace.project.path) { workspace.projectPathChanged() }
            .onChange(of: workspace.project.state) { workspace.projectStateChanged() }
            .onChange(of: workspace.deviceModel.selected?.id) { workspace.deviceChanged() }
            .onChange(of: workspace.deviceModel.selected?.isBooted) { workspace.deviceChanged() }
            .onChange(of: workspace.deviceModel.phase) { workspace.simulatorPhaseChanged() }
            .modifier(ActivityEvents(workspace: workspace))
    }
}

/// The second half of `WorkspaceEvents`, split so neither chain overwhelms the type checker.
private struct ActivityEvents: ViewModifier {
    let workspace: Workspace

    func body(content: Content) -> some View {
        content
            .onChange(of: workspace.run.phase) { workspace.runPhaseChanged() }
            .onChange(of: workspace.fix.phase) { workspace.fixPhaseChanged() }
            .onChange(of: workspace.creator.phase) { workspace.creatorPhaseChanged() }
            .onChange(of: workspace.fix.activity) { workspace.fixActivityChanged() }
            .onChange(of: workspace.chat.isSending) { workspace.chatSendingChanged() }
            .onChange(of: workspace.designChat.isSending) { workspace.designSendingChanged() }
            .onChange(of: workspace.pick.picks.count) { workspace.picksChanged() }
            .onChange(of: workspace.studio.canRunClaude) { _, ready in workspace.claudeAvailabilityChanged(ready) }
    }
}

/// Right-click on the device: redesign the screen it shows. Which screen it is comes from the user, which is
/// always right and costs nothing.
private struct DeviceRedesignMenu: View {
    let workspace: Workspace

    var body: some View {
        let screens = workspace.screens
        Menu("Redesign This Screen") {
            ForEach(screens) { screen in
                Button(screen.name) { workspace.redesign(screen, capture: true) }
            }
        }
        .disabled(screens.isEmpty || !workspace.canCapture)
        Button("Show Design", action: workspace.openDesign)
    }
}

/// A short confirmation over the device ("Updated · 2 files"), with an action when one is needed.
private struct ToastView: View {
    let workspace: Workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let toast = workspace.toast {
                HStack(spacing: 8) {
                    Image(systemName: toast.tone.symbol).foregroundStyle(toast.tone.tint)
                    Text(toast.text)
                    if toast.action == .runAgain {
                        Button("Run Again", action: workspace.runAgain).buttonStyle(.borderedProminent).controlSize(.small)
                        Button { workspace.dismissToast() } label: { Label("Dismiss", systemImage: "xmark").labelStyle(.iconOnly) }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.separator))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isStaticText)
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.3), value: workspace.toast)
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
