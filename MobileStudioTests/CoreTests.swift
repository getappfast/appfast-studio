import Foundation
import Testing
@testable import AppFast_Studio

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

struct CodeEditorTests {
    private let folder = "/Users/me/app"
    private let file = "/Users/me/app/lib/home.dart"

    private func editor(_ kind: CodeEditor.Editor.Kind) -> CodeEditor.Editor {
        .init(kind: kind, appURL: URL(fileURLWithPath: "/Applications/\(kind.appName)"))
    }

    @Test func cursorAndVSCodeGoToTheLineWithTheProjectFolder() {
        for kind in [CodeEditor.Editor.Kind.cursor, .vsCode] {
            #expect(editor(kind).arguments(file: file, line: 42, folder: folder) == ["-g", folder, "\(file):42"])
            #expect(editor(kind).arguments(file: file, line: nil, folder: folder) == ["-g", folder, file])
        }
    }

    @Test func zedTakesTheFolderThenFileAndLine() {
        #expect(editor(.zed).arguments(file: file, line: 7, folder: folder) == [folder, "\(file):7"])
        #expect(editor(.zed).arguments(file: file, line: nil, folder: folder) == [folder, file])
    }

    @Test func androidStudioTakesALineFlagBeforeTheFile() {
        #expect(editor(.androidStudio).arguments(file: file, line: 7, folder: folder) == [folder, "--line", "7", file])
        #expect(editor(.androidStudio).arguments(file: file, line: nil, folder: folder) == [folder, file])
    }

    @Test func aLineBelowOneIsLeftOut() {
        #expect(editor(.zed).arguments(file: file, line: 0, folder: folder) == [folder, file])
        #expect(editor(.cursor).arguments(file: file, line: -3, folder: folder) == ["-g", folder, file])
        #expect(editor(.androidStudio).arguments(file: file, line: 0, folder: folder) == [folder, file])
    }

    @Test func eachEditorsCommandLivesInsideItsApp() {
        #expect(editor(.cursor).executable.path == "/Applications/Cursor.app/Contents/Resources/app/bin/cursor")
        #expect(editor(.vsCode).executable.path == "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code")
        #expect(editor(.zed).executable.path == "/Applications/Zed.app/Contents/MacOS/cli")
        #expect(editor(.androidStudio).executable.path == "/Applications/Android Studio.app/Contents/MacOS/studio")
        #expect(editor(.cursor).bundleIdentifier == "com.todesktop.230313mzl4w4u92")
        #expect(editor(.vsCode).bundleIdentifier == "com.microsoft.VSCode")
        #expect(editor(.zed).bundleIdentifier == "dev.zed.Zed")
        #expect(editor(.androidStudio).bundleIdentifier == "com.google.android.studio")
    }

    @Test func prefersTheEarlierEditorWhenSeveralAreInstalled() {
        let installed: Set<CodeEditor.Editor.Kind> = [.androidStudio, .vsCode, .zed]
        let found = CodeEditor.detected(
            appURL: { installed.contains($0) ? URL(fileURLWithPath: "/Applications/\($0.appName)") : nil },
            isExecutable: { _ in true })
        #expect(found?.kind == .vsCode)
        #expect(found?.name == "VS Code")
    }

    @Test func skipsAnAppWhoseCommandIsMissing() {
        // Zed is installed but its command-line tool isn't there, so Android Studio is the one that can be used.
        let found = CodeEditor.detected(
            appURL: { URL(fileURLWithPath: "/Applications/\($0.appName)") },
            isExecutable: { !$0.path.contains("Cursor") && !$0.path.contains("Visual Studio Code") && !$0.path.contains("Zed") })
        #expect(found?.kind == .androidStudio)
    }

    @Test func isNilWhenNoEditorIsInstalled() {
        #expect(CodeEditor.detected(appURL: { _ in nil }, isExecutable: { _ in true }) == nil)
    }

    @Test func projectRelativePathsAreTakenFromTheFolder() {
        #expect(CodeEditor.absolutePath(of: "lib/home.dart", inProject: folder) == file)
        #expect(CodeEditor.absolutePath(of: "/elsewhere/a.dart", inProject: folder) == "/elsewhere/a.dart")
    }
}
