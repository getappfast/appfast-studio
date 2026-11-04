import AppKit
import Foundation
import Testing
@testable import Mobile_Studio

struct DesignReferencesTests {
    /// A scratch folder for one test, removed when the test ends.
    private func scratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A small JPEG on disk, the kind of file a screenshot tool or a browser saves.
    private func jpeg(in folder: URL) throws -> URL {
        let image = NSImage(size: NSSize(width: 12, height: 8))
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: 12, height: 8).fill()
        image.unlockFocus()
        let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let data = try #require(bitmap.representation(using: .jpeg, properties: [:]))
        let url = folder.appendingPathComponent("shot.jpg")
        try data.write(to: url)
        return url
    }

    @Test func savesAPictureAsPNGInTheFolder() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try jpeg(in: folder)
        let references = folder.appendingPathComponent("References")

        let saved = try #require(DesignReferences.save(source, to: references))

        #expect(saved.deletingLastPathComponent().path == references.path)
        #expect(saved.pathExtension == "png")
        let bytes = try Data(contentsOf: saved).prefix(4)
        #expect(Array(bytes) == [0x89, 0x50, 0x4E, 0x47])
    }

    @Test func leavesOutFilesThatArentPictures() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let notes = folder.appendingPathComponent("notes.txt")
        try Data("not a picture".utf8).write(to: notes)

        #expect(DesignReferences.save(notes, to: folder.appendingPathComponent("References")) == nil)
    }

    @Test func turnsTheReferencesIntoInstructions() {
        let turn = DesignTurn(kind: .freeform, request: "Make it like this", references: ["/tmp/refs/one.png"])
        let text = DesignPrompts.instructions(for: turn, style: nil, tokens: nil, issues: [])

        #expect(text.contains("/tmp/refs/one.png"))
        #expect(text.contains("Read it with the Read tool"))
    }

    @Test func noReferencesAddsNothing() {
        let turn = DesignTurn(kind: .freeform, request: "Hello")
        let text = DesignPrompts.instructions(for: turn, style: nil, tokens: nil, issues: [])

        #expect(!text.contains("reference"))
    }
}
