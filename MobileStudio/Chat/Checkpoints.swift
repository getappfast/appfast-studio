import Foundation

/// What a Claude turn changed, saved so it can be undone: the files as they were before, and a fingerprint
/// of each as Claude left it, so an undo never overwrites an edit made since.
enum CheckpointStore {
    enum Failure: LocalizedError, Equatable {
        case changedSince(String)
        case missing

        var errorDescription: String? {
            switch self {
            case .changedSince(let path): "\(FriendlyName.of(path)) changed after Claude edited it, so it wasn't undone."
            case .missing: "This change can no longer be undone."
            }
        }
    }

    private struct Manifest: Codable {
        struct Entry: Codable {
            let path: String
            let kind: FileSnapshot.Change.Kind
            /// The file as Claude left it; nil when Claude deleted it.
            let after: String?
            /// The saved original, under the checkpoint's folder; nil when Claude added the file.
            let backup: String?
        }
        let entries: [Entry]
    }

    /// Saves a checkpoint. Returns false when a changed file was too big to keep, so it couldn't be undone.
    @discardableResult
    static func save(id: UUID, folder: String, changes: [FileSnapshot.Change],
                     before: FileSnapshot, after: FileSnapshot) -> Bool {
        let directory = url(id, folder)
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var entries: [Manifest.Entry] = []
        for (index, change) in changes.enumerated() {
            var backup: String?
            if change.kind != .added {
                guard let data = before.contents[change.path] else {
                    try? fm.removeItem(at: directory)
                    return false
                }
                backup = "\(index).bak"
                guard (try? data.write(to: directory.appendingPathComponent("\(index).bak"))) != nil else {
                    try? fm.removeItem(at: directory)
                    return false
                }
            }
            entries.append(.init(path: change.path, kind: change.kind, after: after.fingerprint(of: change.path), backup: backup))
        }
        guard let data = try? JSONEncoder().encode(Manifest(entries: entries)),
              (try? data.write(to: directory.appendingPathComponent("manifest.json"))) != nil else { return false }
        return true
    }

    /// Puts the files back as they were before the turn. Checks every file first and changes nothing when
    /// one was edited since. Returns the files it restored.
    static func restore(id: UUID, folder: String) throws -> [FileSnapshot.Change] {
        let directory = url(id, folder)
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { throw Failure.missing }
        let root = URL(fileURLWithPath: folder)
        let fm = FileManager.default

        for entry in manifest.entries {
            let current = (try? Data(contentsOf: root.appendingPathComponent(entry.path))).map(FileSnapshot.hash)
            // Files too big to hash were fingerprinted by size and date; those can only be checked for existence.
            let comparable = entry.after.map { $0.count == 64 } ?? true
            if comparable ? current != entry.after : current == nil { throw Failure.changedSince(entry.path) }
        }
        var restored: [FileSnapshot.Change] = []
        for entry in manifest.entries {
            let target = root.appendingPathComponent(entry.path)
            if let backup = entry.backup {
                let original = try Data(contentsOf: directory.appendingPathComponent(backup))
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try original.write(to: target, options: .atomic)
                restored.append(.init(path: entry.path, kind: entry.kind == .deleted ? .added : .modified))
            } else {
                try? fm.removeItem(at: target)
                restored.append(.init(path: entry.path, kind: .deleted))
            }
        }
        try? fm.removeItem(at: directory)
        return restored
    }

    static func discardAll(folder: String) {
        try? FileManager.default.removeItem(at: ProjectStorage.directory("Checkpoints", for: folder))
    }

    private static func url(_ id: UUID, _ folder: String) -> URL {
        ProjectStorage.directory("Checkpoints", for: folder).appendingPathComponent(id.uuidString)
    }
}
