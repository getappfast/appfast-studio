import AppKit

/// Appends plain-text entries to ~/Library/Logs/Mobile Studio/<name>.log so a failed run can be inspected.
struct DiagnosticLog: Sendable {
    let name: String

    var url: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Mobile Studio/\(name).log")
    }

    func append(_ entry: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("[\(stamp)] \(entry)\n\n".utf8)
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    /// Shows the log in Finder, or the logs folder when nothing has been written yet.
    @MainActor
    func reveal() {
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            let folder = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        }
    }
}
