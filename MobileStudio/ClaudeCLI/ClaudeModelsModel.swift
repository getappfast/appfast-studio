import Foundation
import Observation

@MainActor
@Observable
final class ClaudeModelsModel {
    private(set) var targets: [ModelProbeTarget] = ModelProbeTarget.aliases
    private(set) var states: [ModelProbeTarget: ModelProbeState] = [:]
    private(set) var isChecking = false

    func state(for target: ModelProbeTarget) -> ModelProbeState {
        states[target] ?? .idle
    }

    /// Probes every listed model in parallel; rows update as each one finishes.
    func checkAll(cliPath: String, profile: Profile) async {
        await check(targets, cliPath: cliPath, profile: profile)
    }

    /// Checks one extra model by alias or full ID and adds it to the list.
    func checkCustom(_ name: String, cliPath: String, profile: Profile) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let target = ModelProbeTarget(name: trimmed)
        if !targets.contains(target) { targets.append(target) }
        await check([target], cliPath: cliPath, profile: profile)
    }

    private func check(_ batch: [ModelProbeTarget], cliPath: String, profile: Profile) async {
        isChecking = true
        defer { isChecking = false }
        for target in batch { states[target] = .checking }

        let service = ClaudeModelService(cliPath: cliPath, environment: profile.environment)
        await withTaskGroup(of: (ModelProbeTarget, ModelProbeState).self) { group in
            for target in batch {
                group.addTask { (target, await service.probe(target)) }
            }
            for await (target, result) in group {
                states[target] = result
            }
        }
    }

    /// Forget results; models can differ per account, so switching accounts clears them.
    func reset() {
        states = [:]
    }
}
