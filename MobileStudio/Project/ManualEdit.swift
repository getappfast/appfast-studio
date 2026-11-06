import Foundation

/// Reading a file for the diff sheet's editor and saving the user's edit of it, so the save can be undone like
/// one of Claude's changes. Nothing here touches UI state; `Workspace.saveManualEdit` records the result.
enum ManualEdit {
    enum Failure: LocalizedError, Equatable {
        case outsideProject
        /// Claude is changing the project, or another save is running; the text says which.
        case blocked(String)
        case missing(String)
        case notText(String)
        case tooBig(String)
        case changedOnDisk(String)

        var errorDescription: String? {
            switch self {
            case .outsideProject: "That file isn't inside the project."
            case .blocked(let reason): reason
            case .missing(let path): "\(FriendlyName.of(path)) isn't in the project anymore."
            case .notText(let path): "\(FriendlyName.of(path)) isn't plain text, so it can't be edited here."
            case .tooBig(let path):
                "\(FriendlyName.of(path)) is too big to edit here, because the edit couldn't be undone. Open it in your code editor instead."
            case .changedOnDisk(let path):
                "\(FriendlyName.of(path)) changed on disk after you opened it. Close and reopen it to see the latest, then make your edit again."
            }
        }
    }

    struct Saved: Equatable, Sendable {
        /// Empty when the text was the same as the file's.
        let changes: [FileSnapshot.Change]
        /// The original was kept, so the edit can be undone.
        let isUndoable: Bool
    }

    /// The file's text, for the editor.
    static func text(of path: String, in folder: String) async throws -> String {
        try await Task.detached { try read(path, in: folder) }.value
    }

    /// Writes `content` over the file. Takes a snapshot of the folder before and after, and keeps a checkpoint under
    /// `checkpoint` so Undo can put the original back. Nothing is written when the file no longer holds `original`,
    /// the text the editor was opened with: that would overwrite an edit made somewhere else.
    static func save(_ content: String, to path: String, in folder: String, replacing original: String?,
                     checkpoint id: UUID) async throws -> Saved {
        let (url, relative) = try resolve(path, in: folder)
        let current = try await Task.detached { try read(path, in: folder) }.value
        if let original, current != original { throw Failure.changedOnDisk(relative) }

        let before = await FileSnapshot.taken(of: folder, keepingContents: true)
        let mode = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
        try Data(content.utf8).write(to: url, options: .atomic)
        // An atomic write makes a new file, which would drop a script's executable bit.
        if let mode { try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path) }
        let after = await FileSnapshot.taken(of: folder)

        // Only this file: a build running in the background may touch others while the snapshots are taken.
        let changes = after.changes(since: before).filter { $0.path == relative }
        guard !changes.isEmpty else { return Saved(changes: [], isUndoable: false) }
        let kept = CheckpointStore.save(id: id, folder: folder, changes: changes, before: before, after: after)
        return Saved(changes: changes, isUndoable: kept)
    }

    /// The file inside the project and its path relative to the folder, as snapshots name it.
    static func resolve(_ path: String, in folder: String) throws -> (url: URL, relative: String) {
        let root = URL(fileURLWithPath: folder).standardizedFileURL
        let url = root.appendingPathComponent(path).standardizedFileURL
        guard url.path.hasPrefix(root.path + "/") else { throw Failure.outsideProject }
        return (url, String(url.path.dropFirst(root.path.count + 1)))
    }

    private static func read(_ path: String, in folder: String) throws -> String {
        let (url, relative) = try resolve(path, in: folder)
        guard let data = try? Data(contentsOf: url) else { throw Failure.missing(relative) }
        guard data.count <= FileSnapshot.undoLimit else { throw Failure.tooBig(relative) }
        guard let text = String(data: data, encoding: .utf8) else { throw Failure.notText(relative) }
        return text
    }
}
