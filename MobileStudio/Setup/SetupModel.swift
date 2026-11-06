import AppKit
import Foundation
import Observation

/// Finds what's missing on the Mac and installs it, one step at a time: one item, or everything in
/// `SetupItem.allCases` order. Xcode is the one step that needs the user: the app opens its App Store page and
/// carries on by itself once Xcode has arrived, downloading Flutter in the meantime.
@MainActor
@Observable
final class SetupModel {
    enum Phase: Equatable {
        case idle
        case working(SetupItem, InstallProgress)
        /// The App Store page is open and the app checks for Xcode every few seconds. Carries the Flutter
        /// download that runs meanwhile, if there is one.
        case waitingForXcode(InstallProgress?)
        case failed(SetupItem, String)

        var isWorking: Bool {
            switch self {
            case .working, .waitingForXcode: true
            case .idle, .failed: false
            }
        }
    }

    private enum Request: Equatable {
        case item(SetupItem)
        case everything
    }

    static let appStoreXcode = URL(string: "macappstore://apps.apple.com/app/xcode/id497799835")!

    private(set) var facts: ToolchainFacts?
    private(set) var phase: Phase = .idle

    /// Told when an item was installed, so the workspace can refresh the models that depend on it.
    @ObservationIgnored var onInstalled: (@MainActor (SetupItem) async -> Void)?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var prefetch: Task<Void, Never>?
    @ObservationIgnored private var refreshing: Task<ToolchainFacts, Never>?
    @ObservationIgnored private var lastRequest: Request?

    init() {
        #if DEBUG
        if let fake = SetupFake.phase { phase = fake }
        #endif
    }

    // MARK: Derived

    func status(of item: SetupItem) -> SetupStatus {
        facts.map { SetupPlan.status(of: item, in: $0) } ?? .checking
    }

    /// Nil until the first check has finished.
    var requiredReady: Bool? { facts.map(SetupPlan.requiredReady) }

    /// Items the app can install now or once Xcode is in, so Set Up Everything has something to do.
    var pendingItems: [SetupItem] {
        SetupItem.allCases.filter {
            switch status(of: $0) {
            case .needed, .blocked: true
            case .ready, .checking: false
            }
        }
    }

    /// Roughly what Set Up Everything will download, counting what waits on Xcode too.
    var pendingDownloadBytes: Int64 {
        pendingItems.reduce(0) { total, item in
            switch status(of: item) {
            case .needed(let action): total + action.downloadBytes
            case .blocked: total + (Self.usualAction[item]?.downloadBytes ?? 0)
            default: total
            }
        }
    }

    /// What a blocked item will most likely need once Xcode is in.
    private static let usualAction: [SetupItem: SetupAction] = [
        .flutter: .installFlutter, .cocoapods: .installCocoaPods(withHomebrew: false), .simulator: .downloadSimulator,
    ]

    var asksForPassword: Bool {
        pendingItems.contains { item in
            item == .xcode || (item == .cocoapods && facts?.brewPath == nil)
        }
    }

    // MARK: Checking

    /// Looks again. Calls made while a check is running share its answer.
    func refresh() async {
        if let refreshing {
            facts = await refreshing.value
            return
        }
        let check = Task.detached { await ToolchainDetector().detect() }
        refreshing = check
        let found = await check.value
        refreshing = nil
        facts = found
        // A failure the user has since fixed some other way shouldn't keep showing.
        if case .failed(let item, _) = phase, status(of: item).isReady { phase = .idle }
    }

    // MARK: Installing

    func install(_ item: SetupItem) { start(.item(item)) }

    func installEverything() { start(.everything) }

    func retry() {
        guard let lastRequest else { return }
        start(lastRequest)
    }

    func cancel() {
        task?.cancel()
        prefetch?.cancel()
        task = nil
        prefetch = nil
        phase = .idle
    }

    func reopenAppStore() { NSWorkspace.shared.open(Self.appStoreXcode) }

    func revealLog() { SetupInstaller.log.reveal() }

    private func start(_ request: Request) {
        guard !phase.isWorking else { return }
        lastRequest = request
        let items: [SetupItem] = switch request {
        case .item(let item): [item]
        case .everything: SetupItem.allCases
        }
        task = Task { await run(items) }
    }

    private func run(_ items: [SetupItem]) async {
        for item in items {
            await refresh()
            var previous: SetupAction?
            // One item can take more than one action: the simulator download, then adding an iPhone to it.
            while case .needed(let action) = status(of: item), !Task.isCancelled {
                if action == .getXcode {
                    guard await waitForXcode() else { return }
                    continue
                }
                guard action != previous else {
                    phase = .failed(item, "\(item.title) was installed, but AppFast Studio still can't find it. Quit and reopen AppFast Studio, then try again.")
                    return
                }
                previous = action
                guard await perform(action, for: item) else { return }
            }
            if Task.isCancelled { return }
        }
        prefetch = nil
        phase = .idle
    }

