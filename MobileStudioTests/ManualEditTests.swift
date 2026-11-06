import Foundation
import Testing
@testable import AppFast_Studio

struct ManualEditTests {
    private func project() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("lib"), withIntermediateDirectories: true)
        return root
    }

    private func write(_ text: String, _ path: String, in root: URL) throws {
        try Data(text.utf8).write(to: root.appendingPathComponent(path))
    }

    private func read(_ path: String, in root: URL) -> String? {
        (try? Data(contentsOf: root.appendingPathComponent(path))).map { String(decoding: $0, as: UTF8.self) }
    }

    @Test func savesTheTextAndKeepsACheckpointThatUndoesIt() async throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root); CheckpointStore.discardAll(folder: root.path) }
        try write("old", "lib/a.dart", in: root)
        try write("untouched", "lib/b.dart", in: root)

        let id = UUID()
        let saved = try await ManualEdit.save("new", to: "lib/a.dart", in: root.path, replacing: "old", checkpoint: id)
        #expect(saved == .init(changes: [.init(path: "lib/a.dart", kind: .modified)], isUndoable: true))
        #expect(read("lib/a.dart", in: root) == "new")

        let restored = try CheckpointStore.restore(id: id, folder: root.path)
        #expect(restored == [.init(path: "lib/a.dart", kind: .modified)])
        #expect(read("lib/a.dart", in: root) == "old")
        #expect(read("lib/b.dart", in: root) == "untouched")
    }

    @Test func oldCheckpointsStayValidAndNeverOverwriteALaterEdit() async throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root); CheckpointStore.discardAll(folder: root.path) }
        try write("original", "lib/a.dart", in: root)
        let before = FileSnapshot.take(of: root.path, keepingContents: true)
        try write("claude's version", "lib/a.dart", in: root)
        let after = FileSnapshot.take(of: root.path)
        let claude = UUID()
        CheckpointStore.save(id: claude, folder: root.path, changes: after.changes(since: before), before: before, after: after)

        let hand = UUID()
        _ = try await ManualEdit.save("my tweak", to: "lib/a.dart", in: root.path, replacing: "claude's version", checkpoint: hand)

        // Claude's answer can't be undone around the tweak: that would lose it.
        #expect(throws: CheckpointStore.Failure.changedSince("lib/a.dart")) {
            try CheckpointStore.restore(id: claude, folder: root.path)
        }
        #expect(read("lib/a.dart", in: root) == "my tweak")
        // Newest first, as Workspace.undo does: the tweak, then Claude's answer.
        _ = try CheckpointStore.restore(id: hand, folder: root.path)
        #expect(read("lib/a.dart", in: root) == "claude's version")
        _ = try CheckpointStore.restore(id: claude, folder: root.path)
        #expect(read("lib/a.dart", in: root) == "original")
    }

    @Test func savingTheSameTextChangesNothingAndKeepsNoCheckpoint() async throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root); CheckpointStore.discardAll(folder: root.path) }
        try write("same", "lib/a.dart", in: root)
        let id = UUID()
        let saved = try await ManualEdit.save("same", to: "lib/a.dart", in: root.path, replacing: "same", checkpoint: id)
        #expect(saved == .init(changes: [], isUndoable: false))
        #expect(throws: CheckpointStore.Failure.missing) { try CheckpointStore.restore(id: id, folder: root.path) }
    }

    @Test func refusesWhenTheFileChangedSinceItWasOpened() async throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root); CheckpointStore.discardAll(folder: root.path) }
        try write("someone else's edit", "lib/a.dart", in: root)
        await #expect(throws: ManualEdit.Failure.changedOnDisk("lib/a.dart")) {
            try await ManualEdit.save("mine", to: "lib/a.dart", in: root.path, replacing: "what I opened", checkpoint: UUID())
        }
        #expect(read("lib/a.dart", in: root) == "someone else's edit")
    }

    @Test func onlyThisFileGoesIntoTheCheckpoint() async throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root); CheckpointStore.discardAll(folder: root.path) }
        try write("old", "lib/a.dart", in: root)
        let saved = try await ManualEdit.save("new", to: "./lib/../lib/a.dart", in: root.path, replacing: nil, checkpoint: UUID())
        #expect(saved.changes.map(\.path) == ["lib/a.dart"])
    }

    @Test func keepsAScriptsExecutableBit() async throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root); CheckpointStore.discardAll(folder: root.path) }
        try write("#!/bin/sh\necho old\n", "lib/run.sh", in: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("lib/run.sh").path)
        _ = try await ManualEdit.save("#!/bin/sh\necho new\n", to: "lib/run.sh", in: root.path, replacing: nil, checkpoint: UUID())
        let mode = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("lib/run.sh").path)[.posixPermissions] as? Int
        #expect(mode == 0o755)
    }

    @Test func refusesFilesItCannotUndoOrCannotReadAsText() async throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root); CheckpointStore.discardAll(folder: root.path) }
        try Data(repeating: 0x61, count: FileSnapshot.undoLimit + 1).write(to: root.appendingPathComponent("lib/big.txt"))
        try Data([0xFF, 0xFE, 0x00, 0xC3, 0x28]).write(to: root.appendingPathComponent("lib/binary.bin"))

        await #expect(throws: ManualEdit.Failure.tooBig("lib/big.txt")) { try await ManualEdit.text(of: "lib/big.txt", in: root.path) }
        await #expect(throws: ManualEdit.Failure.notText("lib/binary.bin")) { try await ManualEdit.text(of: "lib/binary.bin", in: root.path) }
        await #expect(throws: ManualEdit.Failure.missing("lib/nope.dart")) { try await ManualEdit.text(of: "lib/nope.dart", in: root.path) }
        await #expect(throws: ManualEdit.Failure.tooBig("lib/big.txt")) {
            try await ManualEdit.save("x", to: "lib/big.txt", in: root.path, replacing: nil, checkpoint: UUID())
        }
    }

    @Test func staysInsideTheProject() async throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: ManualEdit.Failure.outsideProject) { try await ManualEdit.text(of: "../outside.txt", in: root.path) }
        await #expect(throws: ManualEdit.Failure.outsideProject) {
            try await ManualEdit.save("x", to: "lib/../../outside.txt", in: root.path, replacing: nil, checkpoint: UUID())
        }
        #expect(try ManualEdit.resolve("lib/a.dart", in: root.path).relative == "lib/a.dart")
    }
}

@MainActor
struct WorkspaceEditTests {
    private func workspace() -> Workspace {
        Workspace(studio: StudioModel())
    }

    @Test func titlesTheMenuAfterTheEditorOrFallsBack() {
        let workspace = workspace()
        // Whatever this machine has installed, the title is one of the two forms.
        if let editor = workspace.editor {
            #expect(workspace.editorTitle == "Open in \(editor.name)")
        } else {
            #expect(workspace.editorTitle == "Open Code")
        }
    }
}
