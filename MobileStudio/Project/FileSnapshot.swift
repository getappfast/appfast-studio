import Foundation
import CryptoKit

/// What a project folder looked like at one moment, so what Claude changed can be listed from the
/// files themselves rather than from Claude's own account of it.
struct FileSnapshot: Sendable {
    private let entries: [String: String]
    /// File contents, kept only when asked for, so a change can be undone. Large files are left out.
    let contents: [String: Data]

    struct Change: Equatable, Sendable, Identifiable, Codable {
        enum Kind: String, Sendable, Codable { case modified, added, deleted }
        let path: String
        let kind: Kind
        var id: String { path }
    }

    /// Build output, caches and tool-generated files that change on every build.
    private static let skippedDirectories: Set<String> = [
        ".git", ".dart_tool", "build", ".gradle", "Pods", ".symlinks", "ephemeral",
        "DerivedData", ".idea", "node_modules", ".fvm", ".pub-cache", ".plugin_symlinks",
    ]
    private static let skippedFiles: Set<String> = [
        ".DS_Store", ".flutter-plugins", ".flutter-plugins-dependencies", "Generated.xcconfig",
        "flutter_export_environment.sh", "GeneratedPluginRegistrant.swift", "GeneratedPluginRegistrant.h",
        "GeneratedPluginRegistrant.m", "generated_plugin_registrant.dart", "local.properties",
    ]
    private static let hashLimit = 2_000_000
    /// Files bigger than this aren't kept for undo; a change to one can't be undone.
    static let undoLimit = 1_000_000

    /// Takes a snapshot off the main actor: walking and hashing a project takes a moment.
    static func taken(of folder: String, keepingContents: Bool = false) async -> FileSnapshot {
        await Task.detached { take(of: folder, keepingContents: keepingContents) }.value
    }

    static func take(of folder: String, keepingContents: Bool = false) -> FileSnapshot {
        // The enumerator reports fully resolved paths (/private/var for /var), so walk the realpath of the
        // folder or the relative paths below would be cut at the wrong place. `resolvingSymlinksInPath()`
        // won't do: it strips /private again.
        let root = URL(fileURLWithPath: realpath(folder, nil).map { defer { free($0) }; return String(cString: $0) } ?? folder)
        let prefix = root.path + "/"
        var entries: [String: String] = [:]
        var contents: [String: Data] = [:]
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [], errorHandler: { _, _ in true }
        ) else { return FileSnapshot(entries: [:], contents: [:]) }

        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            let name = url.lastPathComponent
            if values?.isDirectory == true {
                if skippedDirectories.contains(name) { walker.skipDescendants() }
                continue
            }
            if skippedFiles.contains(name) { continue }
            let size = values?.fileSize ?? 0
            guard url.path.hasPrefix(prefix) else { continue }
            let relative = String(url.path.dropFirst(prefix.count))
            if size <= hashLimit, let data = try? Data(contentsOf: url) {
                entries[relative] = Self.hash(data)
                if keepingContents, size <= undoLimit { contents[relative] = data }
            } else {
                // Too big to hash cheaply: size and modification time are enough to notice a change.
                entries[relative] = "\(size)-\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
            }
        }
        return FileSnapshot(entries: entries, contents: contents)
    }

    /// The fingerprint `take` records for a file, or nil when the file isn't in the snapshot.
    func fingerprint(of path: String) -> String? { entries[path] }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func changes(since earlier: FileSnapshot) -> [Change] {
        var result: [Change] = []
        for (path, hash) in entries {
            guard let old = earlier.entries[path] else { result.append(Change(path: path, kind: .added)); continue }
            if old != hash { result.append(Change(path: path, kind: .modified)) }
        }
        for path in earlier.entries.keys where entries[path] == nil { result.append(Change(path: path, kind: .deleted)) }
        return result.sorted { $0.path < $1.path }
    }
}
