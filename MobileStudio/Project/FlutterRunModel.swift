import AppKit
import Observation

enum RunPhase: Equatable {
    case idle
    case starting
    case running
    case failed(String)

    var isActive: Bool { self == .starting || self == .running }
    var isFailed: Bool { if case .failed = self { true } else { false } }
}

@MainActor
@Observable
final class FlutterRunModel {
    private(set) var phase: RunPhase = .idle
    /// What Flutter printed for the current run.
    private(set) var output = FlutterOutput()
    /// Device name shown while a run is active.
    private(set) var deviceName: String?
    /// The most recent failed run, kept on disk until a run succeeds.
    private(set) var failure: RunFailure?
    /// The running app's VM service address, which the widget inspector is reached through.
    private(set) var vmServiceURL: URL?
    /// The project's app is already running in the simulator, started by an earlier run or a terminal.
    private(set) var existing: RunningApp?
    /// Why the last reconnect did not work, shown under the Run bar.
    private(set) var reconnectError: String?

    @ObservationIgnored private var process: FlutterRunProcess?
    @ObservationIgnored private var stopRequested = false
    @ObservationIgnored private var quitObserver: NSObjectProtocol?
    @ObservationIgnored private var lookupGeneration = 0
    /// Set while this run is attached to an app that something else started. `flutter attach` only detaches
    /// when asked to quit, so stopping also has to close the app, as it does for a run this app started.
    @ObservationIgnored private var attachedApp: RunningApp?
    @ObservationIgnored private var attachTimedOut = false

    @ObservationIgnored private var currentFolder = ""
    @ObservationIgnored private var currentDeviceID = ""
    @ObservationIgnored private var currentFlavor: RunFlavor?

    private static let failureKey = "run.failure.v1"
    static let log = DiagnosticLog(name: "flutter-run")