    /// Runs one action; false when it failed or was stopped, with the phase saying which.
    private func perform(_ action: SetupAction, for item: SetupItem) async -> Bool {
        guard let facts else { return false }
        if action == .installFlutter, let prefetch {
            phase = .working(item, .init(text: "Finishing the Flutter download…"))
            await prefetch.value
        }
        if action.needsPassword { NSApp.activate() }   // the password dialog makes more sense with the app in front
        phase = .working(item, .init(text: "Starting…"))
        let installer = SetupInstaller { [weak self] progress in
            Task { @MainActor in self?.progressed(item, progress) }
        }
        do {
            try await installer.perform(action, facts: facts)
        } catch {
            if Task.isCancelled || error is CancellationError {
                phase = .idle
            } else {
                SetupInstaller.log.append("\(item.title) failed: \(error.localizedDescription)")
                phase = .failed(item, error.localizedDescription)
            }
            return false
        }
        await refresh()
        await onInstalled?(item)
        return !Task.isCancelled
    }

    private func progressed(_ item: SetupItem, _ progress: InstallProgress) {
        guard case .working(item, _) = phase else { return }
        phase = .working(item, progress)
    }

    /// Opens the App Store and waits for Xcode, downloading Flutter meanwhile. False when stopped.
    private func waitForXcode() async -> Bool {
        NSWorkspace.shared.open(Self.appStoreXcode)
        phase = .waitingForXcode(nil)
        if prefetch == nil, facts?.flutterPath == nil {
            let installer = SetupInstaller { [weak self] progress in
                Task { @MainActor in
                    guard let self, case .waitingForXcode = self.phase else { return }
                    self.phase = .waitingForXcode(progress)
                }
            }
            // A failed early download isn't an error: installing Flutter later simply downloads it then.
            prefetch = Task.detached {
                do { try await installer.prefetchFlutter() } catch { SetupInstaller.log.append("Early Flutter download: \(error.localizedDescription)") }
            }
        }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            if ToolchainDetector.xcodeApp(selected: facts?.developerDir) != nil {
                await refresh()
                return true
            }
        }
        return false
    }
}

#if DEBUG
/// Lets a snapshot run show the checklist on a Mac that already has everything:
/// `MOBILE_STUDIO_SETUP_FAKE=missing|xcode|almost` sets what is installed, and
/// `MOBILE_STUDIO_SETUP_FAKE_PHASE=flutter:42|wait|fail:simulator` what the installer is doing.
enum SetupFake {
    static var facts: ToolchainFacts? {
        guard let mode = ProcessInfo.processInfo.environment["MOBILE_STUDIO_SETUP_FAKE"] else { return nil }
        var facts = ToolchainFacts(freeBytes: 80_000_000_000)
        let app = "/Applications/Xcode.app"
        let phone = SimulatorRuntime(identifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5", version: "26.5",
                                     iPhones: [.init(identifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17", name: "iPhone 17")])
        switch mode {
        case "xcode":
            facts.xcodeApp = app
            facts.developerDir = "/Library/Developer/CommandLineTools"
        case "almost":
            facts = ToolchainFacts(claudePath: "/usr/local/bin/claude", claudeVersion: "2.1.301 (Claude Code)", xcodeApp: app,
                                   xcodeVersion: "Version 27.1", developerDir: app + "/Contents/Developer", xcodeLicenseAccepted: true,
                                   xcodeFirstLaunchDone: true, iosRuntimes: [phone], iosDeviceCount: 0, flutterPath: nil,
                                   flutterOnPath: false, flutterVersion: nil, podPath: nil, brewPath: "/opt/homebrew/bin/brew",
                                   freeBytes: 80_000_000_000)
        default:
            break
        }
        return facts
    }

    static var phase: SetupModel.Phase? {
        guard let value = ProcessInfo.processInfo.environment["MOBILE_STUDIO_SETUP_FAKE_PHASE"] else { return nil }
        let parts = value.split(separator: ":").map(String.init)
        if parts.first == "wait" { return .waitingForXcode(.init(text: "Downloading Flutter 3.47.9…", fraction: 0.31)) }
        if parts.first == "fail", let item = parts.last.flatMap(SetupItem.init(rawValue:)) {
            return .failed(item, SetupError.failed(step: "Downloading the iOS Simulator", detail: "The network connection was lost.").localizedDescription)
        }
        guard let item = SetupItem(rawValue: parts[0]) else { return nil }
        let percent = parts.count > 1 ? Double(parts[1]).map { $0 / 100 } : nil
        return .working(item, .init(text: "Downloading Flutter 3.47.9…", fraction: percent))
    }
}
#endif
