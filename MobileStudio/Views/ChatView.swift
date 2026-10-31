import SwiftUI

/// Chat with Claude Code in the project folder, sent as the selected account. Shown as the window's inspector.
struct ChatPanel: View {
    let workspace: Workspace

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
        .onChange(of: workspace.composerFocusRequest) { inputFocused = true }
    }

    private var draft: String {
        get { workspace.chatDraft }
        nonmutating set { workspace.chatDraft = newValue }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Claude").font(.headline)
            Spacer()
            if chat.totalCost > 0 {
                Text(chat.totalCost, format: .currency(code: "USD").precision(.fractionLength(2)))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help(String(format: "Spent on Claude in this chat: $%.3f", chat.totalCost))
            }
            // Choosing an account only matters when there is more than one to choose from.
            if studio.profiles.profiles.filter({ if case .signedIn = studio.account(for: $0) { true } else { false } }).count > 1 {
                AccountMenu(studio: studio)
            }
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
                LazyVStack(alignment: .leading, spacing: 22) {
                    if chat.messages.isEmpty { emptyState }
                    ForEach(chat.messages) { message in
                        MessageRow(message: message, workspace: workspace).id(message.id)
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
                        Button { workspace.chatDraft = suggestion; inputFocused = true } label: {
                            Label(suggestion, systemImage: "arrow.up.right").frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.top, 4)
                Text("Tip: press Point at… (⇧⌘E) and tap something in the app to show Claude what you mean.")
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
                TextField(workspace.chatBlocker ?? "Describe a change, or point at something in the app",
                          text: Binding(get: { workspace.chatDraft }, set: { workspace.chatDraft = $0 }), axis: .vertical)
                    .lineLimit(2...8)
                    .textFieldStyle(.plain)
                    .focused($inputFocused)
                    .onSubmit(send)
                    .disabled(workspace.chatBlocker != nil)
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                    .padding(.bottom, 6)
                HStack(spacing: 6) {
                    Toggle(isOn: Binding(get: { pick.isPicking }, set: { _ in workspace.togglePick() })) {
                        Label(pick.isPicking ? "Tap in the App…" : "Point at…", systemImage: "scope")
                    }
                    .toggleStyle(.button)
                    .tint(.accentColor)
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
                .controlSize(.regular)
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
            if let data = widget.thumbnail, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 72, height: 32).clipShape(RoundedRectangle(cornerRadius: 4))
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "scope").foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(widget.friendlyLabel).font(.callout).lineLimit(1)
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
        guard canSend else { return }
        let text = draft
        draft = ""
        workspace.sendChat(text)
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
    let workspace: Workspace

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 6) {
                    Text(message.text).textSelection(.enabled)
                    ForEach(Array((message.references ?? []).enumerated()), id: \.offset) { index, reference in
                        HStack(spacing: 6) {
                            if let name = message.referenceImages?[safe: index] ?? nil,
                               let image = NSImage(contentsOf: ChatModel.thumbnailURL(name)) {
                                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                                    .frame(maxWidth: 160, maxHeight: 40).clipShape(RoundedRectangle(cornerRadius: 4))
                            } else {
                                Image(systemName: "scope")
                            }
                            Text(reference)
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        case .assistant:
            let extracted = ChoiceSet.extract(from: message.text)
            let parts = AnswerParts.split(extracted.text)
            VStack(alignment: .leading, spacing: 10) {
                if message.pending { working }
                if !extracted.text.isEmpty { MarkdownView(text: parts.outcome) }
                if !message.files.isEmpty { changes }
                if let choices = extracted.choices, !message.pending {
                    ChoiceCard(choices: choices, chosen: message.chosen, isActive: isLatest && message.chosen == nil,
                               canSend: workspace.chatBlocker == nil && !workspace.chat.isSending,
                               onChoose: { workspace.choose($0, in: message) },
                               onOther: workspace.answerInOwnWords)
                }
                if let error = message.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                if !message.pending, parts.details != nil || !message.activity.isEmpty { details(parts.details) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Only the newest answer's options can still be picked; older ones are history.
    private var isLatest: Bool { workspace.chat.messages.last?.id == message.id }

    /// Shown while Claude works: the latest thing it did.
    private var working: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(message.activity.last ?? "Thinking…").foregroundStyle(.secondary).lineLimit(1)
        }
    }

    /// What changed, in plain words, with Undo while it still can be.
    private var changes: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(message.undone == true ? "Undone" : "Changed \(message.files.count) file\(message.files.count == 1 ? "" : "s")")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if message.checkpointID != nil, message.undone != true {
                    Button { workspace.undo(message) } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                        .controlSize(.small)
                        .disabled(workspace.chat.isSending || workspace.fix.isBusy)
                        .help(message.id == workspace.chat.undoable.first?.id
                              ? "Put the files back as they were before this answer"
                              : "Undo this answer and every one after it")
                }
            }
            ForEach(message.files.prefix(12)) { change in
                Button { workspace.showDiff(of: change) } label: {
                    FileChangeRow(change: change, compact: true)
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show what changed in \(change.path)")
            }
            if message.files.count > 12 { Text("and \(message.files.count - 12) more").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .opacity(message.undone == true ? 0.6 : 1)
    }

    /// Claude's technical notes and the steps it took, for whoever wants them.
    private func details(_ notes: String?) -> some View {
        DisclosureGroup("Technical details") {
            VStack(alignment: .leading, spacing: 8) {
                if let notes { MarkdownView(text: notes).font(.callout) }
                ForEach(Array(message.activity.enumerated()), id: \.offset) { _, step in
                    Label {
                        Text(step).lineLimit(2).textSelection(.enabled)
                    } icon: {
                        Image(systemName: ClaudeStep(step).symbol).frame(width: 14)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if let cost = message.cost {
                    Text(String(format: "Cost $%.3f", cost)).font(.caption).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
        .foregroundStyle(.secondary)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// The options at the end of an answer, to pick instead of typing a reply. Checkboxes when several can be done
/// together, radio buttons when it's one or the other. The recommended option starts selected.
private struct ChoiceCard: View {
    let choices: ChoiceSet
    /// What was picked earlier; the card then shows it and can't be used again.
    let chosen: [String]?
    let isActive: Bool
    let canSend: Bool
    let onChoose: ([String]) -> Void
    let onOther: () -> Void

    @State private var selection: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(choices.question ?? "What would you like to do?").font(.headline)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(choices.options, id: \.self) { option in row(option) }
            }
            if isActive {
                HStack {
                    Button("Something Else…", action: onOther).buttonStyle(.borderless)
                    Spacer()
                    Button(sendTitle) { onChoose(ordered) }
                        .buttonStyle(.borderedProminent)
                        .disabled(selection.isEmpty || !canSend)
                }
                .controlSize(.regular)
            } else if let chosen {
                Label(chosen.count == 1 ? "You chose this" : "You chose \(chosen.count)", systemImage: "checkmark")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(isActive ? Color.accentColor.opacity(0.5) : Color(nsColor: .separatorColor)))
        .onAppear {
            if selection.isEmpty { selection = Set(choices.options.filter { $0.recommended == true }.map(\.label)) }
        }
    }

    private var sendTitle: String {
        guard choices.allowsMultiple, selection.count > 1 else { return "Do This" }
        return "Do These (\(selection.count))"
    }

    /// The picks in the order Claude listed them, which is usually the order to do them in.
    private var ordered: [String] { choices.options.map(\.label).filter(selection.contains) }

    private func isSelected(_ option: ChoiceSet.Option) -> Bool {
        chosen.map { $0.contains(option.label) } ?? selection.contains(option.label)
    }

    private func row(_ option: ChoiceSet.Option) -> some View {
        Button {
            guard isActive else { return }
            if choices.allowsMultiple {
                if selection.contains(option.label) { selection.remove(option.label) } else { selection.insert(option.label) }
            } else {
                selection = [option.label]
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol(for: option))
                    .foregroundStyle(isSelected(option) ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(option.label).foregroundStyle(.primary)
                        if option.recommended == true {
                            Text("Recommended").font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.15), in: Capsule())
                        }
                    }
                    if let detail = option.detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isActive || isSelected(option) ? 1 : 0.55)
        .accessibilityAddTraits(isSelected(option) ? .isSelected : [])
    }

    private func symbol(for option: ChoiceSet.Option) -> String {
        let on = isSelected(option)
        return choices.allowsMultiple ? (on ? "checkmark.square.fill" : "square") : (on ? "largecircle.fill.circle" : "circle")
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
