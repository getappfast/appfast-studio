import Foundation
import Testing
@testable import Mobile_Studio

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
