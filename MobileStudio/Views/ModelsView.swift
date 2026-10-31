import SwiftUI

struct ModelsSection: View {
    let studio: StudioModel
    @State private var custom = ""

    private var models: ClaudeModelsModel { studio.models }

    var body: some View {
        Section {
            if !studio.canCheckModels {
                Text("Install the claude CLI and sign in to check which models you can use.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Checking as \(studio.profiles.active.name)")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(models.targets) { target in
                    ModelRow(target: target, state: models.state(for: target))
                }
                customField
            }
        } header: {
            SettingsHeader(title: "Models") {
                if models.isChecking { ProgressView().controlSize(.small) }
                Button("Check Models") { Task { await studio.checkModels() } }
                    .disabled(!studio.canCheckModels || models.isChecking)
            }
        } footer: {
            Text("The CLI can't list models, so each check sends one tiny prompt (about $0.01 in total).")
                .font(.caption).foregroundStyle(.secondary)
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
            indicator.imageScale(.small).frame(width: 14)
            Text(target.name).fontWeight(.semibold).frame(width: 90, alignment: .leading)
            detail
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var indicator: some View {
        switch state {
        case .idle: Image(systemName: StatusTone.neutral.symbol).foregroundStyle(.secondary).accessibilityLabel("Not checked")
        case .checking: ProgressView().controlSize(.mini)
        case .available: Image(systemName: StatusTone.success.symbol).foregroundStyle(.green).accessibilityLabel("Available")
        case .substituted: Image(systemName: StatusTone.warning.symbol).foregroundStyle(.orange).accessibilityLabel("Substituted")
        case .unavailable: Image(systemName: StatusTone.failure.symbol).foregroundStyle(.red).accessibilityLabel("Unavailable")
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
