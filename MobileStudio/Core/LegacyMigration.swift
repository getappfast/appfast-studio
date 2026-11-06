import Foundation

/// Carries a Mobile Studio install over to AppFast Studio: its folders and its saved settings.
///
/// The app changed name and bundle ID, so macOS gives it new folders and a new preferences file. Without this a
/// returning user would find their chats, accounts and project settings gone.
enum LegacyMigration {
    static let oldName = "Mobile Studio"
    static let newName = "AppFast Studio"
    static let oldBundleID = "com.leo.mobilestudio.app"
    static let doneKey = "migration.fromMobileStudio.v1"

    /// The folders under ~/Library that held the old app's files.
    static let libraryFolders = ["Application Support", "Logs", "Caches"]

    /// What a run did, for the log and the tests.
    struct Report: Equatable {
        var movedFolders: [String] = []
        var copiedSettings = 0
    }

    @discardableResult
    static func run(
        library: URL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0],
        defaults: UserDefaults = .standard,
        oldSettings: [String: Any]? = UserDefaults.standard.persistentDomain(forName: oldBundleID)
    ) -> Report {
        var report = Report()
        let fm = FileManager.default

        for folder in libraryFolders {
            let parent = library.appendingPathComponent(folder)
            let old = parent.appendingPathComponent(oldName)
            let new = parent.appendingPathComponent(newName)
            // A symlink at the old path means an earlier run already moved it; an existing new folder is never replaced.
            guard fm.fileExists(atPath: old.path), !isSymlink(old), !fm.fileExists(atPath: new.path) else { continue }
            do {
                try fm.moveItem(at: old, to: new)
                report.movedFolders.append(folder)
                // Saved accounts remember their config folder by absolute path, and the Claude CLI keys the login to
                // that path, so the old path has to keep resolving.
                if folder == "Application Support" {
                    try? fm.createSymbolicLink(atPath: old.path, withDestinationPath: newName)
                }
            } catch {
                DiagnosticLog(name: "migration").append("Could not move \(old.path): \(error.localizedDescription)")
            }
        }

        if !defaults.bool(forKey: doneKey) {
            for (key, value) in oldSettings ?? [:] where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
                report.copiedSettings += 1
            }
            defaults.set(true, forKey: doneKey)
        }
        return report
    }

    private static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }
}
