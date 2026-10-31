import SwiftUI

@main
struct MobileStudioApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var studio: StudioModel
    @State private var workspace: Workspace
    @State private var dart = DartSDKModel()

    init() {
        // The composition root: app-wide state is made once here and handed down.
        let studio = StudioModel()
        _studio = State(initialValue: studio)
        _workspace = State(initialValue: Workspace(studio: studio))
    }

    var body: some Scene {
        Window("Mobile Studio", id: "main") {
            ContentView(workspace: workspace)
                .frame(minWidth: 1160, minHeight: 680)
        }
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView(studio: studio, dart: dart)
        }
    }
}
