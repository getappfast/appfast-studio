import Foundation
import Testing
@testable import Mobile_Studio

private func controlRequest(tool: String, input: String, id: String = "r1", reason: String? = nil) -> String {
    let description = reason.map { #","description":"\#($0)""# } ?? ""
    return #"{"type":"control_request","request_id":"\#(id)","request":{"subtype":"can_use_tool","tool_name":"\#(tool)","input":\#(input)\#(description)}}"#
}

private func request(command: String) -> AgentPermissionRequest {
    let input = (try? JSONSerialization.data(withJSONObject: ["command": command])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    return AgentPermissionRequest.parse(controlRequest(tool: "Bash", input: input))!
}

private func json(_ line: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] ?? [:]
}

struct AgentPermissionRequestTests {
    @Test func readsACommandWithClaudesReason() throws {
        let parsed = try #require(AgentPermissionRequest.parse(
            controlRequest(tool: "Bash", input: #"{"command":"dart run build_runner build"}"#, reason: "Regenerate code")))
        #expect(parsed.id == "r1")
        #expect(parsed.action == .command("dart run build_runner build"))
        #expect(parsed.reason == "Regenerate code")
    }

    @Test func takesClaudesReasonFromTheInputWhenTheRequestHasNone() throws {
        let parsed = try #require(AgentPermissionRequest.parse(
            controlRequest(tool: "Bash", input: #"{"command":"pod install","description":"Install pods"}"#)))
        #expect(parsed.reason == "Install pods")
    }

    @Test func readsFilesAndOtherTools() throws {
        #expect(AgentPermissionRequest.parse(controlRequest(tool: "Read", input: #"{"file_path":"/x/a.dart"}"#))?.action == .readFile("/x/a.dart"))
        #expect(AgentPermissionRequest.parse(controlRequest(tool: "Write", input: #"{"file_path":"/x/a.dart"}"#))?.action == .editFile("/x/a.dart"))
        #expect(AgentPermissionRequest.parse(controlRequest(tool: "Grep", input: #"{"pattern":"foo"}"#))?.action == .readFile("foo"))
        #expect(AgentPermissionRequest.parse(controlRequest(tool: "WebFetch", input: "{}"))?.action == .other(tool: "WebFetch"))
        // A shell call with no command can't be judged, so it is never treated as a command.
        #expect(AgentPermissionRequest.parse(controlRequest(tool: "Bash", input: "{}"))?.action == .other(tool: "Bash"))
    }

    @Test func ignoresEverythingElseInTheStream() {
        #expect(AgentPermissionRequest.parse(#"{"type":"assistant","message":{}}"#) == nil)
        #expect(AgentPermissionRequest.parse(#"{"type":"control_request","request_id":"a","request":{"subtype":"hook_callback"}}"#) == nil)
        #expect(AgentPermissionRequest.parse("not json") == nil)
    }

    @Test func allowingEchoesTheInputBack() throws {
        let reply = json(try #require(AgentPermissionRequest.parse(controlRequest(tool: "Bash", input: #"{"command":"flutter clean"}"#))).response(.allow))
        let response = try #require(reply["response"] as? [String: Any])
        #expect(reply["type"] as? String == "control_response")
        #expect(response["subtype"] as? String == "success")
        #expect(response["request_id"] as? String == "r1")
        let body = try #require(response["response"] as? [String: Any])
        #expect(body["behavior"] as? String == "allow")
        #expect((body["updatedInput"] as? [String: Any])?["command"] as? String == "flutter clean")
    }

    @Test func decliningCarriesTheMessage() throws {
        let reply = json(request(command: "pod install").response(.deny("Not now.")))
        let body = try #require((reply["response"] as? [String: Any])?["response"] as? [String: Any])
        #expect(body["behavior"] as? String == "deny")
        #expect(body["message"] as? String == "Not now.")
    }

    @Test func answersRequestsItDoesNotHandleSoTheCLIDoesNotWait() throws {
        let line = #"{"type":"control_request","request_id":"h1","request":{"subtype":"hook_callback"}}"#
        let reply = json(try #require(AgentPermissionRequest.unsupportedResponse(to: line)))
        #expect((reply["response"] as? [String: Any])?["subtype"] as? String == "error")
        #expect((reply["response"] as? [String: Any])?["request_id"] as? String == "h1")
        // A request it does handle gets a real answer instead.
        #expect(AgentPermissionRequest.unsupportedResponse(to: controlRequest(tool: "Bash", input: #"{"command":"ls"}"#)) == nil)
    }

    @Test func notesWhatWasDecided() {
        let request = request(command: "pod install")
        #expect(request.note(for: .allow) == "Allowed: pod install")
        #expect(request.note(for: .deny("x")) == "Declined: pod install")
        #expect(ClaudeStep("Allowed: pod install") == .allowed)
        #expect(ClaudeStep("Declined: pod install") == .declined)
    }
}

struct ApprovalCallTests {
    @Test func anApprovingCallTakesItsPromptOnStdin() throws {
        let call = ClaudeAgentCall(prompt: "fix it", maxBudgetUSD: 1, allowedCommands: ["flutter pub *"], asksForApproval: true)
        let arguments = call.arguments
        #expect(!arguments.contains("fix it"))
        #expect(arguments.first == "-p")
        #expect(arguments.firstIndex(of: "--input-format").map { arguments[$0 + 1] } == "stream-json")
        #expect(arguments.firstIndex(of: "--permission-prompt-tool").map { arguments[$0 + 1] } == "stdio")
        #expect(arguments.last == "Bash(flutter pub *)")
        let message = json(try #require(call.inputMessage))
        #expect(message["type"] as? String == "user")
        #expect((message["message"] as? [String: Any])?["content"] as? String == "fix it")
    }

    @Test func otherCallsAreUnchanged() {
        let call = ClaudeAgentCall(prompt: "hi", maxBudgetUSD: 1, allowedCommands: [])
        #expect(Array(call.arguments.prefix(2)) == ["-p", "hi"])
        #expect(!call.arguments.contains("--permission-prompt-tool"))
        #expect(call.inputMessage == nil)
    }
}

struct AgentPermissionPolicyTests {
    private func verdict(_ command: String, approved: Set<String> = []) -> AgentPermissionPolicy.Verdict {
        AgentPermissionPolicy.verdict(for: request(command: command), approvedCommands: approved)
    }

    @Test(arguments: [
        "dart run build_runner build --delete-conflicting-outputs",
        "flutter pub run build_runner build",
        "flutter build ios --simulator --debug --flavor preprod -t lib/main-preprod.dart",
        "git status", "git -C . log --oneline", "git diff HEAD", "grep -r rm lib",
    ])
    func asksAboutOrdinaryCommands(_ command: String) {
        #expect(verdict(command) == .ask)
    }

    @Test(arguments: [
        "rm -rf build", "cd build && rm -rf x", "FOO=1 rm x", "env rm x", "echo hi | sudo tee x", "sudo pod install",
        "flutter run -d ios", "flutter --verbose run", "git commit -m x", "git -C . push", "git checkout main",
        "bash -c 'rm x'", "ls; rm x", "echo $(rm x)", "/bin/rm x",
    ])
    func refusesWhatTheHardRulesForbid(_ command: String) {
        guard case .refuse = verdict(command) else { Issue.record("\(command) was not refused"); return }
    }

    @Test func aRememberedCommandIsAllowedWithoutAsking() {
        let command = "dart run build_runner build --delete-conflicting-outputs"
        #expect(verdict(command, approved: [command]) == .allow)
        #expect(verdict("  \(command) \n", approved: [command]) == .allow)
        // Only that exact text.
        #expect(verdict(command + " --verbose", approved: [command]) == .ask)
    }

    @Test func aRememberedCommandThatBreaksARuleIsStillRefused() {
        guard case .refuse = verdict("rm -rf build", approved: ["rm -rf build"]) else { Issue.record("not refused"); return }
    }

    @Test func readsAskExceptForCredentials() throws {
        func verdict(_ path: String) -> AgentPermissionPolicy.Verdict {
            AgentPermissionPolicy.verdict(for: AgentPermissionRequest.parse(controlRequest(tool: "Read", input: #"{"file_path":"\#(path)"}"#))!, approvedCommands: [])
        }
        #expect(verdict("/Users/a/.pub-cache/hosted/pub.dev/riverpod-2.0.0/lib/a.dart") == .ask)
        guard case .refuse = verdict("/Users/a/.ssh/id_ed25519") else { Issue.record("ssh key not refused"); return }
        guard case .refuse = verdict("/Users/a/.aws/credentials") else { Issue.record("aws not refused"); return }
    }

    @Test func editsOutsideTheProjectAndUnknownToolsAreRefused() throws {
        for line in [controlRequest(tool: "Write", input: #"{"file_path":"/etc/hosts"}"#), controlRequest(tool: "WebFetch", input: "{}")] {
            let request = try #require(AgentPermissionRequest.parse(line))
            guard case .refuse = AgentPermissionPolicy.verdict(for: request, approvedCommands: []) else { Issue.record("not refused"); return }
        }
    }

    @Test(arguments: [
        ("dart run build_runner build --delete-conflicting-outputs", true),
        ("flutter clean", true),
        ("a && b", false), ("echo $HOME", false), ("ls *", false), ("cat < f", false), ("x; y", false),
        ("rm x", false), ("", false), ("   ", false),
    ])
    func onlyAPlainCommandCanBeRemembered(_ command: String, _ expected: Bool) {
        #expect(AgentPermissionPolicy.canRemember(command) == expected)
    }
}

struct ApprovedCommandStoreTests {
    private func store() -> ApprovedCommandStore {
        ApprovedCommandStore(defaults: UserDefaults(suiteName: "approval-tests-\(UUID().uuidString)")!)
    }

    @Test func remembersPerFolderWithoutDuplicates() {
        let store = store()
        store.add("flutter clean", in: "/a")
        store.add("  flutter clean ", in: "/a")
        store.add("pod install", in: "/b")
        #expect(store.commands(in: "/a") == ["flutter clean"])
        #expect(store.commands(in: "/b") == ["pod install"])
        #expect(store.commands(in: "/c").isEmpty)
    }

    @Test func forgetsOneCommand() {
        let store = store()
        store.add("flutter clean", in: "/a")
        store.add("pod install", in: "/a")
        store.remove("flutter clean", in: "/a")
        #expect(store.commands(in: "/a") == ["pod install"])
        store.remove("pod install", in: "/a")
        #expect(store.commands(in: "/a").isEmpty)
    }
}

@MainActor
struct ApprovalModelTests {
    private func model() -> ApprovalModel {
        ApprovalModel(store: ApprovedCommandStore(defaults: UserDefaults(suiteName: "approval-model-\(UUID().uuidString)")!))
    }

    /// Lets the tasks that were just started run until the model has something to show.
    private func waitForQuestions(_ count: Int, in model: ApprovalModel) async {
        for _ in 0..<200 where model.queue.count < count { await Task.yield() }
    }

    @Test func waitsForTheUserAndPassesOnTheirAnswer() async {
        let model = model()
        let answer = Task { await model.decide(request(command: "pod install"), folder: "/p") }
        await waitForQuestions(1, in: model)
        #expect(model.current?.request.action == .command("pod install"))
        model.answer(.allowOnce)
        #expect(await answer.value == .allow)
        #expect(model.current == nil)
        // Once is once.
        #expect(model.approvedCommands(in: "/p").isEmpty)
    }

    @Test func decliningTellsClaudeNotToWorkAroundIt() async {
        let model = model()
        let answer = Task { await model.decide(request(command: "pod install"), folder: "/p") }
        await waitForQuestions(1, in: model)
        model.answer(.decline)
        #expect(await answer.value == .deny(ApprovalModel.declinedMessage))
    }

    @Test func refusesAndAllowsWithoutBotheringTheUser() async {
        let model = model()
        guard case .deny = await model.decide(request(command: "rm -rf lib"), folder: "/p") else { Issue.record("rm was not refused"); return }
        #expect(model.current == nil)
    }

    @Test func alwaysAllowIsRememberedForThatProjectOnly() async {
        let model = model()
        let command = "dart run build_runner build"
        let first = Task { await model.decide(request(command: command), folder: "/p") }
        await waitForQuestions(1, in: model)
        #expect(model.current?.canAlwaysAllow == true)
        model.answer(.allowAlways)
        #expect(await first.value == .allow)
        #expect(model.approvedCommands(in: "/p") == [command])
        #expect(await model.decide(request(command: command), folder: "/p") == .allow)
        #expect(model.needsUser(request(command: command), folder: "/other"))

        model.forget(command, in: "/p")
        #expect(model.approvedCommands(in: "/p").isEmpty)
        #expect(model.needsUser(request(command: command), folder: "/p"))
    }

    @Test func aCompoundCommandOffersOnlyAllowOnce() async {
        let model = model()
        let answer = Task { await model.decide(request(command: "dart run a && dart run b"), folder: "/p") }
        await waitForQuestions(1, in: model)
        #expect(model.current?.canAlwaysAllow == false)
        // Asking for it anyway still lets this one through, without remembering it.
        model.answer(.allowAlways)
        #expect(await answer.value == .allow)
        #expect(model.approvedCommands(in: "/p").isEmpty)
    }

    @Test func questionsComeOneAtATimeInOrder() async {
        let model = model()
        let first = Task { await model.decide(request(command: "pod install"), folder: "/p") }
        await waitForQuestions(1, in: model)
        let second = Task { await model.decide(request(command: "flutter clean"), folder: "/p") }
        await waitForQuestions(2, in: model)
        #expect(model.current?.request.action == .command("pod install"))
        model.answer(.allowOnce)
        #expect(model.current?.request.action == .command("flutter clean"))
        model.answer(.decline)
        #expect(await first.value == .allow)
        #expect(await second.value == .deny(ApprovalModel.declinedMessage))
    }

    @Test func alwaysAllowAlsoAnswersTheSameQuestionWaitingBehindIt() async {
        let model = model()
        let first = Task { await model.decide(request(command: "flutter clean"), folder: "/p") }
        await waitForQuestions(1, in: model)
        let second = Task { await model.decide(request(command: "flutter clean"), folder: "/p") }
        await waitForQuestions(2, in: model)
        model.answer(.allowAlways)
        #expect(await first.value == .allow)
        #expect(await second.value == .allow)
        #expect(model.current == nil)
    }

    @Test func aStoppedRunTakesItsQuestionDown() async {
        let model = model()
        let answer = Task { await model.decide(request(command: "pod install"), folder: "/p") }
        await waitForQuestions(1, in: model)
        answer.cancel()
        #expect(await answer.value == .deny("Stopped."))
        #expect(model.current == nil)
    }
}

/// Runs the process wrapper against a stand-in for the CLI, which speaks the same protocol: it reads the prompt,
/// asks for permission, reads the answer, reports a result and then waits for its stdin to end.
struct ClaudeStreamProcessApprovalTests {
    private func standIn(in directory: URL) throws -> String {
        let script = """
        #!/bin/sh
        read -r prompt
        printf '%s\\n' "$prompt" > prompt.txt
        printf '%s\\n' '\(controlRequest(tool: "Bash", input: #"{"command":"dart run build_runner build"}"#, reason: "Regenerate code"))'
        read -r answer
        printf '%s\\n' "$answer" > answer.txt
        printf '%s\\n' '{"type":"result","is_error":false,"result":"done"}'
        read -r rest
        echo ended > ended.txt
        """
        let url = directory.appendingPathComponent("claude")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func run(answering decision: AgentPermissionRequest.Decision) async throws -> (answer: [String: Any], prompt: [String: Any], ended: Bool, asked: [AgentPermissionRequest]) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("approval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let call = ClaudeAgentCall(prompt: "fix the build", maxBudgetUSD: 1, allowedCommands: [], asksForApproval: true)
        let process = ClaudeStreamProcess(cliPath: try standIn(in: directory), arguments: [], input: call.inputMessage,
                                          folder: directory.path, environment: [:], timeout: 30)
        let asked = Asked()
        let finished = try await process.run(onLine: { _ in }, onPermission: { request in
            asked.add(request)
            return decision
        })
        #expect(finished.status == 0)
        #expect(ClaudeEvents.result(in: finished.lines)?.text == "done")
        func read(_ name: String) -> [String: Any] {
            json((try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)) ?? "")
        }
        return (read("answer.txt"), read("prompt.txt"), FileManager.default.fileExists(atPath: directory.appendingPathComponent("ended.txt").path), asked.requests)
    }

    private final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [AgentPermissionRequest] = []
        func add(_ request: AgentPermissionRequest) { lock.withLock { all.append(request) } }
        var requests: [AgentPermissionRequest] { lock.withLock { all } }
    }

    @Test func sendsThePromptThenAnswersTheRequestAndEndsTheInput() async throws {
        let result = try await run(answering: .allow)
        #expect((result.prompt["message"] as? [String: Any])?["content"] as? String == "fix the build")
        #expect(result.asked.map(\.action) == [.command("dart run build_runner build")])
        let body = (result.answer["response"] as? [String: Any])?["response"] as? [String: Any]
        #expect(body?["behavior"] as? String == "allow")
        #expect((result.answer["response"] as? [String: Any])?["request_id"] as? String == "r1")
        // The stand-in only ends once its stdin does, as the real CLI does.
        #expect(result.ended)
    }

    @Test func passesOnADecline() async throws {
        let result = try await run(answering: .deny("No thanks."))
        let body = (result.answer["response"] as? [String: Any])?["response"] as? [String: Any]
        #expect(body?["behavior"] as? String == "deny")
        #expect(body?["message"] as? String == "No thanks.")
    }

    @Test func stoppingWhileAQuestionIsOpenReturnsPromptly() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("approval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let process = ClaudeStreamProcess(cliPath: try standIn(in: directory), arguments: [], input: "{}", folder: directory.path,
                                          environment: [:], timeout: 30)
        let sawCancellation = Asked()
        let running = Task {
            try await process.run(onLine: { _ in }, onPermission: { request in
                // Waits for the user, who never answers.
                try? await Task.sleep(for: .seconds(30))
                if Task.isCancelled { sawCancellation.add(request) }
                return .deny("Stopped.")
            })
        }
        try await Task.sleep(for: .milliseconds(500))
        process.cancel()
        let finished = try await running.value
        #expect(finished.status != 0)
        #expect(finished.lines.contains { $0.contains("control_request") })
    }
}
