import Darwin
import Foundation

/// The emulators this app started, remembered by AVD name so the next launch can still offer to shut them down on quit.
/// Emulators started anywhere else (Android Studio, a terminal) are never in here and are never touched.
struct BootedByApp: Sendable {
    private static let key = "android.bootedByApp.v1"

    static var names: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    static func add(_ name: String) { UserDefaults.standard.set(Array(names.union([name])), forKey: key) }
    static func remove(_ name: String) { UserDefaults.standard.set(Array(names.subtracting([name])), forKey: key) }
}

/// Lists, boots and controls Android emulators with the SDK's `emulator` and `adb`. The screen arrives in a later phase.
struct EmulatorService: DeviceService {
    var platform: DevicePlatform { .android }
    var textSizes: [TextSizeOption] { AndroidTextSize.options }

    private let sdkProvider: @Sendable () -> AndroidSDK?
    private let avdDirectory: URL
    private let discoveryDirectory: URL

    init(sdkProvider: @escaping @Sendable () -> AndroidSDK? = { AndroidSDK.locate() },
         avdDirectory: URL = EmulatorService.defaultAVDDirectory(),
         discoveryDirectory: URL = RunningEmulator.defaultDirectory) {
        self.sdkProvider = sdkProvider
        self.avdDirectory = avdDirectory
        self.discoveryDirectory = discoveryDirectory
    }

