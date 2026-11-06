import Foundation
import Testing
@testable import AppFast_Studio

struct SetupPlanTests {
    private let app = "/Applications/Xcode.app"

    private var readyXcode: ToolchainFacts {
        ToolchainFacts(xcodeApp: app, xcodeVersion: "Version 27.1", developerDir: app + "/Contents/Developer",
                       xcodeLicenseAccepted: true, xcodeFirstLaunchDone: true)
    }

    private let runtime = SimulatorRuntime(identifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5", version: "26.5", iPhones: [
        .init(identifier: "t.17pro", name: "iPhone 17 Pro"), .init(identifier: "t.16", name: "iPhone 16"),
        .init(identifier: "t.17", name: "iPhone 17"), .init(identifier: "t.air", name: "iPhone Air"),
    ])

    @Test func anEmptyMacStartsWithClaudeAndTheAppStoreAndWaitsOnXcodeForTheRest() {
        let facts = ToolchainFacts()
        #expect(SetupPlan.status(of: .claude, in: facts) == .needed(.installClaude))
        #expect(SetupPlan.status(of: .xcode, in: facts) == .needed(.getXcode))
        for item in [SetupItem.flutter, .cocoapods, .simulator] {
            #expect(SetupPlan.status(of: item, in: facts) == .blocked("Set up Xcode first."))
        }
        #expect(!SetupPlan.requiredReady(facts))
    }

    @Test func xcodeIsOnlyReadyWhenSelectedLicensedAndFirstLaunched() {
        var facts = ToolchainFacts(xcodeApp: app, developerDir: "/Library/Developer/CommandLineTools")
        #expect(SetupPlan.status(of: .xcode, in: facts) == .needed(.finishXcodeSetup(app: app)))
        facts.developerDir = app + "/Contents/Developer"
        facts.xcodeLicenseAccepted = true
        #expect(SetupPlan.status(of: .xcode, in: facts) == .needed(.finishXcodeSetup(app: app)))
        facts.xcodeFirstLaunchDone = true
        #expect(SetupPlan.status(of: .xcode, in: facts) == .ready("Installed"))
        // Another Xcode being selected doesn't count as this one being set up.
        facts.developerDir = "/Applications/Xcode-beta.app/Contents/Developer"
        #expect(!facts.xcodeReady)
    }

    @Test func flutterOffThePathOnlyNeedsThePathFixed() {
        var facts = readyXcode
        #expect(SetupPlan.status(of: .flutter, in: facts) == .needed(.installFlutter))
        facts.flutterPath = "/Users/a/development/flutter/bin/flutter"
        #expect(SetupPlan.status(of: .flutter, in: facts) == .needed(.addFlutterToPath(bin: "/Users/a/development/flutter/bin")))
        facts.flutterOnPath = true
        facts.flutterVersion = "3.47.9"
        #expect(SetupPlan.status(of: .flutter, in: facts) == .ready("Version 3.47.9"))
    }

    @Test func aRuntimeWithoutDevicesGetsThePlainNewestiPhone() {
        var facts = readyXcode
        #expect(SetupPlan.status(of: .simulator, in: facts) == .needed(.downloadSimulator))
        facts.iosRuntimes = [runtime]
        #expect(SetupPlan.status(of: .simulator, in: facts)
                == .needed(.createSimulator(runtime: runtime.identifier, deviceType: "t.17", name: "iPhone 17")))
        facts.iosDeviceCount = 3
        #expect(SetupPlan.status(of: .simulator, in: facts) == .ready("3 available"))
    }

    @Test func aRuntimeWithOnlyFancyiPhonesUsesTheFirst() {
        let fancy = SimulatorRuntime(identifier: "r", version: "1", iPhones: [.init(identifier: "a", name: "iPhone Air")])
        #expect(SetupPlan.preferrediPhone(in: fancy)?.identifier == "a")
        #expect(SetupPlan.preferrediPhone(in: SimulatorRuntime(identifier: "r", version: "1", iPhones: [])) == nil)
    }

    @Test func cocoaPodsBringsHomebrewOnlyWhenItIsMissingAndIsOptional() {
        var facts = readyXcode
        #expect(SetupPlan.status(of: .cocoapods, in: facts) == .needed(.installCocoaPods(withHomebrew: true)))
        #expect(SetupAction.installCocoaPods(withHomebrew: true).needsPassword)
        facts.brewPath = "/opt/homebrew/bin/brew"
        #expect(SetupPlan.status(of: .cocoapods, in: facts) == .needed(.installCocoaPods(withHomebrew: false)))
        #expect(!SetupAction.installCocoaPods(withHomebrew: false).needsPassword)

        facts.claudePath = "/x/claude"
        facts.flutterPath = "/x/flutter"
        facts.flutterOnPath = true
        facts.iosDeviceCount = 1
        #expect(SetupPlan.requiredReady(facts))
    }
}

