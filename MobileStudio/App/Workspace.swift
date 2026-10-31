import AppKit
import Observation

/// The main window's state: one model per panel, and the rules that keep them consistent with each other.
/// Views read the models and call the actions here; no view coordinates two models itself. The toolbar,
/// the menu bar commands and the banners all go through the same actions, so they can't disagree.
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

    // MARK: Window

    /// The chat inspector on the right.
    var isChatVisible = UserDefaults.standard.object(forKey: Keys.chatVisible) as? Bool ?? true {
        didSet { UserDefaults.standard.set(isChatVisible, forKey: Keys.chatVisible) }
    }
    /// The build log drawer under the simulator.
    var isLogVisible = false
    /// The changed file whose diff is shown in a sheet.
    var diffFile: FileSnapshot.Change?
    /// The failure the user closed the banner of. A newer failure brings the banner back.
    private(set) var dismissedFailureDate: Date?

    /// False for snapshot runs (see `AppDelegate`), so screenshots don't spend money on a project check.
    @ObservationIgnored var runsAutomaticChecks = true

    @ObservationIgnored private var activeObserver: NSObjectProtocol?
    /// Run was pressed while the simulator was off: run once it has booted.
    private var runAfterBoot = false
    /// The chat message showing the Fix with Claude run in progress.
    @ObservationIgnored private var fixMessageID: UUID?

    private enum Keys {
        static let chatVisible = "window.chatVisible.v1"
    }

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
        if runsAutomaticChecks { project.autoVerify(studio.projectVerifier) }
        refreshExistingApp()
    }

    // MARK: Derived

    var flutterProject: FlutterProject? {
        if case .ready(let flutter) = project.state { return flutter }
        return nil
    }

    /// Why Run can't start, nil when it can. Claude's project check doesn't block it.
    var runBlocker: String? {
        guard let flutter = flutterProject else { return "Choose a Flutter project first." }
        if !flutter.platforms.contains("ios") { return "This project has no ios folder, so it can't run in the iOS Simulator." }
        guard simulator.selected != nil else {
            return simulator.devices.isEmpty ? "No iOS Simulators are installed." : "Choose a simulator."
        }
        if fix.isBusy { return "Claude is fixing the project." }
        return nil
    }

    var canRun: Bool { !run.phase.isActive && run.existing == nil && runBlocker == nil && !runAfterBoot }
    var canStop: Bool { run.phase.isActive && fix.phase != .validating }
    var canHotReload: Bool { run.phase == .running }
    var canPick: Bool { pick.isPicking || (run.phase == .running && run.vmServiceURL != nil) }

    /// The last failure, while it belongs to this folder and nothing is running or being fixed.
    var visibleFailure: RunFailure? {
        guard let failure = run.failure, failure.folder == project.path, !run.phase.isActive, !fix.isBusy else { return nil }
        return failure
    }

    /// Why Fix with Claude can't start, nil when it can.
    var fixBlocker: String? {
        if studio.claude == nil { return "Install the claude CLI and sign in to fix this with Claude." }
        if chat.isSending { return "Wait for Claude to finish answering in the chat." }
        return nil
    }

    /// Why a chat message can't be sent, nil when it can.
    var chatBlocker: String? {
        if project.readyFolder == nil { return "Choose a Flutter project to start a chat." }
        if studio.claude == nil { return "Install the claude CLI and sign in to chat." }
        if fix.isBusy { return "Claude is fixing the project. You can chat again when it's done." }
        return nil
    }

    /// One line for the toolbar's activity area, like Xcode's.
    var activity: Activity {
        let device = run.deviceName ?? simulator.selected?.name ?? "the simulator"
        if fix.phase == .fixing { return Activity(tone: .neutral, text: "Claude is fixing the project…", busy: true) }
        if fix.phase == .validating { return Activity(tone: .neutral, text: "Checking the fix on \(device)…", busy: true) }
        switch run.phase {
        case .starting:
            return Activity(tone: .neutral, text: run.isAttaching ? "Connecting to the app…" : "Building for \(device)…", busy: true)
        case .running:
            return Activity(tone: .success, text: "Running \(flutterProject?.name ?? "the app") on \(device)", busy: false)
        case .idle, .failed:
            break
        }
        if runAfterBoot || simulator.phase == .booting { return Activity(tone: .neutral, text: "Booting \(device)…", busy: true) }
        if visibleFailure != nil { return Activity(tone: .failure, text: "Run failed", busy: false) }
        if run.existing != nil { return Activity(tone: .neutral, text: "Already running on \(device)", busy: false) }
        if let blocker = runBlocker { return Activity(tone: .neutral, text: blocker, busy: false) }
        return Activity(tone: .neutral, text: "Ready to run on \(device)", busy: false)
    }

    /// What the menu bar shows. `ContentView` mirrors it into `MenuBridge` for `StudioCommands`: menus don't
    /// follow `@Observable` state on their own, so they would keep their first enabled state and titles.
    var menuState: MenuState {
        MenuState(canRun: canRun, canStop: canStop, canHotReload: canHotReload, canPick: canPick,
                  isPicking: pick.isPicking, isChatVisible: isChatVisible, isLogVisible: isLogVisible,
                  canStartNewChat: !chat.messages.isEmpty && !chat.isSending,
                  canFix: visibleFailure != nil && fixBlocker == nil,
                  canCheckProject: project.path != nil && studio.projectVerifier != nil)
    }

    struct MenuState: Equatable {
        var canRun, canStop, canHotReload, canPick, isPicking, isChatVisible, isLogVisible: Bool
        var canStartNewChat, canFix, canCheckProject: Bool
    }

    struct Activity: Equatable {
        let tone: StatusTone
        let text: String
        let busy: Bool
    }

    // MARK: Actions

    func chooseProject() {
        if project.choose(), runsAutomaticChecks { project.autoVerify(studio.projectVerifier) }
    }

    func checkProject() {
        if let verifier = studio.projectVerifier { project.verify(with: verifier) }
    }

    /// Runs the app on the selected simulator, booting it first when it is off.
    func runApp() {
        guard canRun, let flutter = flutterProject, let device = simulator.selected else { return }
        guard device.isBooted else {
            runAfterBoot = true
            simulator.boot()
            return
        }
        run.start(folder: flutter.path, deviceID: device.udid, deviceName: device.name, flavor: project.runFlavor)
    }

    func stopApp() {
        runAfterBoot = false
        if canStop { run.stop() }
    }

    func hotReload() { run.hotReload() }

    func togglePick() {
        guard canPick else { return }
        pick.toggle(run: run, folder: project.readyFolder)
        if pick.isPicking { isChatVisible = true }
    }

    func reconnect() {
        guard let folder = project.readyFolder else { return }
        run.reconnect(folder: folder, deviceName: simulator.selected?.name ?? "the simulator")
    }

    func stopExistingApp() { run.stopExisting() }

    func dismissFailure() { dismissedFailureDate = visibleFailure?.date }

    var isFailureDismissed: Bool { visibleFailure != nil && visibleFailure?.date == dismissedFailureDate }

    /// Hands the failed run to Claude. Progress and the report appear in the chat.
    func fixFailure() {
        guard let failure = visibleFailure, fixBlocker == nil, let claude = studio.claude else { return }
        isChatVisible = true
        fixMessageID = chat.beginFix(failure)
        fix.fix(failure, using: claude, run: run)
    }

    func cancelFix() { fix.cancel() }

    func showDiff(of change: FileSnapshot.Change) { diffFile = change }

    // MARK: Events

    /// The folder was changed or removed: anything running belongs to the old one.
    func projectPathChanged() {
        runAfterBoot = false
        fix.cancel()
        run.stop()
        pick.cancel()
        pick.clear()
        diffFile = nil
        chat.load(folder: project.readyFolder)
    }

    /// The folder became, or stopped being, a usable Flutter project.
    func projectStateChanged() {
        chat.load(folder: project.readyFolder)
        refreshExistingApp()
    }

    func deviceChanged() {
        if runAfterBoot {
            if simulator.selected?.isBooted == true {
                runAfterBoot = false
                runApp()
            } else if case .failed = simulator.phase {
                runAfterBoot = false
            }
        }
        refreshExistingApp()
    }

    func simulatorPhaseChanged() {
        if case .failed = simulator.phase { runAfterBoot = false }
    }

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

    func fixActivityChanged() {
        guard let id = fixMessageID else { return }
        var activity = fix.activity
        if fix.phase == .validating { activity.append("Running the app again to check the fix…") }
        chat.updateFix(id, activity: activity)
    }

    /// The fix ended (done, failed or cancelled): its report goes into the chat, and the fix model is reset.
    func fixPhaseChanged() {
        fixActivityChanged()
        guard let id = fixMessageID, !fix.isBusy else { return }
        fixMessageID = nil
        chat.finishFix(id, with: fix.phase)
        fix.dismiss()
    }

    /// The folder may have been chosen before the CLI and account were ready.
    func claudeAvailabilityChanged(_ ready: Bool) {
        if ready, runsAutomaticChecks { project.autoVerify(studio.projectVerifier) }
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