    static func defaultAVDDirectory() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let path = env["ANDROID_AVD_HOME"]?.nonEmpty { return URL(fileURLWithPath: path) }
        let base = env["ANDROID_USER_HOME"]?.nonEmpty ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".android").path
        return URL(fileURLWithPath: base).appendingPathComponent("avd")
    }

    // MARK: DeviceService

    /// No SDK is not an error: the Android entries are simply absent.
    func devices() async throws -> [Device] {
        guard let sdk = sdkProvider() else { return [] }
        let running = RunningEmulator.running(in: discoveryDirectory)
        var devices: [Device] = []
        for avd in avds() where avd.isPhone {
            let emulator = running.first { $0.avdName == avd.name }
            var state = Device.State.shutdown
            if let emulator {
                state = await isBootCompleted(sdk, emulator.serial) ? .booted : .booting
            }
            devices.append(Device(id: avd.name, name: avd.displayName, platform: .android, osVersion: avd.osVersion,
                                  state: state, runID: emulator?.serial))
        }
        return devices.sorted {
            if $0.osVersion != $1.osVersion { return $0.osVersion.compare($1.osVersion, options: .numeric) == .orderedDescending }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Starts the emulator detached, so it outlives this app, then returns once Android has finished booting.
    func boot(_ device: Device) async throws {
        guard let sdk = sdkProvider() else { throw ClaudeCLIError.commandFailed("The Android SDK was not found.") }
        if RunningEmulator.running(in: discoveryDirectory).first(where: { $0.avdName == device.id }) == nil {
            guard FileManager.default.isExecutableFile(atPath: sdk.emulator) else {
                throw ClaudeCLIError.commandFailed("The Android Emulator isn't installed. Add it in Android Studio's SDK Manager.")
            }
            try await start(sdk, avd: device.id)
            BootedByApp.add(device.id)
        }
        let deadline = ContinuousClock.now + .seconds(240)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if let emulator = RunningEmulator.running(in: discoveryDirectory).first(where: { $0.avdName == device.id }),
               await isBootCompleted(sdk, emulator.serial) { return }
            try await Task.sleep(for: .seconds(2))
        }
        throw ClaudeCLIError.commandFailed("\(device.name) did not finish starting in four minutes. Check Show Log for details.")
    }

    func shutdown(_ device: Device) async throws {
        guard let sdk = sdkProvider() else { return }
        guard let serial = device.runID ?? RunningEmulator.running(in: discoveryDirectory).first(where: { $0.avdName == device.id })?.serial else { return }
        await Self.kill(sdk: sdk, serial: serial, avd: device.id, discoveryDirectory: discoveryDirectory)
    }

    func isDark(_ device: Device) async -> Bool? {
        guard let sdk = sdkProvider(), let serial = device.runID else { return nil }
        return await shell(sdk, serial, ["cmd", "uimode", "night"]).flatMap(AdbOutput.isNight)
    }

    func setDark(_ device: Device, _ dark: Bool) async {
        guard let sdk = sdkProvider(), let serial = device.runID else { return }
        _ = await shell(sdk, serial, ["cmd", "uimode", "night", dark ? "yes" : "no"])
    }

    func textSize(_ device: Device) async -> String? {
        guard let sdk = sdkProvider(), let serial = device.runID else { return nil }
        return await shell(sdk, serial, ["settings", "get", "system", "font_scale"]).map(AndroidTextSize.optionID)
    }

    func setTextSize(_ device: Device, _ id: String) async {
        guard let sdk = sdkProvider(), let serial = device.runID else { return }
        _ = await shell(sdk, serial, ["settings", "put", "system", "font_scale", id])
    }

    /// Needs the emulator's gRPC clipboard call, which arrives with the screen.
    func setClipboard(_ device: Device, text: String) async -> Bool { false }

    func screen(for device: Device) async throws -> any DeviceScreen {
        throw ClaudeCLIError.commandFailed("\(device.name) is running. Showing its screen here isn't supported yet; Run still works on it.")
    }

    // MARK: Quitting

    /// Emulators this app booted that are still running.
    static func runningBootedByApp(discoveryDirectory: URL = RunningEmulator.defaultDirectory) -> [RunningEmulator] {
        let ours = BootedByApp.names
        return RunningEmulator.running(in: discoveryDirectory).filter { ours.contains($0.avdName) }
    }

    /// Shuts each one down with `adb emu kill` and waits up to ten seconds for them to go.
    static func shutDown(_ emulators: [RunningEmulator], discoveryDirectory: URL = RunningEmulator.defaultDirectory) async {
        guard let sdk = AndroidSDK.locate() else { return }
        for emulator in emulators {
            await kill(sdk: sdk, serial: emulator.serial, avd: emulator.avdName, discoveryDirectory: discoveryDirectory)
        }
    }

    private static func kill(sdk: AndroidSDK, serial: String, avd: String, discoveryDirectory: URL) async {
        _ = try? await ProcessRunner(timeout: 15).run(sdk.adb, ["-s", serial, "emu", "kill"])
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline,
              RunningEmulator.running(in: discoveryDirectory).contains(where: { $0.avdName == avd }) {
            try? await Task.sleep(for: .milliseconds(300))
        }
        BootedByApp.remove(avd)
    }

    // MARK: Private

    private func avds() -> [AVDInfo] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: avdDirectory.path)) ?? []
        return files.filter { $0.hasSuffix(".ini") }.compactMap { file in
            let name = String(file.dropLast(4))
            let config = avdDirectory.appendingPathComponent("\(name).avd/config.ini")
            guard let text = try? String(contentsOf: config, encoding: .utf8) else { return nil }
            return AVDInfo.parse(name: name, config: text)
        }
    }

    private func isBootCompleted(_ sdk: AndroidSDK, _ serial: String) async -> Bool {
        await shell(sdk, serial, ["getprop", "sys.boot_completed"]).map(AdbOutput.isBootCompleted) ?? false
    }

    private func shell(_ sdk: AndroidSDK, _ serial: String, _ arguments: [String]) async -> String? {
        guard let out = try? await ProcessRunner(timeout: 15).run(sdk.adb, ["-s", serial, "shell"] + arguments), out.status == 0 else { return nil }
        return out.stdout
    }

    /// `nohup … &` through sh gives the emulator its own life: quitting this app doesn't stop it.
    private func start(_ sdk: AndroidSDK, avd: String) async throws {
        let port = Self.freePort(from: 8554, avoiding: RunningEmulator.running(in: discoveryDirectory).compactMap(\.grpcPort))
        let logFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/AppFast Studio/emulator.log")
        try? FileManager.default.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let script = #"nohup "$0" -avd "$1" -no-window -no-boot-anim -no-audio -grpc "$2" -grpc-use-token >>"$3" 2>&1 </dev/null &"#
        let out = try await ProcessRunner(timeout: 20, extraEnvironment: ["ANDROID_SDK_ROOT": sdk.root.path])
            .run("/bin/sh", ["-c", script, sdk.emulator, avd, String(port), logFile.path])
        guard out.status == 0 else {
            throw ClaudeCLIError.commandFailed(out.failureDetail(fallback: "The emulator could not be started."))
        }
    }

    /// The first TCP port from `start` that nothing is listening on and no running emulator uses.
    static func freePort(from start: Int, avoiding used: [Int]) -> Int {
        var port = start
        while port < start + 200 {
            if !used.contains(port), canBind(port) { return port }
            port += 1
        }
        return start
    }

    private static func canBind(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return result == 0
    }
}
