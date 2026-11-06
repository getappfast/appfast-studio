import Foundation
import Testing
@testable import AppFast_Studio

struct ClaudeAgentCallTests {
    private func call(_ session: ClaudeAgentCall.Session = .none) -> ClaudeAgentCall {
        ClaudeAgentCall(prompt: "hi", session: session, maxBudgetUSD: 0.5, allowedCommands: ["flutter pub *"])
    }

    @Test func alwaysRunsInSafeModeWithEditsOnly() {
        let arguments = call().arguments
        #expect(arguments.contains("--safe-mode"))
        #expect(arguments.firstIndex(of: "--permission-mode").map { arguments[$0 + 1] } == "acceptEdits")
        #expect(arguments.firstIndex(of: "--tools").map { arguments[$0 + 1] } == "Read,Glob,Grep,Edit,Write,Bash")
    }

    @Test func allowedToolsComeLastBecauseTheFlagIsVariadic() throws {
        let arguments = call().arguments
        let index = try #require(arguments.firstIndex(of: "--allowedTools"))
        #expect(Array(arguments[(index + 1)...]) == ["Read", "Glob", "Grep", "Edit", "Write", "Bash(flutter pub *)"])
    }

    @Test func sessionFlags() {
        #expect(call().arguments.contains("--no-session-persistence"))
        #expect(call(.start(id: "abc")).arguments.contains("--session-id"))
        #expect(call(.resume(id: "abc")).arguments.contains("--resume"))
        #expect(!call(.resume(id: "abc")).arguments.contains("--no-session-persistence"))
    }

    @Test func budgetHasNoTrailingZeros() {
        let arguments = call().arguments
        #expect(arguments.firstIndex(of: "--max-budget-usd").map { arguments[$0 + 1] } == "0.5")
    }
}

struct ClaudeEventsTests {
    @Test func describesToolUseRelativeToTheProject() {
        let line = #"""
        {"type":"assistant","message":{"content":[
          {"type":"text","text":"  Looking.  "},
          {"type":"tool_use","name":"Read","input":{"file_path":"/p/app/lib/main.dart"}},
          {"type":"tool_use","name":"Bash","input":{"command":"flutter pub get"}}
        ]}}
        """#.replacingOccurrences(of: "\n", with: "")
        #expect(ClaudeEvents.items(in: line, folder: "/p/app") == [
            .text("Looking."), .activity("Reading lib/main.dart"), .activity("Running flutter pub get"),
        ])
    }

    @Test func readsTheResultFromTheEnd() throws {
        let lines = [
            #"{"type":"system"}"#,
            #"{"type":"result","is_error":false,"result":"done","total_cost_usd":0.25,"structured_output":{"fixed":true,"rootCause":"r","summary":"s","changes":[],"remainingIssues":[]}}"#,
        ]
        let result = try #require(ClaudeEvents.result(in: lines))
        #expect(!result.isError)
        #expect(result.text == "done")
        #expect(result.cost == 0.25)
        #expect(result.structured(as: FixReport.self)?.fixed == true)
    }

    @Test func noResultInAnUnfinishedStream() {
        #expect(ClaudeEvents.result(in: [#"{"type":"assistant"}"#, "not json"]) == nil)
    }
}
