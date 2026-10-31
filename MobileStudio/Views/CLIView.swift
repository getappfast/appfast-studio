import SwiftUI

struct CLICard: View {
    let studio: StudioModel

    var body: some View {
        SectionCard("Claude CLI", systemImage: "terminal") {
            if studio.install == .checking { ProgressView().controlSize(.small) }
            Button("Check again") { Task { await studio.refresh() } }
                .disabled(studio.install == .checking)
        } content: {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch studio.install {
        case .checking:
            Text("Looking for the claude CLI…").foregroundStyle(.secondary)
        case .notInstalled:
            StatusLine(color: .red, title: "Not installed",
                       detail: "Mobile Studio could not find the claude CLI.")
            CommandHint(label: "Install it, then check again:",
                        command: "curl -fsSL https://claude.ai/install.sh | bash")
        case .failed(let message):
            StatusLine(color: .orange, title: "Could not check", detail: message)
        case .installed(let path, let version):
            StatusLine(color: .green, title: "Installed", detail: "Version \(version)")
            Field(label: "Path", value: path, monospaced: true)
        }
    }
}
