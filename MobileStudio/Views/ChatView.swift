import SwiftUI

/// Chat with Claude Code in the project folder, sent as the selected account.
struct ChatPanel: View {
    let chat: ChatModel
    let project: ProjectModel
    let studio: StudioModel
    let run: FlutterRunModel
    let pick: PickModel

    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    private var folder: String? {
        if case .ready(let flutter) = project.state { return flutter.path }
        return nil
    }

    /// Why sending is unavailable, nil when it is possible.
    private var blocker: String? {
        if folder == nil { return "Choose a Flutter project to start a chat." }
        if studio.claude == nil { return "Install the claude CLI and sign in to chat." }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            references
            input
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Label("Chat", systemImage: "bubble.left.and.bubble.right").font(.headline)
            Spacer()
            Text(studio.profiles.active.name).foregroundStyle(.secondary)
                .help("Messages are sent with this Claude account. Change it in Settings.")
            Button("New chat") { chat.reset() }
                .controlSize(.small)
                .disabled(chat.messages.isEmpty || chat.isSending)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if chat.messages.isEmpty {
                        Text(blocker ?? "Ask Claude to change your app, for example \"add a settings screen\" or \"why does the water page overflow?\". It works in your project folder.")
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                    ForEach(chat.messages) { message in
                        MessageRow(message: message).id(message.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: chat.messages.count) { scrollToBottom(proxy) }
            .onChange(of: chat.messages.last?.text) { scrollToBottom(proxy) }
            .onChange(of: chat.messages.last?.activity.count) { scrollToBottom(proxy) }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    // MARK: References

    /// Elements tapped in the running app, waiting to go with the next message.
    @ViewBuilder
    private var references: some View {
        if pick.phase != .idle || !pick.picks.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                switch pick.phase {
                case .connecting:
                    pickNotice("Connecting to the app…", showsProgress: true)
                case .picking:
                    pickNotice("Tap an element in the simulator to reference it.", showsProgress: true)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                case .idle:
                    EmptyView()
                }
                if !pick.picks.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(pick.picks) { chip($0) }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func pickNotice(_ text: String, showsProgress: Bool) -> some View {
        HStack(spacing: 8) {
            if showsProgress { ProgressView().controlSize(.small) }
            Text(text).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { pick.cancel() }.controlSize(.small)
        }
    }

    private func chip(_ widget: PickedWidget) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "scope").foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(widget.label).font(.callout).lineLimit(1)
                if let line = chipDetail(widget) {
                    Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if !widget.ancestors.isEmpty {
                Menu {
                    Section("Select a parent instead") {
                        ForEach(Array(widget.ancestors.enumerated()), id: \.offset) { index, parent in
                            Button("\(parent.type) · \(parent.file):\(parent.line)") { pick.useParent(of: widget, at: index) }
                        }
                    }
                } label: {
                    Label("Select a parent", systemImage: "arrow.up.left.and.arrow.down.right").labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Select a parent widget")
            }
            Button { pick.remove(widget) } label: { Label("Remove", systemImage: "xmark.circle.fill").labelStyle(.iconOnly) }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .help(widget.promptLine)
    }

    private func chipDetail(_ widget: PickedWidget) -> String? {
        ([widget.size.map { "\($0) pt" }] + widget.details.prefix(1).map { Optional($0) }).compactMap { $0 }.joined(separator: " · ").nonEmpty
    }

    private var canPick: Bool { run.phase == .running && run.vmServiceURL != nil }

    // MARK: Input

    private var input: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message Claude…", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .focused($inputFocused)
                .padding(10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                .onSubmit(send)
                .disabled(blocker != nil)
            Button { pick.toggle(run: run, folder: folder) } label: { Label("Pick", systemImage: "scope").labelStyle(.iconOnly) }
                .controlSize(.large)
                .tint(pick.isPicking ? .accentColor : nil)
                .buttonStyle(.bordered)
                .disabled(!canPick && !pick.isPicking)
                .help(canPick ? "Tap an element in the running app to reference it"
                              : "Run the app first, then tap elements in it to reference them")
            if chat.isSending {
                Button { chat.stop() } label: { Label("Stop", systemImage: "stop.fill").labelStyle(.iconOnly) }
                    .controlSize(.large)
                    .help("Stop")
            } else {
                Button(action: send) { Label("Send", systemImage: "arrow.up").labelStyle(.iconOnly) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(blocker != nil || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Send")
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private func send() {
        guard blocker == nil, !chat.isSending, let folder, let claude = studio.claude else { return }
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        pick.cancel()
        chat.send(text, references: pick.picks, folder: folder, claude: claude, profile: studio.profiles.active)
        pick.clear()
        inputFocused = true
    }
}

private struct MessageRow: View {
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 6) {
                    Text(message.text).textSelection(.enabled)
                    ForEach(message.references ?? [], id: \.self) { reference in
                        Label(reference, systemImage: "scope").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.22), in: RoundedRectangle(cornerRadius: 12))
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                if message.pending { working }
                if !message.text.isEmpty { Text(markdown(message.text)).textSelection(.enabled) }
                if !message.pending, !message.activity.isEmpty { steps }
                if !message.files.isEmpty { files }
                if let error = message.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                if let cost = message.cost, !message.pending {
                    Text(String(format: "$%.3f", cost)).font(.caption).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Shown while Claude works: the latest few things it did.
    private var working: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(message.activity.last ?? "Thinking…").foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private var steps: some View {
        DisclosureGroup("Steps (\(message.activity.count))") {
            Text(message.activity.joined(separator: "\n"))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        }
        .foregroundStyle(.secondary)
    }

    private var files: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Files changed (\(message.files.count))").font(.caption).foregroundStyle(.secondary)
            ForEach(message.files.prefix(12)) { change in
                HStack(spacing: 6) {
                    Text(change.kind.badge).foregroundStyle(change.kind.tint)
                    Text(change.path).textSelection(.enabled)
                }
                .font(.system(.caption, design: .monospaced))
            }
            if message.files.count > 12 { Text("and \(message.files.count - 12) more").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
