import Foundation
import CryptoKit
import Observation

struct ChatMessage: Identifiable, Equatable, Codable {
    enum Role: String, Codable { case user, assistant }

    let id: UUID
    let role: Role
    var text: String
    /// What Claude did while answering: reads, edits, commands.
    var activity: [String] = []
    /// Files that differ on disk after this answer, found by comparing before and after.
    var files: [FileSnapshot.Change] = []
    var cost: Double?
    var error: String?
    var pending = false
    /// UI elements the user picked in the running app and attached to this message.
    var references: [String]?
    /// Pictures of those elements, as file names in the thumbnails folder, in the same order.
    var referenceImages: [String?]?
    /// Reference pictures the user attached in the Design window, as file paths.
    var attachments: [String]?
    /// The saved state from before this answer's edits, when they can be undone.
    var checkpointID: UUID?
    /// The edits were undone.
    var undone: Bool?
    /// What the user picked from this answer's choices, once they have.
    var chosen: [String]?
    /// The product plan this answer wrote to PLAN.md.
    var plan: ProductPlan?
    /// The plan milestone (by index) this answer was asked to build.
    var milestone: Int?
    /// The design version this answer was asked to build into the app, as "screen/version".
    var designApply: String?
    let date: Date

    init(role: Role, text: String, pending: Bool = false, references: [String]? = nil) {
        id = UUID()
        self.role = role
        self.text = text
        self.pending = pending
        self.references = references
        date = Date()
    }
}

/// What a chat is for. Kickoff talks an app idea through without touching code; Build changes the project;
/// Design only makes mockups in design/.
enum ChatMode: String, Codable, Equatable, Sendable {
    case build, kickoff, design

    /// An unknown value (from a newer version of the app) reads as build, so a saved chat still loads.
    init(from decoder: Decoder) throws {
        self = ChatMode(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .build
    }
}

/// A chat with Claude Code running in the project folder, as the selected account.
@MainActor
@Observable
final class ChatModel {
    private(set) var messages: [ChatMessage] = []
    private(set) var isSending = false
    private(set) var mode: ChatMode = .build

    /// Which kind of turn a message starts. A plan turn asks for the product plan as structured output.
    enum Turn: Sendable { case normal, plan }

    /// Runs once a turn's process has ended, before the after-snapshot, so files the app writes then (a design's
    /// screen.json) are part of the turn's checkpoint and undone with it.
    typealias Finishing = @MainActor (_ reply: ChatMessage, _ failed: Bool) -> Void

    /// What a design-chat message runs: the app's instructions for the turn, added to the user's words.
    struct DesignCall: Sendable {
        let turn: DesignTurn
        let instructions: String
        let readableFolders: [String]
    }

    /// Which saved conversation this is, besides its folder: the design window keeps its own.
    private let storage: String?

    init(storage: String? = nil, mode: ChatMode = .build) {
        self.storage = storage
        self.mode = mode
        defaultMode = mode
    }

    /// What a fresh conversation starts in.
    private let defaultMode: ChatMode

    @ObservationIgnored private var folder: String?
    /// What the user said about the app in the New Project sheet, for the kickoff system prompt.
    @ObservationIgnored private var kickoffContext: String?
    @ObservationIgnored private var sessionID: String?
    /// Sessions live in one account's config folder, so a conversation can only continue with that account.
    @ObservationIgnored private var sessionProfile: UUID?
    @ObservationIgnored private var process: ClaudeStreamProcess?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var stopRequested = false

    static let log = DiagnosticLog(name: "chat")

    // MARK: Conversation

    /// Shows the saved conversation for a project folder.
    func load(folder: String?) {
        guard folder != self.folder else { return }
        stop()
        self.folder = folder
        messages = []
        sessionID = nil
        sessionProfile = nil
        mode = defaultMode
        kickoffContext = nil
        guard let folder, let stored = Self.read(folder: folder, storage: storage) else { return }
        mode = stored.mode ?? defaultMode
        kickoffContext = stored.kickoffContext
        messages = stored.messages.map { message in
            var message = message
            if message.pending { message.pending = false; message.error = "Interrupted when the app closed." }
            return message
        }
        sessionID = stored.sessionID
        sessionProfile = stored.profileID
    }

