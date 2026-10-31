import Foundation

struct DartInstall: Equatable, Sendable {
    let path: String
    let version: String
    let channel: String?
    /// True when the user's login shell resolves `dart`, so terminals and build tools find it too.
    let onPath: Bool
    /// Set when this Dart is the one bundled inside a Flutter SDK.
    let flutterRoot: String?

    var binDirectory: String { (path as NSString).deletingLastPathComponent }
}

enum DartState: Equatable, Sendable {
    case checking
    case notInstalled
    case failed(String)
    case installed(DartInstall)
}

struct DartSDKService: Sendable {
    var runner = ProcessRunner(timeout: 20)

    func detect() async -> DartState {
        let onPath = await locateViaLoginShell()
        guard let path = onPath ?? locateInKnownPlaces() else { return .notInstalled }

        do {
            let out = try await runner.run(path, ["--version"])
            // Older SDKs print the version on stderr, newer ones on stdout.
            let text = out.stdout + "\n" + out.stderr
            guard out.status == 0, let parsed = Self.parseVersion(text) else {
                return .failed(out.failureDetail(fallback: "`dart --version` produced no version."))
            }
            return .installed(DartInstall(
                path: path, version: parsed.version, channel: parsed.channel,
                onPath: onPath != nil, flutterRoot: Self.flutterRoot(for: path)
            ))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: Locating

    /// A GUI app launched from Finder has a minimal PATH, so ask the user's login shell what
    /// `dart` means in their terminal. That is also what "configured" means here.
    private func locateViaLoginShell() async -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard let out = try? await ProcessRunner(timeout: 15).run(shell, ["-ilc", "command -v dart"]) else { return nil }
        // rc files may print noise; the answer is the last absolute path line.
        let line = out.stdout
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") }
        guard let line, FileManager.default.isExecutableFile(atPath: line) else { return nil }
        return line
    }

    /// Installed but invisible to the shell: common places for a standalone Dart or a Flutter checkout.
    private func locateInKnownPlaces() -> String? {
        let home = NSHomeDirectory()
        var roots = [
            "/opt/homebrew/bin", "/usr/local/bin",
            "\(home)/flutter/bin", "\(home)/development/flutter/bin", "\(home)/sdk/flutter/bin",
            "\(home)/dev/flutter/bin", "\(home)/dev/sdk/flutter/bin", "\(home)/fvm/default/bin",
            "/usr/local/flutter/bin", "\(home)/.puro/envs/stable/flutter/bin",
        ]
        if let sdk = ProcessInfo.processInfo.environment["DART_SDK"] { roots.insert("\(sdk)/bin", at: 0) }
        if let flutter = ProcessInfo.processInfo.environment["FLUTTER_ROOT"] { roots.insert("\(flutter)/bin", at: 0) }
        return roots.map { "\($0)/dart" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: Parsing

    /// "Dart SDK version: 3.12.2 (stable) (Tue Jun 9 …) on "macos_arm64""
    static func parseVersion(_ text: String) -> (version: String, channel: String?)? {
        guard let match = text.firstMatch(of: /Dart SDK version: (\S+)(?: \(([A-Za-z]+)\))?/) else { return nil }
        return (String(match.1), match.2.map(String.init))
    }

    /// The Flutter SDK root when `path` is the Dart launcher inside one (it sits beside `flutter`).
    static func flutterRoot(for path: String) -> String? {
        let bin = URL(fileURLWithPath: path).resolvingSymlinksInPath().deletingLastPathComponent()
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: bin.appendingPathComponent("flutter").path) else { return nil }
        return bin.deletingLastPathComponent().path
    }
}