struct ShellProfileTests {
    private let home = "/Users/a"

    @Test func bashUsesTheProfileFileThatAlreadyExists() {
        #expect(ShellProfile.file(for: .zsh, home: home) { _ in false } == "/Users/a/.zprofile")
        #expect(ShellProfile.file(for: .bash, home: home) { _ in false } == "/Users/a/.bash_profile")
        #expect(ShellProfile.file(for: .bash, home: home) { $0 == "/Users/a/.profile" } == "/Users/a/.profile")
        #expect(ShellProfile.file(for: .fish, home: home) { _ in false } == "/Users/a/.config/fish/conf.d/mobile-studio.fish")
        #expect(ShellProfile.Kind(shell: "/opt/homebrew/bin/fish") == .fish)
        #expect(ShellProfile.Kind(shell: "/bin/tcsh") == .other)
    }

    @Test func addsAMarkedLineOnceAndKeepsWhatWasThere() throws {
        let entry = ShellProfile.Entry.path("/Users/a/development/flutter/bin")
        let added = try #require(ShellProfile.adding(entry, to: "export EDITOR=vim", kind: .zsh, home: home))
        #expect(added == "export EDITOR=vim\n\n# Added by AppFast Studio\nexport PATH=\"$HOME/development/flutter/bin:$PATH\"\n")
        #expect(ShellProfile.adding(entry, to: added, kind: .zsh, home: home) == nil)
        #expect(ShellProfile.adding(entry, to: "", kind: .zsh, home: home) == "# Added by AppFast Studio\nexport PATH=\"$HOME/development/flutter/bin:$PATH\"\n")
    }

    @Test func recognisesTheFolderHowEverItIsWrittenButNotWhenCommentedOut() {
        let entry = ShellProfile.Entry.path("/Users/a/development/flutter/bin")
        #expect(ShellProfile.adding(entry, to: "export PATH=~/development/flutter/bin:$PATH\n", kind: .zsh, home: home) == nil)
        #expect(ShellProfile.adding(entry, to: "path+=/Users/a/development/flutter/bin\n", kind: .zsh, home: home) == nil)
        #expect(ShellProfile.adding(entry, to: "# export PATH=$HOME/development/flutter/bin:$PATH\n", kind: .zsh, home: home) != nil)
    }

    @Test func writesEachShellsOwnSyntax() {
        #expect(ShellProfile.line(for: .path("/opt/flutter/bin"), kind: .fish, home: home) == "fish_add_path -g \"/opt/flutter/bin\"")
        #expect(ShellProfile.line(for: .brewShellenv(brew: "/opt/homebrew/bin/brew"), kind: .zsh, home: home)
                == "eval \"$(/opt/homebrew/bin/brew shellenv)\"")
        #expect(ShellProfile.line(for: .brewShellenv(brew: "/opt/homebrew/bin/brew"), kind: .fish, home: home)
                == "/opt/homebrew/bin/brew shellenv | source")
        #expect(ShellProfile.adding(.brewShellenv(brew: "/opt/homebrew/bin/brew"),
                                    to: "eval \"$(/opt/homebrew/bin/brew shellenv zsh)\"\n", kind: .zsh, home: home) == nil)
    }
}

struct SetupFormatTests {
    private let flutterFeed = """
    {"base_url": "https://storage.googleapis.com/flutter_infra_release/releases",
     "current_release": {"beta": "b", "stable": "s"},
     "releases": [
      {"hash": "b", "channel": "beta", "version": "3.48.0-1.0.pre", "dart_sdk_arch": "arm64",
       "archive": "beta/macos/flutter_macos_arm64_3.48.0-1.0.pre-beta.zip", "sha256": "bb"},
      {"hash": "s", "channel": "stable", "version": "3.47.9", "dart_sdk_arch": "x64",
       "archive": "stable/macos/flutter_macos_3.47.9-stable.zip", "sha256": "AA11"},
      {"hash": "s", "channel": "stable", "version": "3.47.9", "dart_sdk_arch": "arm64",
       "archive": "stable/macos/flutter_macos_arm64_3.47.9-stable.zip", "sha256": "cc22"}
     ]}
    """

    @Test func picksTheCurrentStableBuildForThisProcessor() throws {
        let arm = try FlutterRelease.latestStable(from: Data(flutterFeed.utf8), arm64: true)
        #expect(arm.url.absoluteString == "https://storage.googleapis.com/flutter_infra_release/releases/stable/macos/flutter_macos_arm64_3.47.9-stable.zip")
        #expect(arm.sha256 == "cc22")
        #expect(arm.name == "Flutter 3.47.9")
        let intel = try FlutterRelease.latestStable(from: Data(flutterFeed.utf8), arm64: false)
        #expect(intel.sha256 == "aa11")
        #expect(intel.fileName == "flutter_macos_3.47.9-stable.zip")
    }