    func reset() {
        guard !isSending else { return }
        let checkpoints = messages.compactMap(\.checkpointID)
        messages = []
        sessionID = nil
        sessionProfile = nil
        mode = defaultMode
        kickoffContext = nil
        if let folder {
            try? FileManager.default.removeItem(at: Self.url(for: folder, storage: storage))
            // Only this conversation's: the other chat of the folder keeps its own Undo.
            CheckpointStore.discard(ids: checkpoints, folder: folder)
        }
    }

    /// Turns the chat into the planning conversation for a new app.
    func beginKickoff(context: String) {
        guard !isSending else { return }
        mode = .kickoff
        kickoffContext = context
        save()
    }

    /// Back to changing the project, once the plan is done.
    func switchToBuild() {
        guard !isSending else { return }
        mode = .build
        save()
    }

    func stop() {
        guard isSending else { return }
        stopRequested = true
        process?.cancel()
    }

    /// What this conversation has cost so far.
    var totalCost: Double { messages.compactMap(\.cost).reduce(0, +) }

    /// Answers whose edits can still be undone, newest first. Undoing one undoes the newer ones too.
    var undoable: [ChatMessage] {
        messages.filter { $0.checkpointID != nil && $0.undone != true }.reversed()
    }

    /// The request a reply answered: the user message just before it.
    func request(for reply: ChatMessage) -> ChatMessage? {
        guard let index = index(of: reply.id), index > 0, messages[index - 1].role == .user else { return nil }
        return messages[index - 1]
    }

    func recordChoice(_ labels: [String], for id: UUID) {
        guard let index = index(of: id) else { return }
        messages[index].chosen = labels
        save()
    }

    func markUndone(_ id: UUID) {
        guard let index = index(of: id) else { return }
        messages[index].undone = true
        save()
    }

    /// Every file changed in this conversation, as it stands now: a file added and then edited is still
    /// "added", and one added and then deleted again is left out.
    var changedFiles: [FileSnapshot.Change] {
        var kinds: [String: FileSnapshot.Change.Kind] = [:]
        for change in messages.flatMap(\.files) {
            switch (kinds[change.path], change.kind) {
            case (.added?, .deleted): kinds[change.path] = nil
            case (.added?, _): break
            case (.deleted?, .added): kinds[change.path] = .modified
            default: kinds[change.path] = change.kind
            }
        }
        return kinds.map { FileSnapshot.Change(path: $0.key, kind: $0.value) }.sorted { $0.path < $1.path }
    }

    // MARK: Fix with Claude

    /// Shows a Fix with Claude run in the transcript: the request now, Claude's report when it ends.
    /// Fixes run outside the chat's Claude session, so they don't change what the conversation remembers.
    @discardableResult
    func beginFix(_ failure: RunFailure) -> UUID {
        messages.append(ChatMessage(role: .user, text: "Fix the failed run: \(failure.message)"))
        let reply = ChatMessage(role: .assistant, text: "", pending: true)
        messages.append(reply)
        save()
        return reply.id
    }

    func updateFix(_ id: UUID, activity: [String]) {
        guard let index = index(of: id) else { return }
        messages[index].activity = activity
    }

    func finishFix(_ id: UUID, with phase: FixPhase) {
        guard let index = index(of: id) else { return }
        messages[index].pending = false
        switch phase {
        case .done(let outcome):
            messages[index].text = Self.describe(outcome)
            messages[index].files = outcome.files
            messages[index].cost = outcome.cost
            messages[index].checkpointID = outcome.checkpointID
        case .failed(let message):
            messages[index].error = message
        case .idle, .fixing, .validating:
            messages[index].error = "Cancelled."
        }
        save()
    }

