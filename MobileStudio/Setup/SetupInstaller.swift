import CryptoKit
import Foundation

struct InstallProgress: Equatable, Sendable {
    var text: String
    /// 0...1 when the tool says how far it is, nil for a spinner.
    var fraction: Double?
}

/// Does one `SetupAction`. Every download is checked against the SHA-256 its publisher lists before it is used,
/// steps that need root go through macOS's password dialog (`AdminShell`), and nothing the user made is deleted:
/// only the app's own downloads and half-unpacked folders are removed. Each command is written to `setup.log`.
struct SetupInstaller: Sendable {
    static let log = DiagnosticLog(name: "setup")
    /// Called as work progresses; may be called from any thread.
    let report: @Sendable (InstallProgress) -> Void

    func perform(_ action: SetupAction, facts: ToolchainFacts) async throws {
        try checkSpace(for: action, facts: facts)
        switch action {
        case .installClaude:
            report(.init(text: "Installing the Claude CLI…"))
            // The official installer; it puts claude in ~/.local/bin, where the app looks first.
            try await stream("/bin/bash", ["-c", "set -o pipefail; curl -fsSL https://claude.ai/install.sh | bash"],
                             step: "Installing the Claude CLI", timeout: 900)
        case .getXcode:
            break   // The model opens the App Store and waits; nothing to run.
        case .finishXcodeSetup(let app):
            try await finishXcodeSetup(app: app)
        case .installFlutter:
            try await installFlutter()
        case .addFlutterToPath(let bin):
            try addToProfile(.path(bin))
        case .installCocoaPods(let withHomebrew):
            try await installCocoaPods(brew: withHomebrew ? nil : facts.brewPath)
        case .downloadSimulator:
            try await downloadSimulator(facts: facts)
        case .createSimulator(let runtime, let deviceType, let name):
            report(.init(text: "Adding an \(name)…"))
            try await stream("/usr/bin/xcrun", ["simctl", "create", name, deviceType, runtime], step: "Adding the simulator", timeout: 120)
        }
    }

    // MARK: Xcode

    private func finishXcodeSetup(app: String) async throws {
        // Select this Xcode, accept its licence and install its first-launch packages: what Xcode does when opened.
        let script = """
        set -e
        dev="$1/Contents/Developer"
        /usr/bin/xcode-select --switch "$dev"
        "$dev/usr/bin/xcodebuild" -license accept
        "$dev/usr/bin/xcodebuild" -runFirstLaunch
        """
        try await runAsAdmin(script, [app], prompt: "AppFast Studio needs your password to finish setting up Xcode.",
                             step: "Setting up Xcode", progress: "Enter your password when asked. Setup then takes a few minutes…")
    }

    private func downloadSimulator(facts: ToolchainFacts) async throws {
        guard let app = facts.xcodeApp else { throw SetupError.unexpected("Set up Xcode first.") }
        let developer = "\(app)/Contents/Developer"
        report(.init(text: "Downloading the iOS Simulator…"))
        try await stream("\(developer)/usr/bin/xcodebuild", ["-downloadPlatform", "iOS"], environment: ["DEVELOPER_DIR": developer],
                         step: "Downloading the iOS Simulator", timeout: 4 * 3600)
    }

    // MARK: Flutter

    /// Downloads the SDK ahead of time while Xcode is still coming from the App Store. Install finds it cached.
    func prefetchFlutter() async throws {
        _ = try await download(FlutterRelease.latestStable(from: fetch(FlutterRelease.feed), arm64: Self.isAppleSilicon))
    }

    private func installFlutter() async throws {
        report(.init(text: "Finding the newest Flutter…"))
        let release = try FlutterRelease.latestStable(from: await fetch(FlutterRelease.feed), arm64: Self.isAppleSilicon)
        let zip = try await download(release)
        report(.init(text: "Unpacking Flutter…"))
        let root = try await unpackFlutter(zip)
        try addToProfile(.path(root + "/bin"))
        try? FileManager.default.removeItem(at: zip)
        // Flutter's first run sets itself up, which would outlast the quick `dart --version` check that follows.
        report(.init(text: "Getting Flutter ready…"))
        try await stream(root + "/bin/flutter", ["--version"], step: "Getting Flutter ready", timeout: 900)
        Self.log.append("Installed \(release.name) in \(root)")
    }

