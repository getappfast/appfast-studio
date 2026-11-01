import Foundation

/// What a new iOS app needs besides Flutter, checked before Create so a missing tool is explained up front
/// instead of failing at the first run. These are warnings: the project can still be made.
enum ToolchainCheck {
    static func problems() async -> [String] {
        var problems: [String] = []
        let runner = ProcessRunner(timeout: 15)
        let developer = (try? await runner.run("/usr/bin/xcode-select", ["-p"]))?.stdout ?? ""
        if !developer.contains(".app/") {
            problems.append("Xcode isn't set up, so the app can't build for the iOS Simulator. Install Xcode, then run xcode-select in Terminal.")
        }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let pod = try? await runner.run(shell, ["-ilc", "command -v pod"])
        if pod?.stdout.contains("/") != true {
            problems.append("CocoaPods wasn't found, and iOS builds need it. Install it with: brew install cocoapods")
        }
        return problems
    }
}
