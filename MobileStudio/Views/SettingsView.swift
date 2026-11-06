import SwiftUI

struct SettingsView: View {
    let studio: StudioModel
    let dart: DartSDKModel

    var body: some View {
        TabView {
            Form {
                CLISection(studio: studio)
                AccountsSection(studio: studio)
                ModelsSection(studio: studio)
            }
            .formStyle(.grouped)
            .tabItem { Label("Claude", systemImage: "sparkles") }

            Form {
                DartSDKSection(dart: dart)
                AndroidEmulatorSection()
            }
                .formStyle(.grouped)
                .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
                .task { await dart.refresh() }
        }
        .frame(width: 600, height: 620)
    }
}

/// What happens to emulators this app started when it quits.
private struct AndroidEmulatorSection: View {
    @AppStorage(AndroidQuitChoice.key) private var choice = AndroidQuitChoice.ask.rawValue

    var body: some View {
        Section {
            Picker("When quitting", selection: $choice) {
                Text("Ask me").tag(AndroidQuitChoice.ask.rawValue)
                Text("Keep emulators running").tag(AndroidQuitChoice.keep.rawValue)
                Text("Shut them down").tag(AndroidQuitChoice.shutDown.rawValue)
            }
            Text("Only emulators AppFast Studio started are affected. Ones you started elsewhere are never touched.")
                .font(.callout).foregroundStyle(.secondary)
        } header: {
            Text("Android emulators")
        }
    }
}

/// A Settings section header with its controls on the right.
struct SettingsHeader<Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            accessory().controlSize(.small).font(.body)
        }
    }
}

private struct DartSDKSection: View {
    let dart: DartSDKModel

    var body: some View {
        Section {
            content
        } header: {
            SettingsHeader(title: "Dart SDK") {
                if dart.state == .checking { ProgressView().controlSize(.small) }
                Button("Check Again") { Task { await dart.refresh() } }
                    .disabled(dart.state == .checking)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch dart.state {
        case .checking:
            Text("Looking for the Dart SDK…").foregroundStyle(.secondary)
        case .notInstalled:
            StatusBadge(tone: .failure, title: "Not installed", detail: "AppFast Studio could not find the dart command.")
            CommandHint(label: "Install it, then check again:", command: "brew tap dart-lang/dart && brew install dart")
        case .failed(let message):
            StatusBadge(tone: .warning, title: "Could not check", detail: message)
        case .installed(let install):
            if install.onPath {
                StatusBadge(tone: .success, title: "Installed and configured")
            } else {
                StatusBadge(tone: .warning, title: "Installed, not on PATH")
            }
            LabeledContent("Version", value: install.channel.map { "\(install.version) (\($0))" } ?? install.version)
            LabeledContent("Path") { MonospacedValue(install.path) }
            if let root = install.flutterRoot {
                LabeledContent("Provided by", value: "Flutter SDK")
                LabeledContent("Flutter") { MonospacedValue(root) }
            }
            LabeledContent("PATH", value: install.onPath ? "Found by your shell" : "Not found by your shell")
            if !install.onPath {
                CommandHint(label: "Add it to your shell profile (~/.zshrc):",
                            command: "export PATH=\"$PATH:\(install.binDirectory)\"")
            }
        }
    }
}

/// A path or ID: monospaced, selectable, shortened in the middle when it doesn't fit.
struct MonospacedValue: View {
    let value: String
    init(_ value: String) { self.value = value }

    var body: some View {
        Text(value)
            .font(.system(.callout, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .help(value)
    }
}
