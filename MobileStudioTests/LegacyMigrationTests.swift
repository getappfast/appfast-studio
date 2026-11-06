import Foundation
import Testing
@testable import AppFast_Studio

struct LegacyMigrationTests {
    private func library() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func defaults() -> UserDefaults {
        let name = "migration-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        return suite
    }

    @Test func movesOldFoldersAndKeepsTheOldPathWorking() throws {
        let lib = try library()
        let fm = FileManager.default
        let old = lib.appendingPathComponent("Application Support/Mobile Studio/Profiles/abc")
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try "login".write(to: old.appendingPathComponent("token"), atomically: true, encoding: .utf8)
        try fm.createDirectory(at: lib.appendingPathComponent("Logs/Mobile Studio"), withIntermediateDirectories: true)

        let report = LegacyMigration.run(library: lib, defaults: defaults(), oldSettings: nil)

        #expect(report.movedFolders == ["Application Support", "Logs"])
        #expect(fm.fileExists(atPath: lib.appendingPathComponent("Application Support/AppFast Studio/Profiles/abc/token").path))
        // A saved account's absolute path under the old name still reaches the same files.
        #expect(fm.fileExists(atPath: old.appendingPathComponent("token").path))
        #expect(!fm.fileExists(atPath: lib.appendingPathComponent("Logs/Mobile Studio").path))
    }

    @Test func isIdempotentAndNeverReplacesANewFolder() throws {
        let lib = try library()
        let fm = FileManager.default
        try fm.createDirectory(at: lib.appendingPathComponent("Application Support/Mobile Studio"), withIntermediateDirectories: true)
        let first = LegacyMigration.run(library: lib, defaults: defaults(), oldSettings: nil)
        let second = LegacyMigration.run(library: lib, defaults: defaults(), oldSettings: nil)
        #expect(first.movedFolders == ["Application Support"])
        #expect(second.movedFolders.isEmpty)

        let lib2 = try library()
        try fm.createDirectory(at: lib2.appendingPathComponent("Logs/Mobile Studio"), withIntermediateDirectories: true)
        try fm.createDirectory(at: lib2.appendingPathComponent("Logs/AppFast Studio"), withIntermediateDirectories: true)
        #expect(LegacyMigration.run(library: lib2, defaults: defaults(), oldSettings: nil).movedFolders.isEmpty)
        #expect(fm.fileExists(atPath: lib2.appendingPathComponent("Logs/Mobile Studio").path))
    }

    @Test func copiesOldSettingsOnceWithoutOverwriting() throws {
        let lib = try library()
        let store = defaults()
        store.set("new", forKey: "kept")
        let old: [String: Any] = ["kept": "old", "device.selected.v2": "ios:ABC"]

        let report = LegacyMigration.run(library: lib, defaults: store, oldSettings: old)
        #expect(report.copiedSettings == 1)
        #expect(store.string(forKey: "kept") == "new")
        #expect(store.string(forKey: "device.selected.v2") == "ios:ABC")

        store.removeObject(forKey: "device.selected.v2")
        #expect(LegacyMigration.run(library: lib, defaults: store, oldSettings: old).copiedSettings == 0)
        #expect(store.object(forKey: "device.selected.v2") == nil)
    }
}
