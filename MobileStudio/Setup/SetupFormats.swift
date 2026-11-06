import Foundation

/// A file to download and the SHA-256 it must have.
struct VerifiedDownload: Equatable, Sendable {
    let url: URL
    let sha256: String
    /// Shown while it downloads, e.g. "Flutter 3.47.9".
    let name: String

    var fileName: String { url.lastPathComponent }
}

/// Flutter's official release feed (`releases_macos.json`): the newest stable SDK for this Mac's processor.
enum FlutterRelease {
    static let feed = URL(string: "https://storage.googleapis.com/flutter_infra_release/releases/releases_macos.json")!

    private struct Feed: Decodable {
        struct Current: Decodable { let stable: String }
        struct Release: Decodable {
            let hash: String
            let channel: String
            let version: String
            let dart_sdk_arch: String?
            let archive: String
            let sha256: String
        }
        let base_url: String
        let current_release: Current
        let releases: [Release]
    }

    static func latestStable(from data: Data, arm64: Bool) throws -> VerifiedDownload {
        let feed = try JSONDecoder().decode(Feed.self, from: data)
        let arch = arm64 ? "arm64" : "x64"
        let candidates = feed.releases.filter { $0.hash == feed.current_release.stable && $0.channel == "stable" }
        // Releases before Apple silicon builds have no arch field; those are Intel.
        guard let release = candidates.first(where: { ($0.dart_sdk_arch ?? "x64") == arch }),
              let url = URL(string: feed.base_url + "/" + release.archive) else {
            throw SetupError.unexpected("Flutter's release list has no stable download for this Mac.")
        }
        return VerifiedDownload(url: url, sha256: release.sha256.lowercased(), name: "Flutter \(release.version)")
    }
}

/// Homebrew's signed installer package from its latest GitHub release. The digest comes from the same release.
enum HomebrewRelease {
    static let feed = URL(string: "https://api.github.com/repos/Homebrew/brew/releases/latest")!

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
            let digest: String?
        }
        let tag_name: String
        let assets: [Asset]
    }

    static func installer(from data: Data) throws -> VerifiedDownload {
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard let asset = release.assets.first(where: { $0.name.hasSuffix(".pkg") }),
              let digest = asset.digest, digest.hasPrefix("sha256:"),
              let url = URL(string: asset.browser_download_url), url.host == "github.com" else {
            throw SetupError.unexpected("Homebrew's latest release has no installer package to check.")
        }
        return VerifiedDownload(url: url, sha256: String(digest.dropFirst("sha256:".count)).lowercased(),
                                name: "Homebrew \(release.tag_name)")
    }
}

/// Reads progress out of what the installers print, so the checklist can show a bar instead of a spinner.
enum SetupProgress {
    /// The last percentage in a chunk of output: curl's `###   42.0%`, xcodebuild's `Downloading …: 42.0% (…)`.
    static func fraction(in text: String) -> Double? {
        guard let last = text.matches(of: /(\d{1,3}(?:\.\d+)?)\s?%/).last, let value = Double(last.output.1),
              (0...100).contains(value) else { return nil }
        return value / 100
    }

    /// The last line worth showing: progress bars redraw with \r, so split on both and skip the bar itself.
    static func lastLine(in text: String) -> String? {
        text.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { line in !line.isEmpty && !line.allSatisfy { "#=-%. 0123456789".contains($0) } }
            .map { $0.count > 120 ? String($0.prefix(119)) + "…" : $0 }
    }
}

/// Runs a script as root through macOS's own password dialog (`do shell script … with administrator privileges`).
/// AppFast Studio never sees the password. The script text and its arguments travel as osascript arguments and are
/// quoted by AppleScript, never spliced into the command; the script is inline, so no file can be swapped under it.
enum AdminShell {
    static let osascript = "/usr/bin/osascript"

    static func arguments(prompt: String, script: String, scriptArguments: [String]) -> [String] {
        let source = [
            "on run argv",
            "set theCommand to \"/bin/sh -c \" & quoted form of (item 2 of argv) & \" sh\"",
            "repeat with i from 3 to count of argv",
            "set theCommand to theCommand & \" \" & quoted form of (item i of argv)",
            "end repeat",
            "do shell script theCommand with prompt (item 1 of argv) with administrator privileges",
            "end run",
        ]
        return source.flatMap { ["-e", $0] } + [prompt, script] + scriptArguments
    }

    /// osascript reports a closed password dialog as error -128.
    static func wasCancelled(_ output: ProcessOutput) -> Bool {
        output.stderr.contains("(-128)") || output.stderr.contains("User canceled")
    }
}

enum SetupError: Error, LocalizedError, Equatable {
    case cancelledPassword
    case notEnoughSpace(needed: Int64, free: Int64)
    case checksumMismatch(String)
    case failed(step: String, detail: String)
    case unexpected(String)

    var errorDescription: String? {
        switch self {
        case .cancelledPassword:
            "The password prompt was closed. Click Try Again when you're ready."
        case .notEnoughSpace(let needed, let free):
            "This needs about \(Self.size(needed)) free, and your Mac has \(Self.size(free)). Free up some space, then try again."
        case .checksumMismatch(let name):
            "The \(name) download was damaged, so it wasn't used. Try again."
        case .failed(let step, let detail):
            "\(step) didn't work: \(detail)"
        case .unexpected(let message):
            message
        }
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
