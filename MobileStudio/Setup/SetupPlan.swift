import Foundation

/// The tools AppFast Studio needs on the Mac, in the order "Set Up Everything" installs them. Signing in to Claude
/// and choosing a project are separate steps of the checklist; this is only what gets installed.
enum SetupItem: String, CaseIterable, Identifiable, Sendable {
    case claude, xcode, flutter, cocoapods, simulator

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: "Claude CLI"
        case .xcode: "Xcode"
        case .flutter: "Flutter"
        case .cocoapods: "CocoaPods"
        case .simulator: "iOS Simulator"
        }
    }

    /// CocoaPods is only needed by plugins that don't support Swift Package Manager yet, which Flutter now uses by
    /// default, so the checklist can finish without it.
    var isRequired: Bool { self != .cocoapods }
}

/// An iOS simulator runtime and the iPhones it can run, from `simctl list runtimes -j`.
struct SimulatorRuntime: Equatable, Sendable {
    let identifier: String
    let version: String
    /// (identifier, name) of the iPhone device types this runtime supports.
    let iPhones: [DeviceType]

    struct DeviceType: Equatable, Sendable {
        let identifier: String
        let name: String
    }
}

/// What is on this Mac right now, as `ToolchainDetector` found it. Everything the checklist shows comes from here.
struct ToolchainFacts: Equatable, Sendable {
    var claudePath: String?
    var claudeVersion: String?
    /// The Xcode app, once it is fully installed (its xcodebuild exists).
    var xcodeApp: String?
    var xcodeVersion: String?
    /// What `xcode-select -p` prints: Xcode's Developer folder, the Command Line Tools, or nothing.
    var developerDir: String?
    var xcodeLicenseAccepted = false
    var xcodeFirstLaunchDone = false
    var iosRuntimes: [SimulatorRuntime] = []
    var iosDeviceCount = 0
    /// The Flutter launcher, wherever it was found; `flutterOnPath` says whether the user's shell finds it too.
    var flutterPath: String?
    var flutterOnPath = false
    var flutterVersion: String?
    var podPath: String?
    var brewPath: String?
    /// Free space on the home volume, for a readable error before a large download.
    var freeBytes: Int64?

    /// Xcode is installed, selected, its licence accepted and its first-launch packages installed.
    var xcodeReady: Bool {
        guard let xcodeApp, let developerDir else { return false }
        return developerDir.hasPrefix(xcodeApp) && xcodeLicenseAccepted && xcodeFirstLaunchDone
    }
}

/// Something the app can do about a missing tool. `getXcode` is the one it can't do alone: Xcode comes from the
/// App Store, which needs the user's Apple ID, so the app opens the page and waits for it to arrive.
enum SetupAction: Equatable, Sendable {
    case installClaude
    case getXcode
    case finishXcodeSetup(app: String)
    case installFlutter
    case addFlutterToPath(bin: String)
    case installCocoaPods(withHomebrew: Bool)
    case downloadSimulator
    case createSimulator(runtime: String, deviceType: String, name: String)

    var buttonTitle: String {
        switch self {
        case .getXcode: "Get Xcode…"
        case .finishXcodeSetup: "Finish Setup"
        case .addFlutterToPath: "Fix"
        case .createSimulator: "Add iPhone"
        default: "Install"
        }
    }

    /// What the row says while the tool is missing, in words that say what will happen.
    var explanation: String {
        switch self {
        case .installClaude: "Not installed yet. It takes a minute."
        case .getXcode: "Get it free from the App Store. It's about 12 GB."
        case .finishXcodeSetup: "Downloaded. It needs your password once to finish."
        case .installFlutter: "Not installed yet. It's a 1.5 GB download."
        case .addFlutterToPath: "Installed, but your Terminal can't find it yet."
        case .installCocoaPods(let withHomebrew):
            withHomebrew ? "Some plugins need it. Installing asks for your password." : "Some plugins need it."
        case .downloadSimulator: "No iPhone simulator yet. It's about an 8 GB download."
        case .createSimulator(_, _, let name): "No iPhone to run on yet. AppFast Studio can add an \(name)."
        }
    }

