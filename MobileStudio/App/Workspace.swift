import AppKit
import Observation

/// The main window's state: one model per panel, and the rules that keep them consistent with each other.
/// Views read the models and forward events here; no view coordinates two models itself.
@MainActor
@Observable
final class Workspace {
    let studio: StudioModel
    let simulator = SimulatorModel()
    let project = ProjectModel()
    let run = FlutterRunModel()
    let fix = FixModel()
    let chat = ChatModel()
    let pick = PickModel()

    @ObservationIgnored private var activeObserver: NSObjectProtocol?

    init(studio: StudioModel) {
        self.studio = studio
        // An app left running by an earlier run can be picked up again, so look whenever the user comes back.
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshExistingApp() }
        }
    }

    /// First appearance: find the CLI and accounts, then check the saved project.
    func start() async {
        chat.load(folder: project.readyFolder)
        await studio.refresh()
        project.autoVerify(studio.projectVerifier)
        refreshExistingApp()
    }

    // MARK: Events

    func chooseProject() {
        if project.choose() { project.autoVerify(studio.projectVerifier) }
    }

    /// The folder was changed or removed: anything running belongs to the old one.
    func projectPathChanged() {
        fix.cancel()
        run.stop()
        pick.cancel()
        pick.clear()
        chat.load(folder: project.readyFolder)
    }

    /// The folder became, or stopped being, a usable Flutter project.
    func projectStateChanged() {
        chat.load(folder: project.readyFolder)
        refreshExistingApp()
    }

    func deviceChanged() { refreshExistingApp() }

    func runPhaseChanged() {
        // Select mode only exists while the app runs.
        if run.phase != .running { pick.cancel() }
        guard !run.phase.isActive else { return }
        // The flutter tool takes a moment to let go of the app after it exits.
        Task {
            try? await Task.sleep(for: .seconds(2))
            refreshExistingApp()
        }
    }

    /// The folder may have been chosen before the CLI and account were ready.
    func claudeAvailabilityChanged(_ ready: Bool) {
        if ready { project.autoVerify(studio.projectVerifier) }
    }

    // MARK: Rules

    /// Looks for the project's app already running on the selected simulator, so it can be reconnected to.
    private func refreshExistingApp() {
        guard let folder = project.readyFolder, let device = simulator.selected, device.isBooted else {
            run.forgetExisting()
            return
        }
        run.refreshExisting(folder: folder, deviceID: device.udid)
    }
}