    init() {
        failure = UserDefaults.standard.decoded(RunFailure.self, forKey: Self.failureKey)
        // Don't leave a flutter tool running after the app quits. `AppDelegate` turns SIGTERM and friends
        // into a normal quit, so this also covers being killed.
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.process?.stop() }
        }
    }

    /// The last few lines, including the one being written.
    var tail: [String] { output.tail(8) }

    /// True while this run is attached to an app that was already running, not one this app started.
    var isAttaching: Bool { attachedApp != nil }

    func start(folder: String, deviceID: String, deviceName: String, flavor: RunFlavor? = nil) {
        guard !phase.isActive else { return }
        reconnectError = nil
        output = FlutterOutput()
        stopRequested = false
        vmServiceURL = nil
        existing = nil
        attachedApp = nil
        phase = .starting
        self.deviceName = deviceName
        currentFolder = folder
        currentDeviceID = deviceID
        currentFlavor = flavor
        Self.log.append("RUN flutter run -d \(deviceID) (\(deviceName))\(flavor.map { " --flavor \($0.name)" } ?? "") in \(folder)")

        launch(FlutterRunProcess(folder: folder, deviceID: deviceID, flavor: flavor))
    }

    /// Looks for the project's app already running on that simulator. Cheap enough to call often.
    func refreshExisting(folder: String, deviceID: String) {
        guard !phase.isActive else { return }
        lookupGeneration += 1
        let generation = lookupGeneration
        Task {
            let found = await RunningAppFinder.find(folder: folder, deviceID: deviceID)
            // A newer lookup, or a run started meanwhile, makes this answer stale.
            guard generation == lookupGeneration, !phase.isActive else { return }
            existing = found
        }
    }

    func forgetExisting() {
        lookupGeneration += 1
        existing = nil
    }

    /// Connects to the already-running app, so Hot reload and Pick work again without restarting it.
    func reconnect(folder: String, deviceName: String) {
        guard !phase.isActive, let app = existing else { return }
        output = FlutterOutput()
        stopRequested = false
        attachTimedOut = false
        reconnectError = nil
        existing = nil
        attachedApp = app
        // The address is already known, and it is what the widget inspector needs.
        vmServiceURL = app.serviceURL
        phase = .starting
        self.deviceName = deviceName
        currentFolder = folder
        currentDeviceID = app.deviceID
        currentFlavor = nil
        Self.log.append("RECONNECT flutter attach -d \(app.deviceID) --debug-url \(app.serviceURL.absoluteString) (\(app.bundleID)) in \(folder)")

        Task {
            // A suspended app cannot be attached to: bring it forward and wait for its service to answer.
            await RunningAppFinder.foreground(bundleID: app.bundleID, deviceID: app.deviceID)
            let responsive = await RunningAppFinder.waitUntilResponsive(app.serviceURL, timeout: 15)
            guard phase == .starting, !stopRequested else { return }
            guard responsive else {
                Self.log.append("RECONNECT FAILED: \(app.bundleID) did not answer on \(app.serviceURL.absoluteString)")
                attachedApp = nil
                vmServiceURL = nil
                reconnectError = "The app isn't answering. Open it in the simulator, then try Reconnect again."
                phase = .idle
                return
            }
            let tool = FlutterRunProcess(folder: folder, deviceID: app.deviceID, attachURL: app.serviceURL)
            launch(tool)
            // Attaching to a healthy app takes a few seconds. If it does not get there, don't spin forever.
            try? await Task.sleep(for: .seconds(40))
            if phase == .starting, process === tool {
                attachTimedOut = true
                tool.kill()
            }
        }
    }

    /// Brings the running app to the front, so its debug service answers. Needed before anything connects to it.
    func bringAppToFront() async {
        guard let bundleID = RunningAppFinder.bundleID(ofProjectAt: currentFolder), !currentDeviceID.isEmpty else { return }
        await RunningAppFinder.foreground(bundleID: bundleID, deviceID: currentDeviceID)
        if let url = vmServiceURL { _ = await RunningAppFinder.waitUntilResponsive(url, timeout: 10) }
    }

    /// Ends the already-running app.
    func stopExisting() {
        guard let app = existing else { return }
        existing = nil
        reconnectError = nil
        Self.log.append("STOP existing app \(app.bundleID) on \(app.deviceID)")
        Task { await RunningAppFinder.terminate(app) }
    }

    private func launch(_ process: FlutterRunProcess) {
        self.process = process
        Task { [weak self] in
            let status: Int32
            do {
                status = try await process.run { chunk in
                    Task { @MainActor in self?.receive(chunk) }
                }
            } catch {
                self?.finish(status: -1, detail: error.localizedDescription)
                return
            }
            // Let output queued behind the exit land first.
            try? await Task.sleep(for: .milliseconds(150))
            self?.finish(status: status, detail: nil)
        }
    }

    func stop() {
        // A reconnect still waiting for the app to wake up has no tool to stop yet; just cancel it.
        if process == nil, phase == .starting, attachedApp != nil {
            stopRequested = true
            attachedApp = nil
            vmServiceURL = nil
            phase = .idle
            return
        }
        guard let process, phase.isActive else { return }
        stopRequested = true
        process.stop()
        if let app = attachedApp { Task { await RunningAppFinder.terminate(app) } }
    }

    func revealLog() { Self.log.reveal() }

    func hotReload() { if phase == .running { process?.send("r") } }

    /// Restarts the app's Dart code: needed when main() or app start-up state changed. Native changes still need a new run.
    func hotRestart() { if phase == .running { process?.send("R") } }

    // MARK: Output

    private func receive(_ chunk: String) {
        output.append(chunk)
        if vmServiceURL == nil { vmServiceURL = output.serviceURL }
        if phase == .starting, output.isLaunched {
            phase = .running
            clearFailure()
        }
    }

    private func finish(status: Int32, detail: String?) {
        output.close()
        let lines = output.lines
        Self.log.append("EXIT \(status)\n" + lines.suffix(300).joined(separator: "\n"))
        process = nil
        let wasAttach = attachedApp != nil
        attachedApp = nil
        vmServiceURL = nil
        if stopRequested || status == 0 {
            phase = .idle
        } else if wasAttach {
            // Not a failed build, so nothing for "Fix with Claude" to work on.
            phase = .idle
            reconnectError = attachTimedOut
                ? "Couldn't connect to the running app. Make sure it is open in the simulator, then try Reconnect again."
                : "Couldn't reconnect: " + (detail ?? output.failureReason(status: status))
        } else {
            let message = detail ?? output.failureReason(status: status)
            phase = .failed(message)
            record(RunFailure(date: Date(), folder: currentFolder, deviceID: currentDeviceID,
                              deviceName: deviceName ?? "the simulator", flavor: currentFlavor, message: message,
                              output: Array(lines.suffix(200))))
        }
    }

    /// Keeps the failure on screen after a relaunch and gives "Fix with Claude" something to work from.
    private func record(_ failure: RunFailure) {
        self.failure = failure
        Self.log.append("RECORDED FAILURE: \(failure.message)")
        UserDefaults.standard.setEncoded(failure, forKey: Self.failureKey)
    }

    private func clearFailure() {
        failure = nil
        UserDefaults.standard.removeObject(forKey: Self.failureKey)
    }
}
