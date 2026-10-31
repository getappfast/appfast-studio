import SwiftUI

struct SettingsView: View {
    let studio: StudioModel
    let dart: DartSDKModel

    var body: some View {
        TabView {
            page {
                CLICard(studio: studio)
                AccountsCard(studio: studio)
                ModelsCard(studio: studio)
            }
            .tabItem { Label("Claude", systemImage: "sparkles") }

            page { DartSDKCard(dart: dart) }
                .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
                .task { await dart.refresh() }
        }
        .frame(width: 580, height: 640)
    }

    private func page<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) { content() }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct DartSDKCard: View {
    let dart: DartSDKModel

    var body: some View {
        SectionCard("Dart SDK", systemImage: "chevron.left.forwardslash.chevron.right") {
            if dart.state == .checking { ProgressView().controlSize(.small) }
            Button("Check again") { Task { await dart.refresh() } }
                .disabled(dart.state == .checking)
        } content: {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch dart.state {
        case .checking:
            Text("Looking for the Dart SDK…").foregroundStyle(.secondary)
        case .notInstalled:
            StatusLine(color: .red, title: "Not installed",
                       detail: "Mobile Studio could not find the dart command.")
            CommandHint(label: "Install it, then check again:",
                        command: "brew tap dart-lang/dart && brew install dart")
        case .failed(let message):
            StatusLine(color: .orange, title: "Could not check", detail: message)
        case .installed(let install):
            if install.onPath {
                StatusLine(color: .green, title: "Installed and configured", detail: "Version \(install.version)")
            } else {
                StatusLine(color: .orange, title: "Installed, not on PATH", detail: "Version \(install.version)")
            }
            Field(label: "Version", value: install.channel.map { "\(install.version) (\($0))" } ?? install.version)
            Field(label: "Path", value: install.path, monospaced: true)
            if let root = install.flutterRoot {
                Field(label: "Provided by", value: "Flutter SDK")
                Field(label: "Flutter", value: root, monospaced: true)
            }
            Field(label: "PATH", value: install.onPath ? "Found by your shell" : "Not found by your shell")
            if !install.onPath {
                CommandHint(label: "Add it to your shell profile (~/.zshrc):",
                            command: "export PATH=\"$PATH:\(install.binDirectory)\"")
            }
        }
    }
}
