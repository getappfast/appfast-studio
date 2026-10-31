import AppKit
import Observation

@MainActor
@Observable
final class ProjectModel {
    private static let key = "project.path.v1"
    private static let checkKey = "project.check.v1"
    private static let flavorKey = "project.flavor.v1"

    /// The last Claude verdict, saved with the folder it belongs to.
    private struct StoredCheck: Codable {
        let path: String
        let verdict: ProjectVerdict
        let checkedAt: Date
    }

    private(set) var state: ProjectState = .none
    private(set) var verification: VerificationState = .idle
    /// When the shown verdict was produced.
    private(set) var lastChecked: Date?
    /// Claude is re-checking while the previous verdict stays on screen.
    private(set) var refreshing = false
    /// Why the last re-check failed, shown beside the older verdict that is still displayed.
    private(set) var refreshNote: String?
    /// The checked-out git branch, nil when the folder isn't in a git repository.
    private(set) var branch: String?
    /// The flavor Run uses, by name. Nil when the project has none.
    private(set) var selectedFlavorName: String?

    @ObservationIgnored private var verifyTask: Task<Void, Never>?
    /// The folder has not been verified in this run of the app yet.
    @ObservationIgnored private var needsVerify = false
    @ObservationIgnored private var activeObserver: NSObjectProtocol?

    init() {
        // The branch can change outside the app, so look again whenever the user comes back to it.
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshBranch() }
        }
        guard let path = UserDefaults.standard.string(forKey: Self.key) else { return }
        state = FlutterProjectInspector.inspect(path: path)
        needsVerify = true
        refreshBranch()
        guard case .ready = state, let stored = UserDefaults.standard.decoded(StoredCheck.self, forKey: Self.checkKey),
              stored.path == path else { return }
        // Show the saved verdict at once. Flavors are re-validated against the files now, which is free.
        let flavors = FlavorValidator.validate(stored.verdict.flavors, in: path).runnable
        verification = .done(ProjectVerdict(isFlutterProject: stored.verdict.isFlutterProject, summary: stored.verdict.summary,
                                            problems: stored.verdict.problems, flavors: flavors))
        lastChecked = stored.checkedAt
        selectedFlavorName = UserDefaults.standard.string(forKey: Self.flavorKey)
    }

    /// The flavors Claude found and the files back up. Empty until the check is done.
    var flavors: [RunFlavor] {
        if case .done(let verdict) = verification, verdict.isFlutterProject { return verdict.flavors }
        return []
    }

    /// What Run passes as `--flavor`: the chosen one, or the first when nothing was chosen yet.
    var runFlavor: RunFlavor? {
        flavors.first { $0.name == selectedFlavorName } ?? flavors.first
    }

    func selectFlavor(_ flavor: RunFlavor) {
        selectedFlavorName = flavor.name
        UserDefaults.standard.set(flavor.name, forKey: Self.flavorKey)
    }

    var path: String? {
        switch state {
        case .none: nil
        case .ready(let project): project.path
        case .invalid(let path, _): path
        }
    }

    /// The folder, only while it is a usable Flutter project.
    var readyFolder: String? {
        if case .ready(let project) = state { return project.path }
        return nil
    }

    /// Asks for a folder. A cancelled panel leaves the current choice alone.
    /// Returns true when a new folder was chosen.
    @discardableResult
    func choose() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Choose"
        panel.message = "Choose the root folder of your Flutter project (the one containing pubspec.yaml)."
        if let path { panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent() }
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        set(path: url.path)
        return true
    }

    /// Verifies the folder once per launch and after each new choice, as soon as Claude can be run.
    /// Safe to call repeatedly: it does nothing until a verification is due.
    func autoVerify(_ verifier: ProjectVerifier?) {
        guard needsVerify, let verifier, path != nil else { return }
        verify(with: verifier)
    }

    /// Has Claude Code look through the folder. A newer request replaces one still running.
    /// A verdict already on screen stays there until the new one arrives.
    func verify(with verifier: ProjectVerifier) {
        guard let path else { return }
        needsVerify = false
        verifyTask?.cancel()
        refreshNote = nil
        if case .done = verification { refreshing = true } else { verification = .running }
        verifyTask = Task {
            let outcome: Result<ProjectVerdict, Error>
            do { outcome = .success(try await verifier.verify(folder: path)) } catch { outcome = .failure(error) }
            // The user may have changed or removed the folder while Claude was working.
            guard !Task.isCancelled, self.path == path else { return }
            refreshing = false
            switch outcome {
            case .success(let verdict):
                verification = .done(verdict)
                lastChecked = Date()
                UserDefaults.standard.setEncoded(StoredCheck(path: path, verdict: verdict, checkedAt: lastChecked ?? Date()), forKey: Self.checkKey)
            case .failure(let error):
                if case .done = verification {
                    refreshNote = "Couldn't refresh: \(error.localizedDescription)"
                } else {
                    verification = .failed(error.localizedDescription)
                }
            }
        }
    }

    func recheck() {
        if let path { state = FlutterProjectInspector.inspect(path: path) }
        refreshBranch()
    }

    func refreshBranch() {
        guard let path else { branch = nil; return }
        Task {
            let found = await GitBranch.current(in: path)
            if self.path == path { branch = found }
        }
    }

    func clear() {
        resetVerification()
        needsVerify = false
        UserDefaults.standard.removeObject(forKey: Self.key)
        state = .none
        branch = nil
    }

    func revealLog() { ProjectVerifier.log.reveal() }

    func revealInFinder() {
        guard let path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func set(path: String) {
        resetVerification()
        needsVerify = true
        UserDefaults.standard.set(path, forKey: Self.key)
        state = FlutterProjectInspector.inspect(path: path)
        branch = nil
        refreshBranch()
    }

    private func resetVerification() {
        verifyTask?.cancel()
        selectedFlavorName = nil
        UserDefaults.standard.removeObject(forKey: Self.flavorKey)
        verification = .idle
        lastChecked = nil
        refreshing = false
        refreshNote = nil
        UserDefaults.standard.removeObject(forKey: Self.checkKey)
    }
}
