import Foundation

/// Where the Android SDK is. Pure apart from the file checks passed in, so it is testable.
struct AndroidSDK: Sendable, Equatable {
    let root: URL

    var adb: String { root.appendingPathComponent("platform-tools/adb").path }
    var emulator: String { root.appendingPathComponent("emulator/emulator").path }

    /// First usable SDK, in the order Android's own tools use: `ANDROID_HOME`, `ANDROID_SDK_ROOT`, what `flutter config`
    /// saved (`~/.flutter_settings`), then Android Studio's default folder. Usable means it has `adb`.
    static func locate(environment: [String: String], flutterSettings: Data?, home: URL,
                       fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> AndroidSDK? {
        var candidates = [environment["ANDROID_HOME"], environment["ANDROID_SDK_ROOT"]]
        if let flutterSettings,
           let settings = try? JSONSerialization.jsonObject(with: flutterSettings) as? [String: Any] {
            candidates.append(settings["android-sdk"] as? String)
        }
        candidates.append(home.appendingPathComponent("Library/Android/sdk").path)
        for path in candidates.compactMap({ $0?.nonEmpty }) {
            let sdk = AndroidSDK(root: URL(fileURLWithPath: path))
            if fileExists(sdk.adb) { return sdk }
        }
        return nil
    }

    static func locate() -> AndroidSDK? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let settings = try? Data(contentsOf: home.appendingPathComponent(".flutter_settings"))
        return locate(environment: ProcessInfo.processInfo.environment, flutterSettings: settings, home: home)
    }
}

/// One virtual device from `~/.android/avd`.
struct AVDInfo: Sendable, Equatable {
    let name: String
    let displayName: String
    /// e.g. "Android 36"
    let osVersion: String
    /// Phones and tablets only: Wear, TV, Automotive and XR images can't run a Flutter phone app.
    let isPhone: Bool

    /// `config` is the text of `<name>.avd/config.ini`.
    static func parse(name: String, config: String) -> AVDInfo {
        var values: [String: String] = [:]
        for line in config.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            values[line[..<eq].trimmingCharacters(in: .whitespaces)] = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        }
        let display = values["avd.ini.displayname"]?.nonEmpty ?? name.replacingOccurrences(of: "_", with: " ")
        let tag = (values["tag.id"] ?? "").lowercased()
        let excluded = ["wear", "tv", "automotive", "xr", "glasses", "desktop"]
        return AVDInfo(name: name, displayName: display, osVersion: osVersion(sysdir: values["image.sysdir.1"] ?? ""),
                       isPhone: !excluded.contains { tag.contains($0) })
    }

    /// "system-images/android-36.1/google_apis/arm64-v8a/" -> "Android 36.1"; extension levels like "-ext18" are dropped.
    static func osVersion(sysdir: String) -> String {
        guard let match = sysdir.firstMatch(of: /android-([0-9]+(?:\.[0-9]+)?)/) else { return "Android" }
        return "Android \(match.1)"
    }
}

/// A running emulator, read from the discovery file it writes in `~/Library/Caches/TemporaryItems/avd/running`.
struct RunningEmulator: Sendable, Equatable {
    let avdName: String
    /// The adb serial, e.g. "emulator-5554".
    let serial: String
    let pid: Int32?
    let grpcPort: Int?
    let grpcToken: String?

    static func parse(_ text: String, fileName: String = "") -> RunningEmulator? {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            values[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        guard let name = values["avd.name"]?.nonEmpty, let port = values["port.serial"].flatMap({ Int($0) }) else { return nil }
        let pid = fileName.firstMatch(of: /pid_([0-9]+)\.ini/).flatMap { Int32($0.1) }
        return RunningEmulator(avdName: name, serial: "emulator-\(port)", pid: pid,
                               grpcPort: values["grpc.port"].flatMap { Int($0) }, grpcToken: values["grpc.token"]?.nonEmpty)
    }

    /// Emulators whose process is still alive; a crashed one leaves its file behind.
    static func running(in directory: URL, isAlive: (Int32) -> Bool = { kill($0, 0) == 0 }) -> [RunningEmulator] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return files.filter { $0.hasPrefix("pid_") && $0.hasSuffix(".ini") }.compactMap { file in
            guard let text = try? String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8),
                  let emulator = parse(text, fileName: file) else { return nil }
            if let pid = emulator.pid, !isAlive(pid) { return nil }
            return emulator
        }
    }

    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/TemporaryItems/avd/running")
    }
}

/// Parsers for what `adb` prints.
enum AdbOutput {
    /// Serial and state of each emulator in `adb devices`.
    static func emulators(in output: String) -> [(serial: String, state: String)] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            guard parts.count >= 2, parts[0].hasPrefix("emulator-") else { return nil }
            return (String(parts[0]), String(parts[1]))
        }
    }

    static func isBootCompleted(_ output: String) -> Bool {
        output.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    /// `adb shell cmd uimode night` prints "Night mode: yes"; nil for "auto" or anything else.
    static func isNight(_ output: String) -> Bool? {
        let text = output.lowercased()
        if text.contains("night mode: yes") { return true }
        if text.contains("night mode: no") { return false }
        return nil
    }
}

/// Android's text size is a scale factor in `font_scale`.
enum AndroidTextSize {
    static let options: [TextSizeOption] = [
        ("0.85", "Small"), ("1.0", "Default"), ("1.15", "Large"), ("1.3", "Larger"), ("1.5", "Extra Large"), ("2.0", "Largest"),
    ].map { TextSizeOption(id: $0.0, name: $0.1) }

    /// The option closest to what `settings get system font_scale` printed ("null" means the default).
    static func optionID(for output: String) -> String {
        let scale = Double(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1.0
        return options.min { abs(Double($0.id)! - scale) < abs(Double($1.id)! - scale) }?.id ?? "1.0"
    }
}

/// What to do about running emulators when the app quits.
enum AndroidQuitChoice: String, Sendable, CaseIterable {
    case ask, keep, shutDown

    static let key = "android.quitChoice.v1"

    enum Action: Equatable { case quit, askUser, shutDownThenQuit }

    /// Only emulators this app booted are ever considered; anything else is left alone.
    func action(runningBootedByApp count: Int) -> Action {
        guard count > 0 else { return .quit }
        switch self {
        case .ask: return .askUser
        case .keep: return .quit
        case .shutDown: return .shutDownThenQuit
        }
    }
}
