import SwiftUI

/// The Product and View menu items, with the shortcuts Xcode users expect. They call the same `Workspace`
/// actions as the toolbar.
///
/// Titles and enabled states come from `MenuBridge`. SwiftUI doesn't re-evaluate commands when `@Observable`
/// state changes, so reading the workspace directly left Run disabled forever and ⌘R did nothing. Commands do
/// follow an `ObservableObject`, so `ContentView` mirrors `Workspace.menuState` into one.
struct StudioCommands: Commands {
    let workspace: Workspace
    @ObservedObject var bridge: MenuBridge

    private var state: Workspace.MenuState { bridge.state }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Flutter Project…", action: workspace.newProject)
                .keyboardShortcut("n")
                .disabled(!state.canCreateProject)
            Button("Open Flutter Project…", action: workspace.chooseProject)
                .keyboardShortcut("o")
            Button("New Chat") { workspace.chat.reset() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!state.canStartNewChat)
        }

        CommandMenu("Product") {
            Button("Run", action: workspace.runApp)
                .keyboardShortcut("r")
                .disabled(!state.canRun)
            Button("Stop", action: workspace.stopApp)
                .keyboardShortcut(".")
                .disabled(!state.canStop)
            Divider()
            Button("Hot Reload", action: workspace.hotReload)
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!state.canHotReload)
            Button("Hot Restart", action: workspace.hotRestart)
                .keyboardShortcut("r", modifiers: [.command, .shift, .option])
                .disabled(!state.canHotReload)
            Button(state.isPicking ? "Stop Picking" : "Pick Element", action: workspace.togglePick)
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!state.canPick)
            Divider()
            Button("Fix with Claude", action: workspace.fixFailure)
                .disabled(!state.canFix)
            Button("Check Project with Claude", action: workspace.checkProject)
                .disabled(!state.canCheckProject)
        }

        CommandGroup(after: .sidebar) {
            Button("Show Device") { workspace.canvas = .device }
                .keyboardShortcut("1")
                .disabled(state.canvas == .device)
            Button("Show App Flow") { workspace.canvas = .flow }
                .keyboardShortcut("2")
                .disabled(state.canvas == .flow)
            Button(state.showsDeviceFrame ? "Hide Device Frame" : "Show Device Frame") { workspace.showsDeviceFrame.toggle() }
                .disabled(state.canvas != .device)
            Divider()
            // The app flow map's zoom. ⌘= also zooms in (`FlowInput`), as in other Mac apps.
            Button("Zoom In", action: workspace.zoomMapIn)
                .keyboardShortcut("+")
                .disabled(!state.canZoomMapIn)
            Button("Zoom Out", action: workspace.zoomMapOut)
                .keyboardShortcut("-")
                .disabled(!state.canZoomMapOut)
            Button("Actual Size", action: workspace.zoomMapToActualSize)
                .keyboardShortcut("0")
                .disabled(!state.canResizeMap)
            Button("Zoom to Fit", action: workspace.zoomMapToFit)
                .keyboardShortcut("9")
                .disabled(!state.canResizeMap)
            Divider()
            Button("Show Design", action: workspace.openDesign)
                .keyboardShortcut("d", modifiers: [.command, .option])
                .disabled(!state.canOpenDesign || state.canvas == .design)
            Button(state.isChatVisible ? "Hide Chat" : "Show Chat") { workspace.isChatVisible.toggle() }
                .keyboardShortcut("0", modifiers: [.command, .option])
            Button(state.isLogVisible ? "Hide Build Log" : "Show Build Log") { workspace.isLogVisible.toggle() }
                .keyboardShortcut("y", modifiers: [.command, .shift])
            Divider()
        }
    }
}

/// `Workspace.menuState`, republished for the menu bar (see `StudioCommands`).
@MainActor
final class MenuBridge: ObservableObject {
    @Published var state: Workspace.MenuState

    init(_ state: Workspace.MenuState) { self.state = state }
}
