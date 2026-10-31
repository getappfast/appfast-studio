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
    /// The saved state from before this answer's edits, when they can be undone.
    var checkpointID: UUID?
    /// The edits were undone.
    var undone: Bool?
    /// What the user picked from this answer's choices, once they have.
    var chosen: [String]?
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

/// A chat with Claude Code running in the project folder, as the selected account.
@MainActor
@Observable
final class ChatModel {
    private(set) var messages: [ChatMessage] = []
    private(set) var isSending = false

    @ObservationIgnored private var folder: String?
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
        guard let folder, let stored = Self.read(folder: folder) else { return }
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
        messages = []
        sessionID = nil
        sessionProfile = nil
        if let folder {
            try? FileManager.default.removeItem(at: Self.url(for: folder))
            CheckpointStore.discardAll(folder: folder)
        }
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

    // MARK: Sending

    func send(_ text: String, references: [PickedWidget] = [], folder: String, claude: ClaudeAccess, profile: Profile) {
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
        messages.append(request)
        let reply = ChatMessage(role: .assistant, text: "", pending: true)
        messages.append(reply)
        if let note { messages[messages.count - 1].activity.append(note) }
        save()

        let prompt = Self.prompt(text, references: references)
        let call = Self.call(for: prompt, session: resuming == nil ? .start(id: session) : .resume(id: session))
        task = Task { await perform(call, folder: folder, claude: claude, resuming: resuming != nil, replyID: reply.id) }
    }

    private func perform(_ call: ClaudeAgentCall, folder: String, claude: ClaudeAccess, resuming: Bool, replyID: UUID) async {
        let before = await FileSnapshot.taken(of: folder, keepingContents: true)
        let process = await claude.agentProcess(call, folder: folder, timeout: 30 * 60)
        self.process = process
        Self.log.append("SEND in \(folder) (\(call.session))\n\(call.prompt)")

        var failure: String?
        var cost: Double?
        do {
            let finished = try await process.run { [weak self] line in
                Task { @MainActor in self?.receive(line, folder: folder, replyID: replyID) }
            }
            Self.log.append("EXIT \(finished.status)\n" + finished.lines.joined(separator: "\n") + "\n--- stderr ---\n" + finished.stderr)
            if let result = ClaudeEvents.result(in: finished.lines) {
                cost = result.cost
                if result.isError {
                    failure = result.errors.nonEmpty ?? result.text.nonEmpty ?? "Claude stopped (\(result.subtype ?? "error"))."
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

        let after = await FileSnapshot.taken(of: folder)
        let changes = after.changes(since: before)
        let undoable = !changes.isEmpty
            && CheckpointStore.save(id: replyID, folder: folder, changes: changes, before: before, after: after)
        if let index = index(of: replyID) {
            messages[index].pending = false
            messages[index].cost = cost
            messages[index].files = changes
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
        Never run `flutter run`: the app runs it, and it reloads the app on its own after you change files, so never \
        say you couldn't see the result. After changing code, check it with `dart analyze` when that is cheap.

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

    /// Edits stay inside the project folder; shell access is limited to Flutter, Dart, CocoaPods and read-only git.
    private static func call(for prompt: String, session: ClaudeAgentCall.Session) -> ClaudeAgentCall {
        ClaudeAgentCall(
            prompt: prompt,
            session: session,
            systemPrompt: systemPrompt,
            maxBudgetUSD: 5,
            allowedCommands: [
                "flutter pub *", "flutter analyze *", "flutter test *", "flutter build *",
                "dart format *", "dart analyze *", "dart fix *", "pod *",
                "git status *", "git diff *", "git log *", "git branch *",
            ]
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
    }

    private func save() {
        guard let folder else { return }
        let stored = Stored(folder: folder, sessionID: sessionID, profileID: sessionProfile, messages: messages)
        let url = Self.url(for: folder)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(stored) { try? data.write(to: url, options: .atomic) }
    }

    private static func read(folder: String) -> Stored? {
        guard let data = try? Data(contentsOf: url(for: folder)) else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }

    private static func url(for folder: String) -> URL {
        let name = SHA256.hash(data: Data(folder.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mobile Studio/Chats/\(name).json")
    }
}