    var needsPassword: Bool {
        switch self {
        case .finishXcodeSetup: true
        case .installCocoaPods(let withHomebrew): withHomebrew
        default: false
        }
    }

    /// Roughly what the step downloads, for the note under Set Up Everything.
    var downloadBytes: Int64 {
        let megabyte: Int64 = 1_000_000
        switch self {
        case .installClaude: return 100 * megabyte
        case .getXcode: return 12_000 * megabyte
        case .installFlutter: return 1_500 * megabyte
        case .installCocoaPods: return 300 * megabyte
        case .downloadSimulator: return 8_000 * megabyte
        default: return 0
        }
    }

    /// Roughly what the step needs free on disk, checked before starting it.
    var bytesNeeded: Int64 {
        let gigabyte: Int64 = 1_000_000_000
        switch self {
        case .installFlutter: return 4 * gigabyte
        case .downloadSimulator: return 12 * gigabyte
        case .installCocoaPods: return gigabyte
        default: return 0
        }
    }
}

enum SetupStatus: Equatable, Sendable {
    case checking
    case ready(String)
    case needed(SetupAction)
    /// Waits on another item, with the reason in words ("Set up Xcode first.").
    case blocked(String)

    var isReady: Bool { if case .ready = self { true } else { false } }

    var action: SetupAction? { if case .needed(let action) = self { action } else { nil } }
}

/// The rules between the tools, kept pure so they can be tested: what each one needs and which comes first.
enum SetupPlan {
    static func status(of item: SetupItem, in facts: ToolchainFacts) -> SetupStatus {
        switch item {
        case .claude:
            if facts.claudePath != nil { return .ready(facts.claudeVersion ?? "Installed") }
            return .needed(.installClaude)

        case .xcode:
            if facts.xcodeReady { return .ready(facts.xcodeVersion ?? "Installed") }
            if let app = facts.xcodeApp { return .needed(.finishXcodeSetup(app: app)) }
            return .needed(.getXcode)

        case .flutter:
            if facts.flutterPath != nil, facts.flutterOnPath { return .ready(facts.flutterVersion.map { "Version \($0)" } ?? "Installed") }
            // Flutter's first run uses git, which comes with Xcode; without it macOS pops up its own installer.
            guard facts.xcodeReady else { return .blocked("Set up Xcode first.") }
            if let path = facts.flutterPath { return .needed(.addFlutterToPath(bin: (path as NSString).deletingLastPathComponent)) }
            return .needed(.installFlutter)

        case .cocoapods:
            if facts.podPath != nil { return .ready("Installed") }
            guard facts.xcodeReady else { return .blocked("Set up Xcode first.") }
            return .needed(.installCocoaPods(withHomebrew: facts.brewPath == nil))

        case .simulator:
            if facts.iosDeviceCount > 0 { return .ready(facts.iosDeviceCount == 1 ? "1 available" : "\(facts.iosDeviceCount) available") }
            guard facts.xcodeReady else { return .blocked("Set up Xcode first.") }
            if let runtime = facts.iosRuntimes.first, let phone = preferrediPhone(in: runtime) {
                return .needed(.createSimulator(runtime: runtime.identifier, deviceType: phone.identifier, name: phone.name))
            }
            return .needed(.downloadSimulator)
        }
    }

    /// Everything the checklist can't finish without.
    static func requiredReady(_ facts: ToolchainFacts) -> Bool {
        SetupItem.allCases.filter(\.isRequired).allSatisfy { status(of: $0, in: facts).isReady }
    }

    /// The plain model of the newest iPhone ("iPhone 17" over "iPhone 17 Pro Max"), else the first one listed.
    static func preferrediPhone(in runtime: SimulatorRuntime) -> SimulatorRuntime.DeviceType? {
        let plain = runtime.iPhones.filter { $0.name.wholeMatch(of: /iPhone \d+/) != nil }
        let newest = plain.max { (number(in: $0.name) ?? 0) < (number(in: $1.name) ?? 0) }
        return newest ?? runtime.iPhones.first
    }

    private static func number(in name: String) -> Int? {
        name.firstMatch(of: /\d+/).flatMap { Int($0.output) }
    }
}
