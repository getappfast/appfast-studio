import AppKit
import Foundation

/// Looks at what is installed without changing anything. Nothing here runs `flutter` or `git`: before Xcode is set
/// up, `/usr/bin/git` pops up macOS's own Command Line Tools installer, which would confuse someone mid-setup.
struct ToolchainDetector: Sendable {
    private let runner = ProcessRunner(timeout: 20)

    func detect() async -> ToolchainFacts {
        #if DEBUG
        if let fake = SetupFake.facts { return fake }
        #endif
        async let claude = claude()
        async let xcode = xcode()
        async let flutter = flutter()
        async let pod = loginShellPath(of: "pod")
        let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }

        var facts = await xcode
        (facts.claudePath, facts.claudeVersion) = await claude
        (facts.flutterPath, facts.flutterOnPath, facts.flutterVersion) = await flutter
        facts.podPath = await pod
        facts.brewPath = brew
        facts.freeBytes = Self.freeBytes()
        return facts
    }

    // MARK: Claude

    private func claude() async -> (String?, String?) {
        guard let path = await ClaudeCLIService().locate() else { return (nil, nil) }
        return (path, try? await ClaudeCLIService().version(at: path))
    }

    // MARK: Xcode

    private func xcode() async -> ToolchainFacts {
        var facts = ToolchainFacts()
        let selected = try? await runner.run("/usr/bin/xcode-select", ["-p"])
        facts.developerDir = selected?.status == 0 ? selected?.stdout.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty : nil

        guard let app = Self.xcodeApp(selected: facts.developerDir) else { return facts }
        facts.xcodeApp = app
        let xcodebuild = "\(app)/Contents/Developer/usr/bin/xcodebuild"
        // Ask this Xcode directly, so the answers are about it even while the Command Line Tools are selected.
        let direct = ProcessRunner(timeout: 30, extraEnvironment: ["DEVELOPER_DIR": "\(app)/Contents/Developer"])
        if let version = try? await direct.run(xcodebuild, ["-version"]), version.status == 0 {
            facts.xcodeVersion = version.stdout.split(whereSeparator: \.isNewline).first.map { $0.replacingOccurrences(of: "Xcode ", with: "Version ") }
        }
        facts.xcodeLicenseAccepted = (try? await direct.run(xcodebuild, ["-license", "check"]))?.status == 0
        facts.xcodeFirstLaunchDone = (try? await direct.run(xcodebuild, ["-checkFirstLaunchStatus"]))?.status == 0
        if facts.xcodeLicenseAccepted {
            (facts.iosRuntimes, facts.iosDeviceCount) = await simulators(developerDir: "\(app)/Contents/Developer")
        }
        return facts
    }

    /// The selected Xcode if it is an app, else the usual places, else wherever Launch Services knows one.
    /// Only a complete app counts: the App Store shows Xcode in Launchpad before the download has finished.
    static func xcodeApp(selected developerDir: String?) -> String? {
        var candidates: [String] = []
        if let developerDir, let range = developerDir.range(of: ".app/") {
            candidates.append(String(developerDir[..<range.lowerBound]) + ".app")
        }
        candidates += ["/Applications/Xcode.app", "/Applications/Xcode-beta.app", "\(NSHomeDirectory())/Applications/Xcode.app"]
        candidates += NSWorkspace.shared.urlsForApplications(withBundleIdentifier: "com.apple.dt.Xcode").map(\.path)
        return candidates.first { FileManager.default.isExecutableFile(atPath: "\($0)/Contents/Developer/usr/bin/xcodebuild") }
    }

    private func simulators(developerDir: String) async -> ([SimulatorRuntime], Int) {
        let xcrun = ProcessRunner(timeout: 30, extraEnvironment: ["DEVELOPER_DIR": developerDir])
        var runtimes: [SimulatorRuntime] = []
        if let out = try? await xcrun.run("/usr/bin/xcrun", ["simctl", "list", "runtimes", "available", "-j"]), out.status == 0 {
            runtimes = Self.iosRuntimes(fromJSON: Data(out.stdout.utf8))
        }
        let devices = (try? await SimctlService().devices())?.count ?? 0
        return (runtimes, devices)
    }

    private struct RuntimeListing: Decodable {
        struct Runtime: Decodable {
            struct DeviceType: Decodable { let identifier: String; let name: String; let productFamily: String? }
            let identifier: String
            let version: String
            let platform: String?
            let isAvailable: Bool?
            let supportedDeviceTypes: [DeviceType]?
        }
        let runtimes: [Runtime]
    }

    /// Available iOS runtimes, newest first, each with the iPhones it supports.
    static func iosRuntimes(fromJSON data: Data) -> [SimulatorRuntime] {
        guard let listing = try? JSONDecoder().decode(RuntimeListing.self, from: data) else { return [] }
        return listing.runtimes
            .filter { ($0.platform == "iOS" || $0.identifier.contains("SimRuntime.iOS-")) && $0.isAvailable != false }
            .sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
            .map { runtime in
                SimulatorRuntime(identifier: runtime.identifier, version: runtime.version, iPhones: (runtime.supportedDeviceTypes ?? [])
                    .filter { $0.productFamily == "iPhone" || $0.name.hasPrefix("iPhone") }
                    .map { .init(identifier: $0.identifier, name: $0.name) })
            }
    }

    // MARK: Flutter

    private func flutter() async -> (String?, Bool, String?) {
        let onPath = await loginShellPath(of: "flutter")
        guard let path = onPath ?? Self.knownFlutter() else { return (nil, false, nil) }
        return (path, onPath != nil, Self.flutterVersion(launcher: path))
    }

    /// Where people (and this app) usually put the SDK, for one the shell can't find yet.
    static func knownFlutter() -> String? {
        let home = NSHomeDirectory()
        return [
            "\(home)/development/flutter", "\(home)/flutter", "\(home)/dev/flutter", "\(home)/sdk/flutter",
            "\(home)/dev/sdk/flutter", "\(home)/fvm/default", "/opt/homebrew/share/flutter", "/usr/local/flutter",
        ]
        .map { "\($0)/bin/flutter" }
        .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Read from the SDK's files rather than by running `flutter --version`, which needs git.
    static func flutterVersion(launcher: String) -> String? {
        let root = URL(fileURLWithPath: launcher).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        if let data = try? Data(contentsOf: root.appendingPathComponent("bin/cache/flutter.version.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let version = json["frameworkVersion"] as? String {
            return version
        }
        return (try? String(contentsOf: root.appendingPathComponent("version"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    // MARK: Helpers

    /// What the user's Terminal finds for a command, which is also what Flutter and Claude's shell will find.
    private func loginShellPath(of command: String) async -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        // `command` is one of this file's own constants, never user text; fish has no "$1", so it goes in the text.
        guard let out = try? await ProcessRunner(timeout: 15).run(shell, ["-ilc", "command -v \(command)"]) else { return nil }
        let line = out.stdout.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.last { $0.hasPrefix("/") }
        guard let line, FileManager.default.isExecutableFile(atPath: line) else { return nil }
        return line
    }

    static func freeBytes() -> Int64? {
        let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
