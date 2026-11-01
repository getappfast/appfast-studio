import Foundation
import Observation

enum CreatePhase: Equatable {
    case idle
    case working(CreateStep)
    case done(path: String)
    case failed(step: CreateStep, message: String)
}

/// Creates a project from a request, one step at a time, and can resume from the step that failed.
@MainActor @Observable
final class NewProjectModel {
    private(set) var phase: CreatePhase = .idle
    private(set) var request: NewProjectRequest?
    /// Steps that finished, for the progress checklist.
    private(set) var completed: Set<CreateStep> = []
    /// Something worth telling the user after a successful create, such as git needing a name.
    private(set) var note: String?

    let log: DiagnosticLog
    private let service: NewProjectService
    private var task: Task<Void, Never>?

    init(service: NewProjectService = NewProjectService()) {
        self.service = service
        self.log = service.log
    }

    var isWorking: Bool {
        if case .working = phase { return true }
        return false
    }

    /// The steps this request needs, for the checklist.
    var steps: [CreateStep] { request.map(CreateStep.steps(for:)) ?? [] }

    func create(_ request: NewProjectRequest) {
        guard !isWorking else { return }
        self.request = request
        completed = []
        note = nil
        run(from: .flutterCreate)
    }

    /// Resumes at the step that failed. Earlier steps are not repeated.
    func retry() {
        guard case .failed(let step, _) = phase, request != nil else { return }
        run(from: step)
    }

    /// Stops the current step. The folder stays: nothing here deletes the user's files.
    func cancel() {
        task?.cancel()
        task = nil
        if isWorking { phase = .idle }
    }

    func reset() {
        cancel()
        request = nil
        completed = []
        note = nil
        phase = .idle
    }

    private func run(from first: CreateStep) {
        guard let request else { return }
        let service = self.service
        let steps = CreateStep.steps(for: request).filter { $0 >= first }
        task?.cancel()
        task = Task { [weak self] in
            for step in steps {
                guard let self, !Task.isCancelled else { return }
                self.phase = .working(step)
                do {
                    let git = try await service.perform(step, for: request)
                    // A cancel ends the child process with a non-zero status; don't report that as a failure.
                    guard !Task.isCancelled else { return }
                    self.completed.insert(step)
                    if let git, !git.committed { self.note = git.note }
                } catch {
                    guard !Task.isCancelled else { return }
                    self.phase = .failed(step: step, message: error.localizedDescription)
                    return
                }
            }
            self?.phase = .done(path: request.path)
        }
    }
}
