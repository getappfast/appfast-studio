import SwiftUI

struct ModelsCard: View {
    let studio: StudioModel
    @State private var custom = ""

    private var models: ClaudeModelsModel { studio.models }

    var body: some View {
        SectionCard("Models", systemImage: "cpu") {
            if models.isChecking { ProgressView().controlSize(.small) }
            Button("Check models") { Task { await studio.checkModels() } }
                .disabled(!studio.canCheckModels || models.isChecking)
        } content: {
            if !studio.canCheckModels {
                Text("Install the claude CLI and sign in to check which models you can use.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Checking as \(studio.profiles.active.name)")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(models.targets) { target in
                    ModelRow(target: target, state: models.state(for: target))
                }
                Divider()
                customField
                Text("The CLI can't list models, so each check sends one tiny prompt (about $0.01 in total).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var customField: some View {
        HStack {
            TextField("Another model, e.g. claude-opus-5-5", text: $custom)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submitCustom)
            Button("Check", action: submitCustom)
                .disabled(custom.trimmingCharacters(in: .whitespaces).isEmpty || models.isChecking)
        }
    }

    private func submitCustom() {
        guard !models.isChecking else { return }
        let name = custom
        custom = ""
        Task { await studio.checkCustomModel(name) }
    }
}

private struct ModelRow: View {
    let target: ModelProbeTarget
    let state: ModelProbeState

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            indicator.frame(width: 12)
            Text(target.name).fontWeight(.semibold).frame(width: 90, alignment: .leading)
            detail
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var indicator: some View {
        switch state {
        case .idle: Circle().strokeBorder(.secondary, lineWidth: 1).frame(width: 9, height: 9)
        case .checking: ProgressView().controlSize(.mini)
        case .available: Circle().fill(.green).frame(width: 9, height: 9)
        case .substituted: Circle().fill(.orange).frame(width: 9, height: 9)
        case .unavailable: Circle().fill(.red).frame(width: 9, height: 9)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch state {
        case .idle:
            Text("Not checked").foregroundStyle(.secondary)
        case .checking:
            Text("Checking…").foregroundStyle(.secondary)
        case .available(let result):
            VStack(alignment: .leading, spacing: 2) {
                Text(result.resolvedID)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                Text(summary(result)).font(.caption).foregroundStyle(.secondary)
            }
        case .substituted(let requested, let result):
            VStack(alignment: .leading, spacing: 2) {
                Text("Not available to this account")
                Text("The CLI answered \(requested) with \(result.resolvedID) instead.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .unavailable(let reason):
            Text(reason).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func summary(_ result: ModelProbeResult) -> String {
        var parts: [String] = []
        if let window = result.contextWindow { parts.append("\(window.formatted(.number.notation(.compactName))) context") }
        if let out = result.maxOutputTokens { parts.append("\(out.formatted(.number.notation(.compactName))) max output") }
        parts.append(String(format: "%.1fs", result.latency))
        return parts.joined(separator: " · ")
    }
}
