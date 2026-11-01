import SwiftUI

@main
struct MobileStudioApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var studio: StudioModel
    @State private var workspace: Workspace
    @StateObject private var menuBridge: MenuBridge

    init() {
        // The composition root: app-wide state is made once here and handed down.
        let studio = StudioModel()
        _studio = State(initialValue: studio)
        let workspace = Workspace(studio: studio)
        workspace.runsAutomaticChecks = !AppDelegate.isSnapshotRun
        #if DEBUG
        if ProcessInfo.processInfo.environment["MOBILE_STUDIO_SNAPSHOT_LOG"] == "1" { workspace.isLogVisible = true }
        Snapshot.workspace = workspace
        #endif
        _workspace = State(initialValue: workspace)
        _menuBridge = StateObject(wrappedValue: MenuBridge(workspace.menuState))
    }

    var body: some Scene {
        Window("Mobile Studio", id: "main") {
            ContentView(workspace: workspace, menuBridge: menuBridge)
                .frame(minWidth: 1160, minHeight: 680)
        }
        .windowResizability(.contentMinSize)
        .commands { StudioCommands(workspace: workspace, bridge: menuBridge) }

        Settings {
            SettingsView(studio: studio, dart: workspace.dart)
        }
    }
}
