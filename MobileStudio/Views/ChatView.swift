import SwiftUI

/// Chat with Claude Code in the project folder, sent as the selected account. Shown as the window's inspector.
struct ChatPanel: View {
    let workspace: Workspace

    @State private var draft = ""
    @FocusState private var inputFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var chat: ChatModel { workspace.chat }
    private var pick: PickModel { workspace.pick }
    private var studio: StudioModel { workspace.studio }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            composer
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Claude").font(.headline)
            Spacer()
            AccountMenu(studio: studio)
            Button { chat.reset() } label: { Label("New Chat", systemImage: "square.and.pencil").labelStyle(.iconOnly) }
                .buttonStyle(.borderless)
                .disabled(chat.messages.isEmpty || chat.isSending)
                .help("New Chat (⇧⌘N)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if chat.messages.isEmpty { emptyState }
                    ForEach(chat.messages) { message in
                        MessageRow(message: message, onOpenFile: workspace.showDiff).id(message.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: chat.messages.count) { scrollToBottom(proxy) }
            .onChange(of: chat.messages.last?.text) { scrollToBottom(proxy) }
            .onChange(of: chat.messages.last?.activity.count) { scrollToBottom(proxy) }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if reduceMotion { proxy.scrollTo("bottom", anchor: .bottom); return }
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "sparkles").font(.title).foregroundStyle(.secondary)
            Text("Ask Claude to change your app").font(.title3.weight(.semibold))
            if let blocker = workspace.chatBlocker {
                Text(blocker).foregroundStyle(.secondary)
                if workspace.project.readyFolder == nil {
                    Button("Choose Flutter Project…", action: workspace.chooseProject)
                } else if studio.claude == nil {
                    SettingsLink { Text("Open Settings…") }
                }
            } else {
                Text("Claude works in your project folder, and you'll see the result here once the app reloads.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Self.suggestions, id: \.self) { suggestion in
                        Button { draft = suggestion; inputFocused = true } label: {
                            Label(suggestion, systemImage: "arrow.up.right").frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.top, 4)
                Text("Tip: press Pick (⇧⌘E) and tap an element in the app to point Claude at it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 8)
    }

    private static let suggestions = [
        "Add a settings screen with a dark mode switch",
        "Why does this screen overflow on small phones?",
        "Make the buttons follow Material 3",
    ]

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            references
            VStack(spacing: 0) {
                TextField(workspace.chatBlocker ?? "Message Claude…", text: $draft, axis: .vertical)
                    .lineLimit(1...8)
                    .textFieldStyle(.plain)
                    .focused($inputFocused)
                    .onSubmit(send)
                    .disabled(workspace.chatBlocker != nil)
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                    .padding(.bottom, 6)
                HStack(spacing: 6) {
                    Toggle(isOn: Binding(get: { pick.isPicking }, set: { _ in workspace.togglePick() })) {
                        Label("Pick", systemImage: "scope")
                    }
                    .toggleStyle(.button)
                    .disabled(!workspace.canPick)
                    .help(workspace.canPick ? "Tap an element in the running app to reference it (⇧⌘E)"
                                            : "Run the app first, then tap elements in it to reference them")
                    Spacer()
                    if chat.isSending {
                        Button { chat.stop() } label: { Label("Stop", systemImage: "stop.fill").labelStyle(.iconOnly) }
                            .help("Stop Claude")
                    } else {
                        Button(action: send) { Label("Send", systemImage: "arrow.up").labelStyle(.iconOnly) }
                            .buttonStyle(.borderedProminent)
                            .disabled(!canSend)
                            .help("Send (Return)")
                    }
                }
                .controlSize(.small)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(inputFocused ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor)))
        }
        .padding(12)
    }

    private var canSend: Bool {
        workspace.chatBlocker == nil && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Elements tapped in the running app, waiting to go with the next message.
    @ViewBuilder
    private var references: some View {
        switch pick.phase {
        case .connecting:
            pickNotice("Connecting to the app…")
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
        case .idle, .picking:
            EmptyView()
        }
        ForEach(pick.picks) { chip($0) }
    }

    private func pickNotice(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
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

    private func send() {
        guard workspace.chatBlocker == nil, !chat.isSending, let folder = workspace.project.readyFolder,
              let claude = studio.claude else { return }
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        pick.cancel()
        chat.send(text, references: pick.picks, folder: folder, claude: claude, profile: studio.profiles.active)
        pick.clear()
        inputFocused = true
    }
}

/// The account messages go out as. Only signed-in accounts can be chosen.
private struct AccountMenu: View {
    let studio: StudioModel

    var body: some View {
        Menu {
            ForEach(studio.profiles.profiles) { profile in
                let signedIn = if case .signedIn = studio.account(for: profile) { true } else { false }
                Toggle(isOn: Binding(get: { profile.id == studio.profiles.activeID }, set: { _ in studio.select(profile) })) {
                    Text(signedIn ? profile.name : "\(profile.name) (signed out)")
                }
                .disabled(!signedIn)
            }
            Divider()
            SettingsLink { Text("Manage Accounts…") }
        } label: {
            Label(studio.profiles.active.name, systemImage: "person.crop.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Messages are sent with this Claude account")
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    let onOpenFile: (FileSnapshot.Change) -> Void

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
                .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 10) {
                if message.pending { working }
                if !message.text.isEmpty { MarkdownView(text: message.text) }
                if !message.pending, !message.activity.isEmpty { steps }
                if !message.files.isEmpty { files }
                if let error = message.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                if let cost = message.cost, !message.pending {
                    Text(String(format: "$%.3f", cost)).font(.caption).foregroundStyle(.tertiary)
                        .accessibilityLabel(String(format: "Cost %.3f dollars", cost))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Shown while Claude works: the latest thing it did.
    private var working: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(message.activity.last ?? "Thinking…").foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var steps: some View {
        DisclosureGroup("\(message.activity.count) steps") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(message.activity.enumerated()), id: \.offset) { _, step in
                    Label {
                        Text(step).lineLimit(2).textSelection(.enabled)
                    } icon: {
                        Image(systemName: ClaudeStep(step).symbol).frame(width: 14)
                    }
                    .font(.caption)
                }
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
        .foregroundStyle(.secondary)
    }

    private var files: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Changed \(message.files.count) file\(message.files.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
            ForEach(message.files.prefix(12)) { change in
                Button { onOpenFile(change) } label: {
                    FileChangeRow(change: change, font: .system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show what changed")
            }
            if message.files.count > 12 { Text("and \(message.files.count - 12) more").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Claude's markdown, block by block: headings, lists and code blocks as well as inline styles.
struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            Text(inline(text)).fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let text):
            Text(inline(text)).font(level <= 2 ? .headline : .subheadline.weight(.semibold)).padding(.top, 2)
        case .listItem(let ordinal, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(ordinal ?? "•").foregroundStyle(.secondary).monospacedDigit()
                Text(inline(text)).fixedSize(horizontal: false, vertical: true)
            }
        case .code(let language, let code):
            CodeBlock(language: language, code: code)
        }
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

private struct CodeBlock: View {
    let language: String?
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                } label: { Label("Copy", systemImage: "doc.on.doc").labelStyle(.iconOnly) }
                    .buttonStyle(.borderless)
                    .help("Copy code")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            Divider()
            ScrollView(.horizontal) {
                Text(code).font(.system(.callout, design: .monospaced)).padding(10)
            }
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
    }
}