    @Test func homebrewNeedsADigestAndAGitHubDownload() throws {
        let release = """
        {"tag_name": "7.0.12", "assets": [{"name": "Homebrew.pkg",
         "browser_download_url": "https://github.com/Homebrew/brew/releases/download/7.0.12/Homebrew.pkg",
         "digest": "sha256:A982"}]}
        """
        let package = try HomebrewRelease.installer(from: Data(release.utf8))
        #expect(package.sha256 == "a982")
        #expect(package.name == "Homebrew 7.0.12")
        let unsigned = release.replacingOccurrences(of: "\"digest\": \"sha256:A982\"", with: "\"digest\": null")
        #expect(throws: SetupError.self) { try HomebrewRelease.installer(from: Data(unsigned.utf8)) }
        let elsewhere = release.replacingOccurrences(of: "https://github.com", with: "https://example.com")
        #expect(throws: SetupError.self) { try HomebrewRelease.installer(from: Data(elsewhere.utf8)) }
    }

    @Test func readsProgressFromCurlAndXcodebuild() {
        #expect(SetupProgress.fraction(in: "\r####################        42.5%") == 0.425)
        #expect(SetupProgress.fraction(in: "Downloading iOS 26.5 Simulator (23F77): 7.0% (590 MB of 8.4 GB)\n") == 0.07)
        #expect(SetupProgress.fraction(in: "==> Pouring ruby") == nil)
        #expect(SetupProgress.lastLine(in: "==> Fetching ruby\n==> Pouring ruby--3.4.bottle\n\r###   12.0%") == "==> Pouring ruby--3.4.bottle")
        #expect(SetupProgress.lastLine(in: "\r### 10%\r###### 20%") == nil)
    }

    @Test func adminScriptAndArgumentsTravelAsArguments() {
        let args = AdminShell.arguments(prompt: "Password, please", script: "echo \"$1\"", scriptArguments: ["/Applications/X code.app"])
        #expect(args.suffix(3) == ["Password, please", "echo \"$1\"", "/Applications/X code.app"])
        let source = stride(from: 1, to: args.count - 3, by: 2).map { args[$0] }.joined(separator: "\n")
        #expect(source.contains("with administrator privileges"))
        #expect(!source.contains("X code"))
        #expect(AdminShell.wasCancelled(ProcessOutput(status: 1, stdout: "", stderr: "execution error: User canceled. (-128)")))
    }

    @Test func readsiOSRuntimesNewestFirstWithTheiriPhones() {
        let json = """
        {"runtimes": [
         {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-6", "version": "18.6", "platform": "iOS", "isAvailable": true,
          "supportedDeviceTypes": [{"identifier": "p16", "name": "iPhone 16", "productFamily": "iPhone"},
                                   {"identifier": "ipad", "name": "iPad Air", "productFamily": "iPad"}]},
         {"identifier": "com.apple.CoreSimulator.SimRuntime.watchOS-11-0", "version": "11.0", "platform": "watchOS", "isAvailable": true},
         {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-5", "version": "26.5", "platform": "iOS", "isAvailable": true,
          "supportedDeviceTypes": [{"identifier": "p17", "name": "iPhone 17", "productFamily": "iPhone"}]}
        ]}
        """
        let runtimes = ToolchainDetector.iosRuntimes(fromJSON: Data(json.utf8))
        #expect(runtimes.map(\.version) == ["26.5", "18.6"])
        #expect(runtimes.last?.iPhones == [.init(identifier: "p16", name: "iPhone 16")])
    }

    @Test func hashesFilesAndExplainsFailuresFromTheirLastLines() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("abc".utf8).write(to: file)
        #expect(try SetupInstaller.sha256(of: file) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

        let output = ProcessOutput(status: 1, stdout: "==> Fetching\n", stderr: "\r### 50%\nError: No space left on device\n")
        #expect(SetupInstaller.reason(output) == "Error: No space left on device ==> Fetching")
        #expect(SetupInstaller.reason(ProcessOutput(status: 3, stdout: "", stderr: "")) == "it stopped with status 3.")
    }

    @Test func spaceErrorsSayHowMuchIsNeeded() {
        let message = SetupError.notEnoughSpace(needed: 12_000_000_000, free: 3_000_000_000).localizedDescription
        #expect(message.contains("12 GB") && message.contains("3 GB"))
    }

    @Test func readsFlutterVersionFromTheSDKWithoutRunningIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("bin/cache"), withIntermediateDirectories: true)
        try Data(#"{"frameworkVersion": "3.47.9", "channel": "stable"}"#.utf8).write(to: root.appendingPathComponent("bin/cache/flutter.version.json"))
        #expect(ToolchainDetector.flutterVersion(launcher: root.appendingPathComponent("bin/flutter").path) == "3.47.9")
    }
}