    /// Unpacks into a folder of its own next to the destination, then moves the SDK into place in one step, so
    /// an interrupted unpack never leaves a half-made `flutter` folder that looks installed.
    private func unpackFlutter(_ zip: URL) async throws -> String {
        let fm = FileManager.default
        let parent = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("development")
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let target = (["flutter"] + (2...20).map { "flutter-\($0)" })
            .map { parent.appendingPathComponent($0) }
            .first { !fm.fileExists(atPath: $0.path) }
        guard let target else { throw SetupError.unexpected("~/development already has many flutter folders. Remove the ones you don't need, then try again.") }
        let staging = parent.appendingPathComponent(".mobile-studio-unpacking-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        try await stream("/usr/bin/ditto", ["-x", "-k", zip.path, staging.path], step: "Unpacking Flutter", timeout: 1800)
        let sdk = staging.appendingPathComponent("flutter")
        guard fm.isExecutableFile(atPath: sdk.appendingPathComponent("bin/flutter").path) else {
            throw SetupError.unexpected("The Flutter download didn't contain the Flutter tool. Try again.")
        }
        try fm.moveItem(at: sdk, to: target)
        return target.path
    }

    // MARK: CocoaPods

    private func installCocoaPods(brew existing: String?) async throws {
        var brew = existing
        if brew == nil {
            report(.init(text: "Finding Homebrew…"))
            let package = try await download(HomebrewRelease.installer(from: fetch(HomebrewRelease.feed)))
            // Root copies the package somewhere only root can write and checks it again before installing, so
            // the file can't be swapped between the check here and the install.
            let script = """
            set -e
            dir=$(/usr/bin/mktemp -d /private/tmp/mobile-studio.XXXXXX)
            trap '/bin/rm -rf "$dir"' EXIT
            /bin/cp "$1" "$dir/Homebrew.pkg"
            echo "$2  $dir/Homebrew.pkg" | /usr/bin/shasum -a 256 -c - >/dev/null
            /usr/sbin/installer -pkg "$dir/Homebrew.pkg" -target /
            """
            try await runAsAdmin(script, [package.path, try Self.sha256(of: package)],
                                 prompt: "AppFast Studio needs your password to install Homebrew, which CocoaPods comes from.",
                                 step: "Installing Homebrew", progress: "Enter your password when asked, then Homebrew installs…")
            try? FileManager.default.removeItem(at: package)
            brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
        }
        guard let brew else { throw SetupError.unexpected("Homebrew was installed but can't be found. Try again.") }
        // /usr/local/bin is on every PATH already; Apple silicon's /opt/homebrew isn't until the shell is told.
        if brew.hasPrefix("/opt/homebrew/") { try addToProfile(.brewShellenv(brew: brew)) }
        report(.init(text: "Installing CocoaPods…"))
        try await stream(brew, ["install", "cocoapods"], environment: ["HOMEBREW_NO_ENV_HINTS": "1", "NONINTERACTIVE": "1"],
                         step: "Installing CocoaPods", timeout: 3600)
    }

    // MARK: Downloading

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("MobileStudio", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw SetupError.failed(step: "Checking for the newest version", detail: "the server answered \((response as? HTTPURLResponse)?.statusCode ?? 0).")
            }
            return data
        } catch let error as SetupError {
            throw error
        } catch {
            throw SetupError.failed(step: "Checking for the newest version", detail: "\(error.localizedDescription) Check your internet connection.")
        }
    }

    /// Downloads into the app's cache, resuming a partial file, and returns it only once its SHA-256 matches.
    private func download(_ file: VerifiedDownload) async throws -> URL {
        let fm = FileManager.default
        let folder = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("AppFast Studio/Downloads")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(file.fileName)
        if fm.fileExists(atPath: destination.path) {
            report(.init(text: "Checking the \(file.name) download…"))
            if try Self.sha256(of: destination) == file.sha256 { return destination }
            try fm.removeItem(at: destination)
        }
        let partial = folder.appendingPathComponent(file.fileName + ".part")
        // A partial file that is already whole (the app quit before moving it) would make curl's resume fail.
        if fm.fileExists(atPath: partial.path), try Self.sha256(of: partial) == file.sha256 {
            try fm.moveItem(at: partial, to: destination)
            return destination
        }
        report(.init(text: "Downloading \(file.name)…", fraction: 0))
        try await stream("/usr/bin/curl", ["-fL", "--retry", "3", "--progress-bar", "-C", "-", "-o", partial.path, file.url.absoluteString],
                         step: "Downloading \(file.name)", timeout: 3 * 3600, label: "Downloading \(file.name)…")
        report(.init(text: "Checking the \(file.name) download…"))
        guard try Self.sha256(of: partial) == file.sha256 else {
            try? fm.removeItem(at: partial)
            throw SetupError.checksumMismatch(file.name)
        }
        try fm.moveItem(at: partial, to: destination)
        return destination
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Running

    /// Runs a command, passing its progress on. `label` keeps one steady line (a download) instead of the
    /// tool's own last line.
    private func stream(_ executable: String, _ arguments: [String], environment: [String: String] = [:],
                        step: String, timeout: TimeInterval, label: String? = nil) async throws {
        let report = self.report
        var runner = ProcessRunner(timeout: timeout, extraEnvironment: environment)
        runner.onOutput = { chunk in
            let fraction = SetupProgress.fraction(in: chunk)
            if let text = label ?? SetupProgress.lastLine(in: chunk) { report(.init(text: text, fraction: fraction)) }
        }
        let output: ProcessOutput
        do {
            output = try await runner.run(executable, arguments)
        } catch ClaudeCLIError.timedOut {
            Self.log.append("$ \(executable) \(arguments.joined(separator: " "))\ntimed out after \(Int(timeout)) s")
            throw SetupError.failed(step: step, detail: "it took too long and was stopped.")
        }
        record(executable, arguments, output)
        try Task.checkCancellation()
        guard output.status == 0 else { throw SetupError.failed(step: step, detail: Self.reason(output)) }
    }

    private func runAsAdmin(_ script: String, _ arguments: [String], prompt: String, step: String, progress: String) async throws {
        // osascript prints nothing until the script ends, so one line covers the dialog and the work after it.
        report(.init(text: progress))
        let output = try await ProcessRunner(timeout: 3600).run(AdminShell.osascript, AdminShell.arguments(prompt: prompt, script: script, scriptArguments: arguments))
        record("osascript (as administrator)", [step] + arguments, output)
        try Task.checkCancellation()
        if AdminShell.wasCancelled(output) { throw SetupError.cancelledPassword }
        guard output.status == 0 else { throw SetupError.failed(step: step, detail: Self.reason(output)) }
    }

    private func addToProfile(_ entry: ShellProfile.Entry) throws {
        do {
            if let file = try ShellProfile.add(entry) { Self.log.append("Added \(entry) to \(file)") }
        } catch {
            throw SetupError.failed(step: "Adding it to your Terminal's PATH", detail: error.localizedDescription)
        }
    }

    private func checkSpace(for action: SetupAction, facts: ToolchainFacts) throws {
        guard let free = facts.freeBytes ?? ToolchainDetector.freeBytes(), action.bytesNeeded > 0, free < action.bytesNeeded else { return }
        throw SetupError.notEnoughSpace(needed: action.bytesNeeded, free: free)
    }

    private func record(_ executable: String, _ arguments: [String], _ output: ProcessOutput) {
        let text = (output.stdout + "\n" + output.stderr).suffix(20_000)
        Self.log.append("$ \(executable) \(arguments.joined(separator: " "))\nexit \(output.status)\n\(text)")
    }

    /// The last few lines that say something, which is where tools put the reason they stopped.
    static func reason(_ output: ProcessOutput) -> String {
        let lines = (output.stderr + "\n" + output.stdout)
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.allSatisfy { "#=-%. 0123456789".contains($0) } }
        let tail = lines.suffix(2).joined(separator: " ")
        return tail.isEmpty ? "it stopped with status \(output.status)." : tail
    }

    static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }
}
