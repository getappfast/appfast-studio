import Foundation
import Testing
@testable import Mobile_Studio

struct FileSnapshotTests {
    @Test func listsAddedModifiedAndDeletedFilesButNotBuildOutput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ path: String, _ text: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try write("lib/main.dart", "void main() {}")
        try write("lib/old.dart", "old")
        let before = FileSnapshot.take(of: root.path)

        try write("lib/main.dart", "void main() { run(); }")
        try write("lib/new.dart", "new")
        try FileManager.default.removeItem(at: root.appendingPathComponent("lib/old.dart"))
        try write("build/app.o", "binary")
        try write(".dart_tool/cache", "x")

        let changes = FileSnapshot.take(of: root.path).changes(since: before)
        #expect(changes == [
            .init(path: "lib/main.dart", kind: .modified),
            .init(path: "lib/new.dart", kind: .added),
            .init(path: "lib/old.dart", kind: .deleted),
        ])
    }
}

struct ExtensionsTests {
    private struct Sample: Codable, Equatable { let name: String }

    @Test func nonEmpty() {
        #expect("".nonEmpty == nil)
        #expect("a".nonEmpty == "a")
    }

    @Test func userDefaultsRoundTripsCodableValues() throws {
        let suite = "MobileStudioTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.setEncoded(Sample(name: "x"), forKey: "k")
        #expect(defaults.decoded(Sample.self, forKey: "k") == Sample(name: "x"))
        defaults.setEncoded(Sample?.none, forKey: "k")
        #expect(defaults.decoded(Sample.self, forKey: "k") == nil)
    }
}
