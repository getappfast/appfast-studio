import SwiftUI

struct CLISection: View {
    let studio: StudioModel

    var body: some View {
        Section {
            content
        } header: {
            SettingsHeader(title: "Claude CLI") {
                if studio.install == .checking { ProgressView().controlSize(.small) }
                Button("Check Again") { Task { await studio.refresh() } }
                    .disabled(studio.install == .checking)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch studio.install {
        case .checking:
            Text("Looking for the claude CLI…").foregroundStyle(.secondary)
        case .notInstalled:
            StatusBadge(tone: .failure, title: "Not installed", detail: "Mobile Studio could not find the claude CLI.")
            CommandHint(label: "Install it, then check again:", command: "curl -fsSL https://claude.ai/install.sh | bash")
        case .failed(let message):
            StatusBadge(tone: .warning, title: "Could not check", detail: message)
        case .installed(let path, let version):
            LabeledContent("Status") { StatusBadge(tone: .success, title: "Installed") }
            LabeledContent("Version", value: version)
            LabeledContent("Path") { MonospacedValue(path) }
        }
    }
}
