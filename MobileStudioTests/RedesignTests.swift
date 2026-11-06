import Foundation
import Testing
@testable import AppFast_Studio

struct MarkdownBlockTests {
    @Test func splitsHeadingsListsCodeAndParagraphs() {
        let text = """
        ## Summary
        I changed **two** files.
        It builds.

        - lib/main.dart
        2. pubspec.yaml

        ```dart
        void main() {}
        ```
        Done.
        """
        #expect(MarkdownBlock.parse(text) == [
            .heading(level: 2, text: "Summary"),
            .paragraph("I changed **two** files.\nIt builds."),
            .listItem(ordinal: nil, text: "lib/main.dart"),
            .listItem(ordinal: "2.", text: "pubspec.yaml"),
            .code(language: "dart", text: "void main() {}"),
            .paragraph("Done."),
        ])
    }

    @Test func showsAnUnclosedFenceAsCode() {
        #expect(MarkdownBlock.parse("```\nlet x = 1") == [.code(language: nil, text: "let x = 1")])
    }

    @Test func classifiesSteps() {
        #expect(ClaudeStep("Reading lib/main.dart") == .reading)
        #expect(ClaudeStep("Running flutter pub get") == .running)
        #expect(ClaudeStep("Started a new conversation") == .note)
    }
}

struct GitDiffTests {
    @Test func dropsHeadersAndKeepsChangedLines() {
        let diff = """
        diff --git a/lib/a.dart b/lib/a.dart
        index 1..2 100644
        --- a/lib/a.dart
        +++ b/lib/a.dart
        @@ -1,2 +1,2 @@
         keep
        -old
        +new
        """
        #expect(GitDiff.parse(diff).map(\.kind) == [.hunk, .context, .removed, .added])
    }

    @Test func readsWhereAHunkStartsInTheNewFile() {
        #expect(GitDiff.newStartLine(ofHunk: "@@ -12,3 +14,4 @@ class Foo {") == 14)
        #expect(GitDiff.newStartLine(ofHunk: "@@ -1 +1 @@") == 1)
        #expect(GitDiff.newStartLine(ofHunk: "@@ -0,0 +1,20 @@") == 1)
        #expect(GitDiff.newStartLine(ofHunk: "@@ -3,2 +0,0 @@") == 0)
        #expect(GitDiff.newStartLine(ofHunk: "+not a hunk") == nil)
        #expect(GitDiff.newStartLine(ofHunk: "@@ nothing useful @@") == nil)
    }

    @Test func firstChangedLineSkipsTheHunksLeadingContext() {
        let diff = """
        diff --git a/lib/a.dart b/lib/a.dart
        --- a/lib/a.dart
        +++ b/lib/a.dart
        @@ -10,6 +10,6 @@
         one
         two
         three
        -old
        +new
         after
        @@ -40,2 +40,2 @@
        -later
        +later still
        """
        // Three context lines from line 10 put the change on line 13, and the second hunk is not the first change.
        #expect(GitDiff.firstChangedLine(in: GitDiff.parse(diff)) == 13)
        #expect(GitDiff.Result.diff(GitDiff.parse(diff)).firstChangedLine == 13)
    }

    @Test func firstChangedLineOfANewFileAndOfADeletionAtTheTop() {
        let added = GitDiff.parse("""
        diff --git a/lib/new.dart b/lib/new.dart
        new file mode 100644
        --- /dev/null
        +++ b/lib/new.dart
        @@ -0,0 +1,2 @@
        +first
        +second
        """)
        #expect(GitDiff.firstChangedLine(in: added) == 1)
        // A hunk that starts at line 0 (everything above was removed) still points at a real line.
        let removed = GitDiff.parse("""
        --- a/lib/a.dart
        +++ b/lib/a.dart
        @@ -1,2 +0,0 @@
        -gone
        -too
        """)
        #expect(GitDiff.firstChangedLine(in: removed) == 1)
    }

    @Test func firstChangedLineIsNilWithoutAHunk() {
        #expect(GitDiff.firstChangedLine(in: []) == nil)
        #expect(GitDiff.Result.unchanged.firstChangedLine == nil)
        #expect(GitDiff.Result.unavailable("no git").firstChangedLine == nil)
    }
}

@MainActor
struct ChatChangesTests {
    private func outcome(_ files: [FileSnapshot.Change]) -> FixPhase {
        .done(FixOutcome(report: FixReport(fixed: true, rootCause: "r", summary: "s", changes: [], remainingIssues: []),
                         files: files, validated: true, cost: nil))
    }

    private let failure = RunFailure(date: Date(), folder: "/nowhere", deviceID: "d", deviceName: "iPhone",
                                     message: "boom", output: [])

    @Test func combinesChangesAcrossMessages() {
        let chat = ChatModel()
        chat.finishFix(chat.beginFix(failure), with: outcome([.init(path: "a", kind: .added), .init(path: "b", kind: .modified)]))
        chat.finishFix(chat.beginFix(failure), with: outcome([.init(path: "a", kind: .modified), .init(path: "c", kind: .added)]))
        chat.finishFix(chat.beginFix(failure), with: outcome([.init(path: "c", kind: .deleted)]))

        #expect(chat.changedFiles == [.init(path: "a", kind: .added), .init(path: "b", kind: .modified)])
    }

    @Test func fixReportBecomesAMessage() throws {
        let chat = ChatModel()
        let id = chat.beginFix(failure)
        #expect(chat.messages.count == 2)
        #expect(chat.messages.last?.pending == true)

        chat.finishFix(id, with: outcome([]))
        let reply = try #require(chat.messages.last)
        #expect(!reply.pending)
        #expect(reply.text.contains("Fixed and verified"))

        chat.finishFix(chat.beginFix(failure), with: .idle)
        #expect(chat.messages.last?.error == "Cancelled.")
    }
}

/// What the toolbar and menus enable comes from `Workspace`. Before the simulator list has loaded nothing can
/// run, and every disabled action has a reason the user can read.
@MainActor
struct WorkspaceAvailabilityTests {
    @Test func nothingRunsBeforeASimulatorIsKnown() throws {
        let workspace = Workspace(studio: StudioModel())
        workspace.runsAutomaticChecks = false

        #expect(!workspace.canRun)
        #expect(try #require(workspace.runBlocker).hasSuffix("."))
        #expect(!workspace.canStop)
        #expect(!workspace.canHotReload)
        #expect(!workspace.canPick)
        #expect(workspace.activity.text == workspace.runBlocker)
        #expect(!workspace.activity.busy)
    }

    @Test func chatExplainsWhyItCantSend() {
        let workspace = Workspace(studio: StudioModel())
        // The CLI hasn't been looked for yet, so Claude can't be run.
        #expect(workspace.chatBlocker != nil)
        #expect(workspace.fixBlocker != nil)
    }
}
