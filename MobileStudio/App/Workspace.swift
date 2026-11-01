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
    let dart = DartSDKModel()
    let creator = NewProjectModel()

    // MARK: Window

    /// The chat inspector on the right.
    var isChatVisible = UserDefaults.standard.object(forKey: Keys.chatVisible) as? Bool ?? true {
        didSet { UserDefaults.standard.set(isChatVisible, forKey: Keys.chatVisible) }
    }
    /// What the canvas shows: the running device, or the map of the app's screens.
    var canvas = UserDefaults.standard.string(forKey: Keys.canvas).flatMap(Canvas.init) ?? .device {
        didSet { UserDefaults.standard.set(canvas.rawValue, forKey: Keys.canvas) }
    }
    /// The build log drawer under the simulator.
    var isLogVisible = false
    /// The New Project sheet.
    var isNewProjectSheetVisible = false
    /// The changed file whose diff is shown in a sheet.
    var diffFile: FileSnapshot.Change?
    /// The failure the user closed the banner of. A newer failure brings the banner back.
    private(set) var dismissedFailureDate: Date?
    /// A short confirmation over the device ("Updated", "Undone"), cleared after a few seconds.
    private(set) var toast: Toast?
    /// What's typed in the chat box. Here rather than in the view so the Screens list can start a message.
    var chatDraft = ""
    /// Bumped to put the cursor in the chat box.
    private(set) var composerFocusRequest = 0
    /// What was asked for in the New Project sheet, for a project made there. Drives the planning card.
    private(set) var newProjectRecord: NewProjectRecord?
    /// The written product plan, kept apart from the chat so the milestone tracker outlives a new chat.
    private(set) var plan: ProductPlan?
    /// The app's screens and how they lead to each other, found in its source; refreshed when Claude changes files.
    private(set) var flow: AppFlow?

    /// False for snapshot runs (see `AppDelegate`), so screenshots don't spend money on a project check.
    @ObservationIgnored var runsAutomaticChecks = true

    @ObservationIgnored private var activeObserver: NSObjectProtocol?
    /// Run was pressed while the simulator was off: run once it has booted.
    private var runAfterBoot = false
    /// The chat message showing the Fix with Claude run in progress.
    @ObservationIgnored private var fixMessageID: UUID?
    /// Run Again was pressed while the app ran: run once it has stopped.
    @ObservationIgnored private var runAfterStop = false
    /// A project was just created: run it once it is the open project.
    @ObservationIgnored private var runAfterOpen: String?
    /// The folder `projectPathChanged` last cleaned up after, so a pending run never starts before the old one is stopped.
    @ObservationIgnored private var handledPath: String?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    private enum Keys {
        static let chatVisible = "window.chatVisible.v1"
        static let canvas = "window.canvas.v1"
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
        loadRecord()
        refreshFlow()
        async let sdk: Void = dart.refresh()
        await studio.refresh()
        await sdk
        if runsAutomaticChecks { project.autoVerify(studio.projectVerifier) }
        refreshExistingApp()
    }

    // MARK: Derived

    /// The current project's screens, empty until they've been read.
    var screens: [AppScreen] {
        guard let flow, flow.folder == project.readyFolder else { return [] }
        return flow.screens
    }

    /// The flow with the latest plan's unbuilt screens added as dashed cards.
    var flowWithPlan: AppFlow? {
        guard let flow else { return nil }
        guard let plan = chat.messages.last(where: { $0.plan != nil && $0.undone != true })?.plan else { return flow }
        return flow.adding(plan)
    }

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

    /// Why a new project can't be started, nil when it can. Claude isn't needed until the planning chat.
    var createProjectBlocker: String? {
        switch dart.state {
        case .checking: "Looking for Flutter…"
        case .notInstalled, .failed: "Install Flutter first, then try again."
        case .installed: nil
        }
    }

    var canCreateProject: Bool { createProjectBlocker == nil && !creator.isWorking }

    /// The kickoff card is showing: a new project whose planning chat was neither started nor skipped.
    var isKickoffOffered: Bool { newProjectRecord?.kickoff == .offered && chat.mode == .build && chat.messages.isEmpty }

    /// "Plan this app" is offered in the empty chat after Skip, and for a project that has no plan yet.
    var canOfferPlanning: Bool { newProjectRecord != nil && newProjectRecord?.kickoff != .planned && chat.messages.isEmpty }

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
                  isShowingFlow: canvas == .flow,
                  canStartNewChat: !chat.messages.isEmpty && !chat.isSending,
                  canFix: visibleFailure != nil && fixBlocker == nil,
                  canCheckProject: project.path != nil && studio.projectVerifier != nil,
                  canCreateProject: canCreateProject && !isNewProjectSheetVisible)
    }

    struct MenuState: Equatable {
        var canRun, canStop, canHotReload, canPick, isPicking, isChatVisible, isLogVisible, isShowingFlow: Bool
        var canStartNewChat, canFix, canCheckProject, canCreateProject: Bool
    }

    /// Everything wrong with the project that the user may need to act on, worst first.
    var issues: [ProjectIssue] {
        guard let flutter = flutterProject else { return [] }
        var issues: [ProjectIssue] = []
        if let failure = visibleFailure { issues.append(.init(tone: .failure, title: "Run failed", detail: failure.message)) }
        if !flutter.platforms.contains("ios") {
            issues.append(.init(tone: .warning, title: "No ios folder", detail: "It can't run in the iOS Simulator."))
        }
        if let record = newProjectRecord, record.changed != true, let note = record.gitNote {
            issues.append(.init(tone: .warning, title: "The first version wasn't saved", detail: note))
        }
        if !flutter.hasMainDart { issues.append(.init(tone: .warning, title: "lib/main.dart is missing", detail: nil)) }
        if case .done(let verdict) = project.verification {
            issues += verdict.problems.map { .init(tone: .warning, title: $0, detail: nil) }
        }
        if case .failed(let message) = project.verification {
            issues.append(.init(tone: .warning, title: "Claude couldn't check the project", detail: message))
        }
        if let note = project.refreshNote { issues.append(.init(tone: .warning, title: note, detail: nil)) }
        return issues
    }

    struct ProjectIssue: Equatable, Hashable {
        let tone: StatusTone
        let title: String
        let detail: String?
    }

    enum Canvas: String {
        case device, flow
    }

    struct Toast: Equatable {
        enum Action: Equatable { case runAgain }
        let id = UUID()
        let tone: StatusTone
        let text: String
        var action: Action?
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

    /// Opens the New Project sheet, starting from a clean slate unless a create is still running.
    func newProject() {
        guard canCreateProject || creator.isWorking else { return }
        // A create that stopped partway is resumed, not started over: its folder is still there.
        if !creator.isWorking, !creator.isResumable { creator.reset() }
        isNewProjectSheetVisible = true
    }

    func closeNewProjectSheet() {
        if creator.isWorking { creator.cancel() }
        isNewProjectSheetVisible = false
    }

    /// The created folder becomes the open project, and runs as soon as the simulator allows.
    func finishNewProject(path: String) {
        if let request = creator.request {
            var record = NewProjectRecord(request: request)
            record.gitNote = creator.committed == false ? creator.note : nil
            record.save(forFolder: path)
            if creator.note != nil { show(Toast(tone: .warning, text: "Your first version wasn't saved in git. The project's issues say how to fix it.")) }
        }
        UserDefaults.standard.set(creator.request?.parentFolder, forKey: NewProjectDefaults.lastParentKey)
        runAfterOpen = path
        isNewProjectSheetVisible = false
        project.open(path: path)
        if runsAutomaticChecks { project.autoVerify(studio.projectVerifier) }
        creator.reset()
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
        // Pointing happens on the device, so it has to be in view.
        if pick.isPicking {
            isChatVisible = true
            canvas = .device
        }
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

    /// Starts a chat message about a screen, for people who'd rather name it than point at it.
    func mention(_ screen: AppScreen) {
        chatDraft = screen.isPlanned
            ? "Build the \(screen.name) screen from PLAN.md (\(screen.purpose ?? ""))."
            : "On the \(screen.name) screen, "
        isChatVisible = true
        composerFocusRequest += 1
    }

    /// Stops the app and runs it again, for changes hot reload can't apply (packages, iOS settings).
    func runAgain() {
        toast = nil
        guard run.phase.isActive else { runApp(); return }
        runAfterStop = true
        stopApp()
    }

    /// Undoes an answer's edits, and every newer answer's first, so files go back in order.
    func undo(_ message: ChatMessage) {
        guard let folder = project.readyFolder, !chat.isSending, !fix.isBusy else { return }
        let newestFirst = chat.undoable
        guard let target = newestFirst.firstIndex(where: { $0.id == message.id }) else { return }
        var restored: [FileSnapshot.Change] = []
        for answer in newestFirst[...target] {
            guard let id = answer.checkpointID else { continue }
            do {
                restored += try CheckpointStore.restore(id: id, folder: folder)
                chat.markUndone(answer.id)
                // With the plan undone, planning can be offered again.
                if answer.plan != nil, let record = newProjectRecord {
                    ProductPlanStore.delete(forFolder: folder)
                    plan = nil
                    update(record) { $0.kickoff = .started; $0.doneMilestones = nil }
                }
                if let index = answer.milestone { setMilestone(index, done: false) }
            } catch {
                show(Toast(tone: .warning, text: error.localizedDescription))
                return
            }
        }
        applyEdits(restored, done: "Undone")
    }

    func dismissToast() { toast = nil }

    /// Sends a chat message with whatever is picked in the app, as the composer and the choice cards do.
    func sendChat(_ text: String, turn: ChatModel.Turn = .normal, milestone: Int? = nil) {
        guard chatBlocker == nil, !chat.isSending, let folder = project.readyFolder, let claude = studio.claude,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        pick.cancel()
        chat.send(text, references: pick.picks, turn: turn, milestone: milestone, folder: folder, claude: claude, profile: studio.profiles.active)
        pick.clear()
    }

    /// The user picked from the options at the end of an answer: remember it and send it as the next message.
    func choose(_ labels: [String], in message: ChatMessage) {
        guard !labels.isEmpty, chatBlocker == nil, !chat.isSending else { return }
        chat.recordChoice(labels, for: message.id)
        if chat.mode == .kickoff, let step = kickoffStep(for: labels) {
            step()
            return
        }
        sendChat(ChoiceSet.reply(choosing: labels))
    }

    /// The user answered every question of an answer: one question is a plain pick, several go back together.
    func choose(answers: [(question: String?, labels: [String])], in message: ChatMessage) {
        let labels = answers.flatMap(\.labels)
        if answers.count == 1 { choose(labels, in: message); return }
        guard !labels.isEmpty, chatBlocker == nil, !chat.isSending else { return }
        chat.recordChoice(labels, for: message.id)
        sendChat(ChoiceSet.reply(answering: answers))
    }

    /// The planning chat's own buttons do more than send their label.
    private func kickoffStep(for labels: [String]) -> (() -> Void)? {
        // Claude may phrase a label a little differently ("Write the plan now"), so match on how it starts.
        func picked(_ label: String) -> Bool {
            labels.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix(label.lowercased()) }
        }
        if picked(ProductPlan.writeLabel) { return { [self] in writePlan() } }
        if picked(ProductPlan.buildLabel) {
            return { [self] in buildMilestone(0) }
        }
        // Nothing to send: the plan stays and the chat waits.
        if picked(ProductPlan.notNowLabel) { return {} }
        return nil
    }

    // MARK: Planning a new app

    /// Starts the planning chat: Claude asks a few questions, then writes PLAN.md.
    func startKickoff() {
        guard let record = newProjectRecord, chatBlocker == nil, !chat.isSending else { return }
        update(record) { $0.kickoff = .started }
        isChatVisible = true
        chat.beginKickoff(context: Self.kickoffContext(for: record.request))
        sendChat("Let's plan \(record.request.displayName). " + (record.request.description.nonEmpty ?? "I haven't described it yet."))
    }

    /// The planning chat has run long enough to write the plan, whatever Claude's last question offered.
    var canWritePlan: Bool { chat.mode == .kickoff && chat.messages.count >= 2 && !chat.isSending && chatBlocker == nil }

    /// Asks for the plan: one Opus turn, then PLAN.md.
    func writePlan() {
        sendChat(ChoiceSet.reply(choosing: [ProductPlan.writeLabel]), turn: .plan)
    }

    // MARK: Milestones

    /// The plan the tracker follows, with what is built so far.
    var milestoneProgress: MilestoneProgress? {
        plan.map { MilestoneProgress(plan: $0, done: Set(newProjectRecord?.doneMilestones ?? [])) }
    }

    var buildMilestoneBlocker: String? { chatBlocker }

    /// Asks Claude to build one milestone of the plan, in build mode. It counts as built when the answer changes files.
    func buildMilestone(_ index: Int) {
        guard let plan, plan.milestones.indices.contains(index), buildMilestoneBlocker == nil, !chat.isSending else { return }
        isChatVisible = true
        chat.switchToBuild()
        sendChat("Build milestone \(index + 1) from \(ProductPlan.fileName): \(plan.milestones[index].title).", milestone: index)
    }

    /// For milestones built by hand or outside the app, or to build one again.
    func setMilestone(_ index: Int, done: Bool) {
        guard let record = newProjectRecord else { return }
        update(record) { record in
            var set = Set(record.doneMilestones ?? [])
            if done { set.insert(index) } else { set.remove(index) }
            record.doneMilestones = set.sorted()
        }
    }

    func skipKickoff() {
        guard let record = newProjectRecord else { return }
        update(record) { $0.kickoff = .skipped }
    }

    private static func kickoffContext(for request: NewProjectRequest) -> String {
        var lines = ["Name: \(request.displayName)"]
        if let description = request.description.nonEmpty { lines.append("Description: \(description)") }
        lines.append("Platforms: " + ProjectPlatform.allCases.filter { request.platforms.contains($0) }.map(\.title).joined(separator: ", "))
        return lines.joined(separator: "\n")
    }

    private func update(_ record: NewProjectRecord, _ change: (inout NewProjectRecord) -> Void) {
        guard let folder = project.readyFolder else { return }
        var record = record
        change(&record)
        record.save(forFolder: folder)
        newProjectRecord = record
    }

    private func loadRecord() {
        newProjectRecord = project.readyFolder.flatMap(NewProjectRecord.load(forFolder:))
        plan = project.readyFolder.flatMap(ProductPlanStore.load(forFolder:))
            ?? chat.messages.last(where: { $0.plan != nil && $0.undone != true })?.plan
    }

    /// Starts typing a different answer to an answer's options.
    func answerInOwnWords() {
        isChatVisible = true
        composerFocusRequest += 1
    }

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
        handledPath = project.path
        startPendingRun()
    }

    /// The folder became, or stopped being, a usable Flutter project.
    func projectStateChanged() {
        chat.load(folder: project.readyFolder)
        loadRecord()
        refreshExistingApp()
        refreshFlow()
        startPendingRun()
    }

    /// Runs the project that was just created, once the previous folder's run has stopped. Called from every
    /// event that can be the last to arrive, because their order isn't guaranteed.
    private func startPendingRun() {
        guard let path = runAfterOpen, path == project.readyFolder, handledPath == path, !run.phase.isActive else { return }
        runAfterOpen = nil
        runApp()
    }

    /// The create pipeline finished: open the project it made.
    func creatorPhaseChanged() {
        if case .done(let path) = creator.phase { finishNewProject(path: path) }
    }

    /// A chat answer finished: show its edits in the running app.
    func chatSendingChanged() {
        guard !chat.isSending, let reply = chat.messages.last, reply.role == .assistant else { return }
        if let written = reply.plan, let record = newProjectRecord, let folder = project.readyFolder {
            ProductPlanStore.save(written, forFolder: folder)
            plan = written
            update(record) { $0.kickoff = .planned; $0.doneMilestones = [] }
        }
        if let index = reply.milestone, reply.error == nil, reply.files.contains(where: { $0.path != ProductPlan.fileName }) {
            setMilestone(index, done: true)
            let next = milestoneProgress?.next.flatMap { plan?.milestones.indices.contains($0) == true ? plan?.milestones[$0].title : nil }
            show(Toast(tone: .success, text: next.map { "Milestone \(index + 1) built. Next: \($0)" } ?? "Every milestone is built"))
        }
        if reply.files.contains(where: { $0.path != ProductPlan.fileName }), let record = newProjectRecord, record.changed != true {
            update(record) { $0.changed = true }
        }
        applyEdits(reply.files, done: "Updated")
    }

    /// A pick came in: give it a picture of where the user tapped.
    func picksChanged() {
        guard let newest = pick.picks.last, newest.thumbnail == nil,
              let tap = simulator.lastTap, Date().timeIntervalSince(tap.date) < 20 else { return }
        pick.setThumbnail(tap.image, for: newest.id)
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
        startPendingRun()
        if runAfterStop {
            runAfterStop = false
            runApp()
            return
        }
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

    /// Makes changed files show in the running app: hot reload for code, a hot restart when start-up code changed,
    /// and an offer to run again for packages and native settings, which only a new build picks up.
    private func applyEdits(_ files: [FileSnapshot.Change], done: String) {
        guard !files.isEmpty else { return }
        // PLAN.md isn't part of the app, so it needs no reload.
        guard files.contains(where: { $0.path != ProductPlan.fileName }) else {
            if done == "Undone" { show(Toast(tone: .success, text: "Undone")) }
            return
        }
        if files.contains(where: { $0.path.hasPrefix("lib/") }) { refreshFlow() }
        guard run.phase == .running else {
            if done == "Undone" { show(Toast(tone: .success, text: "Undone")) }
            return
        }
        let count = files.count == 1 ? "1 file" : "\(files.count) files"
        let paths = files.map(\.path)
        if paths.contains(where: { $0.hasPrefix("pubspec") || $0.hasPrefix("ios/") || $0.hasPrefix("android/") }) {
            show(Toast(tone: .warning, text: "\(done) \(count). Run again to apply package or iOS changes.", action: .runAgain))
        } else if paths.contains("lib/main.dart") {
            run.hotRestart()
            show(Toast(tone: .success, text: "\(done) · restarted the app"))
        } else {
            run.hotReload()
            show(Toast(tone: .success, text: "\(done) · \(count)"))
        }
    }

    private func show(_ toast: Toast) {
        self.toast = toast
        toastTask?.cancel()
        // One that asks for something stays until it's used or dismissed.
        guard toast.action == nil else { return }
        toastTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled, self.toast?.id == toast.id { self.toast = nil }
        }
    }

    private func refreshFlow() {
        guard let folder = project.readyFolder else { flow = nil; return }
        Task {
            let found = await FlowFinder.found(in: folder)
            if project.readyFolder == folder { flow = found }
        }
    }

    /// Looks for the project's app already running on the selected simulator, so it can be reconnected to.
    private func refreshExistingApp() {
        guard let folder = project.readyFolder, let device = simulator.selected, device.isBooted else {
            run.forgetExisting()
            return
        }
        run.refreshExisting(folder: folder, deviceID: device.udid)
    }
}
