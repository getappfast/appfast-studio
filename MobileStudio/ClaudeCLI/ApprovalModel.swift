import Foundation
import Observation

/// Asks the user when Claude wants something its allow-list doesn't cover, one question at a time, and
/// remembers the commands they said "Always allow" to. The chat shows `current`; the Claude run waits for the answer.
@MainActor
@Observable
final class ApprovalModel {
    struct Pending: Identifiable, Equatable {
        let id = UUID()
        let request: AgentPermissionRequest
        let folder: String

        /// "Always allow" is only offered for a plain command, because what is remembered is that exact text.
        var canAlwaysAllow: Bool {
            if case .command(let command) = request.action { return AgentPermissionPolicy.canRemember(command) }
            return false
        }
    }

    enum Answer { case allowOnce, allowAlways, decline }

    /// Waiting for the user, oldest first. A parallel tool call can ask while another question is open.
    private(set) var queue: [Pending] = []
    /// The commands remembered for each folder, mirrored from the store so the list on screen updates.
    private(set) var remembered: [String: [String]] = [:]

    @ObservationIgnored private let store: ApprovedCommandStore
    @ObservationIgnored private var waiting: [UUID: CheckedContinuation<AgentPermissionRequest.Decision, Never>] = [:]

    static let declinedMessage = "The user said no to this. Don't try another way around it: say what you couldn't do and why."

    init(store: ApprovedCommandStore = ApprovedCommandStore()) {
        self.store = store
    }

    var current: Pending? { queue.first }

    func approvedCommands(in folder: String) -> [String] {
        remembered[folder] ?? store.commands(in: folder)
    }

    /// Whether answering this request needs the user, so the window can come forward.
    func needsUser(_ request: AgentPermissionRequest, folder: String) -> Bool {
        verdict(for: request, folder: folder) == .ask
    }

    /// The answer to a request: at once when the app's rules decide, otherwise after the user has clicked.
    func decide(_ request: AgentPermissionRequest, folder: String) async -> AgentPermissionRequest.Decision {
        switch verdict(for: request, folder: folder) {
        case .allow: return .allow
        case .refuse(let reason): return .deny(reason)
        case .ask: break
        }
        let pending = Pending(request: request, folder: folder)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.append(pending)
                waiting[pending.id] = continuation
            }
        } onCancel: {
            // The run was stopped or ended, so there is nobody left to ask for.
            Task { @MainActor in self.resolve(pending.id, .deny("Stopped.")) }
        }
    }

    func answer(_ answer: Answer) {
        guard let pending = current else { return }
        switch answer {
        case .allowOnce:
            resolve(pending.id, .allow)
        case .allowAlways:
            if case .command(let command) = pending.request.action, pending.canAlwaysAllow { remember(command, in: pending.folder) }
            resolve(pending.id, .allow)
            // The same command may be waiting behind this one.
            for other in queue where verdict(for: other.request, folder: other.folder) == .allow { resolve(other.id, .allow) }
        case .decline:
            resolve(pending.id, .deny(Self.declinedMessage))
        }
    }

    func forget(_ command: String, in folder: String) {
        store.remove(command, in: folder)
        remembered[folder] = store.commands(in: folder)
    }

    private func remember(_ command: String, in folder: String) {
        store.add(command, in: folder)
        remembered[folder] = store.commands(in: folder)
    }

    private func verdict(for request: AgentPermissionRequest, folder: String) -> AgentPermissionPolicy.Verdict {
        AgentPermissionPolicy.verdict(for: request, approvedCommands: Set(approvedCommands(in: folder)))
    }

    private func resolve(_ id: UUID, _ decision: AgentPermissionRequest.Decision) {
        queue.removeAll { $0.id == id }
        waiting.removeValue(forKey: id)?.resume(returning: decision)
    }
}