    private static func describe(_ outcome: FixOutcome) -> String {
        let report = outcome.report
        let verdict = switch outcome.validated {
        case true?: "**Fixed and verified.** The app runs."
        case false?: "**Changed, but it still fails.** The app did not run after the fix."
        case nil: report.fixed ? "**No files changed.**" : "**Nothing to fix in the project.**"
        }
        var parts = [verdict, "**Cause:** \(report.rootCause)", "**What was done:** \(report.summary)"]
        if !report.remainingIssues.isEmpty {
            parts.append("**Still open:**\n" + report.remainingIssues.map { "- \($0)" }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    /// Records a change the app made itself (Use this design) as a request and answer, so it shows and can be undone
    /// like one of Claude's.
    func appendLocal(request: String, reply: String, files: [FileSnapshot.Change], checkpointID: UUID?) {
        guard !isSending else { return }
        messages.append(ChatMessage(role: .user, text: request))
        var answer = ChatMessage(role: .assistant, text: reply)
        answer.files = files
        answer.checkpointID = checkpointID
        messages.append(answer)
        save()
    }

    // MARK: Sending

    /// `approve` answers Claude when it wants something outside its allow-list; it is what shows the user a question.
    func send(_ text: String, references: [PickedWidget] = [], turn: Turn = .normal, milestone: Int? = nil, designApply: String? = nil,
              design: DesignCall? = nil, attachments: [String] = [], readableFolders: [String] = [], folder: String,
              claude: ClaudeAccess, profile: Profile, approve: @escaping AgentPermissionHandler, finishing: Finishing? = nil) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        self.folder = folder
        stopRequested = false
        isSending = true

        // A conversation can only continue with the account that started it.
        var note: String?
        if let sessionProfile, sessionProfile != profile.id, sessionID != nil {
            sessionID = nil
            note = "Started a new conversation, because the account changed to \(profile.name)."
        }
        let resuming = sessionID
        let session = sessionID ?? UUID().uuidString.lowercased()
        sessionID = session
        sessionProfile = profile.id

        var request = ChatMessage(role: .user, text: text, references: references.isEmpty ? nil : references.map(\.friendlyLabel))
        if references.contains(where: { $0.thumbnail != nil }) {
            request.referenceImages = references.map { pick in pick.thumbnail.flatMap(Self.saveThumbnail) }
        }
        request.attachments = attachments.isEmpty ? nil : attachments
        messages.append(request)
        var reply = ChatMessage(role: .assistant, text: "", pending: true)
        reply.milestone = milestone
        reply.designApply = designApply
        messages.append(reply)
        if let note { messages[messages.count - 1].activity.append(note) }
        save()

        var prompt = Self.prompt(text, references: references)
        if let design, !design.instructions.isEmpty { prompt += "\n\n" + design.instructions }
        let callSession: ClaudeAgentCall.Session = resuming == nil ? .start(id: session) : .resume(id: session)
        let call = switch mode {
        case .build: Self.call(for: prompt, session: callSession, readableFolders: readableFolders)
        case .kickoff: Self.kickoffCall(for: prompt, session: callSession, context: kickoffContext, turn: turn)
        case .design: Self.designCall(for: prompt, session: callSession, design: design, readableFolders: readableFolders)
        }
        task = Task {
            await perform(call, turn: turn, folder: folder, claude: claude, resuming: resuming != nil, replyID: reply.id,
                          approve: approve, finishing: finishing)
        }
    }

    private func perform(_ call: ClaudeAgentCall, turn: Turn, folder: String, claude: ClaudeAccess, resuming: Bool, replyID: UUID,
                         approve: @escaping AgentPermissionHandler, finishing: Finishing?) async {
        let before = await FileSnapshot.taken(of: folder, keepingContents: true)
        let process = await claude.agentProcess(call, folder: folder, timeout: 30 * 60)
        self.process = process
        Self.log.append("SEND in \(folder) (\(call.session))\n\(call.prompt)")

        var failure: String?
        var cost: Double?
        var plan: ProductPlan?
        do {
            let finished = try await process.run(onLine: { [weak self] line in
                Task { @MainActor in self?.receive(line, folder: folder, replyID: replyID) }
            }, onPermission: { [weak self] request in
                let decision = await approve(request)
                await self?.noteDecision(decision, for: request, replyID: replyID)
                return decision
            })
            Self.log.append("EXIT \(finished.status)\n" + finished.lines.joined(separator: "\n") + "\n--- stderr ---\n" + finished.stderr)
            if let result = ClaudeEvents.result(in: finished.lines) {
                cost = result.cost
                if result.isError {
                    failure = result.errors.nonEmpty ?? result.text.nonEmpty ?? "Claude stopped (\(result.subtype ?? "error"))."
                } else if turn == .plan {
                    // The app writes PLAN.md itself, before the after-snapshot, so it is undoable like any change.
                    if let found = result.structured(as: ProductPlan.self) {
                        do {
                            try PlanRenderer.write(found, appName: Self.appName(in: folder), to: folder)
                            plan = found
                        } catch {
                            failure = "Couldn't save PLAN.md: \(error.localizedDescription)"
                        }
                    } else {
                        failure = "Claude didn't return a plan. Try again."
                    }
                } else if let index = index(of: replyID), messages[index].text.isEmpty, !result.text.isEmpty {
                    messages[index].text = result.text
                }
            } else if !stopRequested {
                let stderr = finished.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                failure = finished.timedOut ? "Claude took longer than 30 minutes and was stopped."
                    : stderr.nonEmpty ?? "Claude did not answer."
            }
        } catch {
            failure = error.localizedDescription
        }
        self.process = nil

        if let finishing, let index = index(of: replyID) { finishing(messages[index], failure != nil || stopRequested) }
        let after = await FileSnapshot.taken(of: folder)
        let changes = after.changes(since: before)
        let undoable = !changes.isEmpty
            && CheckpointStore.save(id: replyID, folder: folder, changes: changes, before: before, after: after)
        if let index = index(of: replyID) {
            messages[index].pending = false
            messages[index].cost = cost
            messages[index].files = changes
            if let plan {
                messages[index].plan = plan
                messages[index].text = Self.planAnswer(plan)
            }
            if undoable { messages[index].checkpointID = replyID }
            if stopRequested { messages[index].error = "Stopped." } else { messages[index].error = failure }
        }
        // A failed first turn leaves nothing to resume.
        if failure != nil, !resuming, !stopRequested { sessionID = nil }
        isSending = false
        save()
    }

    private func receive(_ line: String, folder: String, replyID: UUID) {
        guard let index = index(of: replyID) else { return }
        for item in ClaudeEvents.items(in: line, folder: folder) {
            switch item {
            case .text(let text):
                messages[index].text += (messages[index].text.isEmpty ? "" : "\n\n") + text
            case .activity(let text):
                messages[index].activity.append(text)
            }
        }
    }

    /// What was allowed or declined goes in the answer's steps, so the technical details show it.
    private func noteDecision(_ decision: AgentPermissionRequest.Decision, for request: AgentPermissionRequest, replyID: UUID) {
        guard let index = index(of: replyID) else { return }
        messages[index].activity.append(request.note(for: decision))
        Self.log.append("APPROVAL \(request.note(for: decision))")
    }

    private func index(of id: UUID) -> Int? { messages.firstIndex { $0.id == id } }

    /// The message, plus where in the code each tapped UI element lives.
    private static func prompt(_ text: String, references: [PickedWidget]) -> String {
        guard !references.isEmpty else { return text }
        return text + """


        The user tapped these elements in the running app to show what they mean. Each is the Flutter widget at that \
        source location, so read that code first:
        """ + "\n" + references.map(\.promptLine).joined(separator: "\n")
    }

    // MARK: Claude call

    private static let systemPrompt = """
        You are the coding agent inside Mobile Studio, a desktop app where people build a Flutter app by asking for \
        changes and seeing them in an iOS Simulator next to this chat. Many of them don't read code. The current \
        directory is their project. Make the change they ask for directly. Do not commit or touch git history. \
        Change files only with the Edit and Write tools, never with a shell script (python, sed, cat > file): those \
        need the user's OK, while edits are accepted and can be undone. \
        Never run `flutter run`: the app runs it, and it reloads the app on its own after you change files, so never \
        say you couldn't see the result. After changing code, check it with `dart analyze` when that is cheap. \
        For a command beyond the usual Flutter and Dart ones, such as `dart run build_runner build`, just run it: the \
        app asks the user first. If they say no, don't find another way around it; say what they would need to run. \
        If ARCHITECTURE.md or PLAN.md exist, read them before changing code and follow them.

        You can see and use the running app. `ms-sim screenshot` saves a picture of the simulator and prints its \
        path: read that file to look at it. `ms-sim tap X Y` and `ms-sim swipe X1 Y1 X2 Y2` touch the screen at \
        pixel positions of the latest screenshot, and `ms-sim home` presses Home. To scroll, swipe (drag up to see what's below). To fill a form, tap the \
        field and try `ms-sim type "text"`, then screenshot: on newer Xcode simulators the keyboard may be ignored. If \
        the text didn't appear, run `ms-sim paste "text"`, `ms-sim hold X Y` on the field, and tap Paste in the menu \
        that appears. Check with a screenshot either way, as iOS may autocorrect. After a change to what the user \
        sees, wait a few seconds for the hot reload, then take a screenshot and check the result yourself. Tap \
        through the screen you changed (and any screen it leads to) when behaviour matters. If ms-sim says the \
        simulator isn't running, say so rather than guessing. Don't take screenshots for changes that can't be seen.

        Answer in two parts. First, one to three short plain sentences on what changed in the app, as the user will \
        see it ("The three water buttons now share the row and shrink on small phones."), without class names, \
        file paths or code. Then a line with only `---`, then brief technical notes for developers: files, widgets, \
        checks you ran. If nothing changed, say why in the first part and skip the rest.

        When you end by offering options (what to do next, or alternatives to pick from), don't ask in prose. \
        Put them last, after everything else, as a fenced block with the language `choices` holding JSON: \
        {"question": "What should I do first?", "multiple": true, "options": [{"label": "Fix the broken test", \
        "detail": "One short sentence on what it involves.", "recommended": true}]}. Labels are short actions in \
        plain words. Set "multiple" to true when several can be done together, mark at most one option \
        "recommended", and offer between two and six options. The app shows them as buttons and sends back \
        what the user picks.
        """

    private static func kickoffSystemPrompt(context: String?) -> String {
        """
        You are the product partner inside Mobile Studio, helping someone who may not read code plan a new Flutter \
        app before it is built. The current directory is their new project: read `pubspec.yaml` and \
        `ARCHITECTURE.md` once at the start. You cannot change files in this conversation, and you should not try.

        \(context.map { "What they told the app about the idea:\n\($0)\n" } ?? "")
        Each turn, answer in two parts like the rest of the app: a short plain-words reply (the first turn: one \
        paragraph with your take on the app), then a line with only `---` and brief notes if you have any. Then ask \
        one to three short questions, each its own fenced block with the language `choices` holding JSON, all at the \
        very end of your answer (put the questions that matter most first): \
        {"question": "Does it need accounts?", "multiple": false, "options": [{"label": "No, it stays on the phone", \
        "detail": "One short sentence.", "recommended": true}]}. Use "multiple": true for lists of features. Offer \
        two to six options, in plain words, and mark at most one "recommended". They can always type their own answer.

        Cover these in about two to four turns: who it is for and the one job it does; the \
        screens and main flow; where data lives (on the phone or in the cloud, offline); accounts; notifications; look \
        and feel (colour, tone, light and dark); money; platforms; accessibility and languages. Skip what the \
        description already answers. When you have enough, say so, and make your only question exactly: {"question": "I have what I need. Write the \
        plan?", "multiple": false, "options": [{"label": "\(ProductPlan.writeLabel)", "recommended": true}, \
        {"label": "\(ProductPlan.moreQuestionsLabel)"}]}. If they ask to change the plan, ask what to change, then \
        offer \(ProductPlan.writeLabel) again.
        """
    }

    /// Kickoff turns can only read: no shell, no editing. A plan turn also asks for the plan as structured output.
    private static func kickoffCall(for prompt: String, session: ClaudeAgentCall.Session, context: String?, turn: Turn) -> ClaudeAgentCall {
        switch turn {
        case .normal:
            ClaudeAgentCall(prompt: prompt, tools: ["Read", "Glob", "Grep"], session: session,
                            systemPrompt: kickoffSystemPrompt(context: context), maxBudgetUSD: 1, allowedCommands: [])
        case .plan:
            ClaudeAgentCall(
                prompt: prompt + "\n\nNow write the product plan from everything we discussed. Must have is what the first "
                    + "version needs; can have is for later. Milestones are in build order, each small enough to build and "
                    + "see in one go. Use the screen names the plan's screens list uses.",
                tools: ["Read", "Glob", "Grep"], model: "opus", session: session,
                systemPrompt: kickoffSystemPrompt(context: context), jsonSchema: ProductPlan.schema,
                maxBudgetUSD: 3, allowedCommands: [])
        }
    }

    /// The chat text for a written plan: a short summary and what to do next.
    private static func planAnswer(_ plan: ProductPlan) -> String {
        let choices = (try? JSONEncoder().encode(ProductPlan.nextSteps)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return "**The plan is written to \(ProductPlan.fileName).** \(plan.summary)\n\n```choices\n\(choices)\n```"
    }

    /// The app's display name from the New Project record, or the folder's name.
    private static func appName(in folder: String) -> String {
        NewProjectRecord.load(forFolder: folder)?.request.displayName.nonEmpty ?? (folder as NSString).lastPathComponent
    }

    /// Mockups only: edits limited to design/ (or less, for a turn that only rewrites suggestions), no shell.
    private static func designCall(for prompt: String, session: ClaudeAgentCall.Session, design: DesignCall?,
                                   readableFolders: [String]) -> ClaudeAgentCall {
        let turn = design?.turn
        return ClaudeAgentCall(
            prompt: prompt,
            model: turn?.model ?? "sonnet",
            session: session,
            systemPrompt: DesignPrompts.systemPrompt,
            maxBudgetUSD: turn?.maxBudgetUSD ?? 2,
            allowedCommands: [],
            readableFolders: (design?.readableFolders ?? []) + readableFolders,
            asksForApproval: true,
            editablePattern: turn?.editablePattern ?? "\(DesignPaths.folder)/**"
        )
    }

    /// Edits stay inside the project folder; shell access is limited to Flutter, Dart, CocoaPods and read-only git.
    private static func call(for prompt: String, session: ClaudeAgentCall.Session, readableFolders: [String] = []) -> ClaudeAgentCall {
        ClaudeAgentCall(
            prompt: prompt,
            session: session,
            systemPrompt: systemPrompt,
            maxBudgetUSD: 5,
            allowedCommands: [
                "ms-sim *",
                "flutter pub *", "flutter analyze *", "flutter test *", "flutter build *",
                "dart format *", "dart analyze *", "dart fix *", "pod *",
                "git status *", "git diff *", "git log *", "git branch *",
            ],
            readableFolders: [AgentBridge.screenshotDirectory.path] + readableFolders,
            asksForApproval: true
        )
    }

    // MARK: Thumbnails

    private static var thumbnails: URL { ProjectStorage.root.appendingPathComponent("Thumbnails") }

    static func thumbnailURL(_ name: String) -> URL { thumbnails.appendingPathComponent(name) }

    private static func saveThumbnail(_ data: Data) -> String? {
        let name = UUID().uuidString + ".png"
        try? FileManager.default.createDirectory(at: thumbnails, withIntermediateDirectories: true)
        return (try? data.write(to: thumbnailURL(name))) != nil ? name : nil
    }

    // MARK: Persistence

    private struct Stored: Codable {
        let folder: String
        let sessionID: String?
        let profileID: UUID?
        let messages: [ChatMessage]
        // Absent in chats saved before kickoff existed.
        var mode: ChatMode?
        var kickoffContext: String?
    }

    private func save() {
        guard let folder else { return }
        let stored = Stored(folder: folder, sessionID: sessionID, profileID: sessionProfile, messages: messages,
                            mode: mode, kickoffContext: kickoffContext)
        let url = Self.url(for: folder, storage: storage)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(stored) { try? data.write(to: url, options: .atomic) }
    }

    private static func read(folder: String, storage: String?) -> Stored? {
        guard let data = try? Data(contentsOf: url(for: folder, storage: storage)) else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }

    private static func url(for folder: String, storage: String?) -> URL {
        let name = SHA256.hash(data: Data(folder.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mobile Studio/Chats/\(name)\(storage.map { "-\($0)" } ?? "").json")
    }
}
