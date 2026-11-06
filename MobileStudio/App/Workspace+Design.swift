import AppKit

/// A screen on the Design window's canvas: drawn already, in the code, or planned. One list, so the canvas, the
/// redesign actions and App Flow agree on which screen is which.
struct DesignScreenItem: Identifiable, Equatable {
    /// The folder name under design/screens.
    let id: String
    let name: String
    /// Its Dart file, for a screen in the code.
    let file: String?
    /// What the plan says it is for, for a planned screen.
    let purpose: String?
    let design: DesignLibrary.Screen?

    var isBuilt: Bool { file != nil }
}

/// The Design window's actions. Like the rest of `Workspace`, the views call these and nothing else, so the
/// window's buttons, the menus and App Flow can't disagree.
extension Workspace {
    // MARK: Availability

    /// Why a design turn can't start, nil when it can.
    var designBlocker: String? {
        if project.readyFolder == nil { return "Choose a Flutter project first." }
        if studio.claude == nil { return "Install the claude CLI and sign in to design with Claude." }
        if fix.isBusy { return "Claude is fixing the project. You can design again when it's done." }
        if chat.isSending { return "Claude is changing the app in the main chat. You can design again when it's done." }
        if isSavingEdit { return "Saving your edit. You can design again in a moment." }
        return nil
    }

    var canSendDesign: Bool { designBlocker == nil && !designChat.isSending }

    /// Every screen to show, in the order the app is used: the flow's (start first) or the plan's, then any drawn
    /// screen neither knows.
    var designScreens: [DesignScreenItem] {
        var items: [DesignScreenItem] = []
        var seen = Set<String>()
        func add(name: String, file: String?, purpose: String?) {
            let key = AppFlow.screenKey(name)
            guard !key.isEmpty, !seen.contains(key) else { return }
            seen.insert(key)
            let drawn = design.library.screen(named: name)
            items.append(DesignScreenItem(id: drawn?.id ?? DesignPaths.screenID(for: name), name: drawn?.name.nonEmpty ?? name,
                                          file: file ?? drawn?.versions.file, purpose: purpose, design: drawn))
        }
        if let flow = flowWithPlan, flow.folder == project.readyFolder {
            let order = flow.layout.columns.flatMap { $0 } + flow.layout.unlinked
            let byClass = Dictionary(flow.screens.map { ($0.className, $0) }, uniquingKeysWith: { first, _ in first })
            for screen in order.compactMap({ byClass[$0] }) {
                add(name: screen.name, file: screen.isPlanned ? nil : screen.file, purpose: screen.purpose)
            }
        }
        for screen in plan?.screens ?? [] { add(name: screen.name, file: nil, purpose: screen.purpose) }
        for screen in design.library.screens { add(name: screen.name, file: screen.versions.file, purpose: nil) }
        return items
    }

    /// The screen the app opens on, which the look step draws first.
    var designStartScreen: DesignScreenItem? {
        let items = designScreens
        if let start = flow?.start, let screen = flow?.screens.first(where: { $0.className == start }),
           let item = items.first(where: { AppFlow.screenKey($0.name) == AppFlow.screenKey(screen.name) }) {
            return item
        }
        return items.first
    }

    // MARK: Window

    /// Shows the design canvas, with the design chat in the sidebar, ready for the open project.
    func openDesign() {
        guard project.readyFolder != nil else { return }
        design.prepare()
        design.refresh()
        if design.stage == .look { design.downloadStyleFonts() }
        canvas = .design
    }

    /// Starts redesigning a screen of the code: open it in the window, redraw it from the code unless that's
    /// already done, and take a picture of it first when it's on the device.
    func redesign(_ screen: AppScreen, capture: Bool = false) {
        guard !screen.isPlanned else { return }
        openDesign()
        design.stage = .screens
        let id = design.library.screen(named: screen.name)?.id ?? DesignPaths.screenID(for: screen.name)
        design.selection = [id]
        if capture { captureCurrent(for: id) }
        let drawn = design.library.screen(id)
        if drawn?.hasCurrent != true || design.staleScreens.contains(id) {
            redrawFromApp(id, name: screen.name, file: screen.file)
        }
    }

    /// Saves what the simulator shows now as the screen's picture in the app.
    @discardableResult
    func captureCurrent(for screenID: String) -> Bool {
        guard let store = design.store, let png = deviceModel.capturePNG() else {
            show(Toast(tone: .warning, text: "Run the app and show this screen on the device to take its picture."))
            return false
        }
        store.write(png, to: DesignPaths.capture(screenID))
        design.refresh()
        return true
    }

    var canCapture: Bool { deviceModel.canSendInput }

    /// Draws the screen as the code builds it now, into current.html.
    func redrawFromApp(_ screenID: String, name: String? = nil, file: String? = nil) {
        let item = designScreens.first { $0.id == screenID }
        guard let name = name ?? item?.name else { return }
        let hasCapture = design.store?.exists(DesignPaths.capture(screenID)) ?? false
        sendDesign(DesignTurn(kind: .current(screen: screenID, name: name, file: file ?? item?.file, hasCapture: hasCapture),
                              request: "Show the \(name) screen as it is now."))
    }

    // MARK: Look

    /// Picks a style: Claude draws the start screen in it and suggests colours and fonts. `description` is for
    /// Describe your own.
    func chooseStyle(_ id: String, description: String? = nil, references: [String] = []) {
        guard let start = designStartScreen else {
            show(Toast(tone: .warning, text: "The app has no screens yet. Plan the app or add a screen first."))
            return
        }
        design.styleID = id
        let existing = design.library.screen(start.id)?.versions ?? DesignVersions(name: start.name)
        let ids = existing.nextIDs(count: 1, existingFiles: design.library.screen(start.id)?.files ?? [])
        let about = start.purpose ?? start.file.map { "built in \($0)" }
        let target = DesignTurn.Target(screenID: start.id, name: start.name, parent: nil, ids: ids, about: about)
        let name = DesignStyle.named(id)?.name ?? id
        let request = description.map { "My own style: \($0) (nearest: \(name))" } ?? "\(name) style"
        sendDesign(DesignTurn(kind: .look(style: id, start: target), request: request, references: references))
    }

    /// New colour themes or font pairings, optionally steered: "warmer", "our brand is #E4572E".
    func moreSuggestions(_ kind: DesignTurn.Suggestions, hint: String? = nil, references: [String] = []) {
        let what = kind == .palettes ? "colour themes" : "font pairings"
        sendDesign(DesignTurn(kind: .suggestions(kind, hint: hint?.nonEmpty), request: hint.map { "More \(what): \($0)" } ?? "More \(what)",
                              references: references))
    }

    /// Saves the picked look, then draws the planned screens that have no mockup yet, a few at a time.
    func useLook() {
        guard design.useLook() else { return }
        drawReferences = []
        drawQueue = DesignPrompts.batches(designScreens.filter { $0.design?.shown == nil && !$0.isBuilt }.map { item in
            DesignTurn.Target(screenID: item.id, name: item.name, parent: nil, ids: ["v1"], about: item.purpose)
        })
        drawNextQueued()
    }

    /// Sends the next batch of screens to draw, when nothing else is running.
    func drawNextQueued() {
        guard canSendDesign, !drawQueue.isEmpty else { return }
        let batch = drawQueue.removeFirst().map { target in
            let versions = design.library.screen(target.screenID)?.versions ?? DesignVersions(name: target.name)
            let ids = versions.nextIDs(count: 1, existingFiles: design.library.screen(target.screenID)?.files ?? [])
            return DesignTurn.Target(screenID: target.screenID, name: target.name, parent: nil, ids: ids, about: target.about)
        }
        sendDesign(DesignTurn(kind: .versions(batch), request: "Draw " + batch.map(\.name).formatted(.list(type: .and)),
                              references: drawReferences))
    }

    // MARK: Asking

    /// The Design window's composer: a request about the selected screens makes new versions of each, starting
    /// from what each shows. Nothing selected is a plain question. Attached pictures go with the request, and a
    /// request with only pictures in it asks for them to be used.
    func sendDesignMessage(_ typed: String) {
        let typed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let references = designAttachments
        guard !typed.isEmpty || !references.isEmpty else { return }
        designAttachments = []
        let text = typed.isEmpty ? "Use the reference screenshots." : typed
        if design.stage == .look, design.tokens == nil, design.styleID == nil {
            chooseStyle(DesignStyle.nearest(to: text), description: typed.nonEmpty, references: references)
            return
        }
        if design.stage == .look, design.styleID != nil, design.suggestions.palettes.isEmpty == false {
            moreSuggestions(.palettes, hint: typed.nonEmpty, references: references)
            return
        }
        let items = designScreens.filter { design.selection.contains($0.id) }
        guard !items.isEmpty else {
            sendDesign(DesignTurn(kind: .freeform, request: text, references: references))
            return
        }
        let count = DesignPrompts.versionCount(in: text)
        let targets = items.map { item -> DesignTurn.Target in
            let screen = item.design
            let parent = screen.flatMap { design.shownVersion(of: $0) }
            let ids = (screen?.versions ?? DesignVersions(name: item.name)).nextIDs(count: count, existingFiles: screen?.files ?? [])
            let about = item.purpose ?? item.file.map { "built in \($0); draw it from the code with the request applied" }
            return DesignTurn.Target(screenID: item.id, name: item.name, parent: parent, ids: ids, about: about)
        }
        let batches = DesignPrompts.batches(targets)
        drawReferences = references
        drawQueue = Array(batches.dropFirst()) + drawQueue
        sendDesign(DesignTurn(kind: .versions(batches[0]), request: text, references: references))
    }

    // MARK: Reference pictures

    /// Keeps pictures the user attached in the Design window, to send with its next message. Anything that isn't
    /// a picture is left out and said so.
    func attachDesignReferences(_ urls: [URL]) {
        guard let store = design.store else { return }
        let saved = urls.compactMap { DesignReferences.save($0, to: store.referencesFolder) }
        designAttachments += saved.map(\.path)
        let skipped = urls.count - saved.count
        if skipped > 0 {
            show(Toast(tone: .warning, text: skipped == 1 ? "That file isn't a picture AppFast Studio can read."
                                                          : "\(skipped) files aren't pictures AppFast Studio can read."))
        }
    }

    func removeDesignAttachment(_ path: String) {
        designAttachments.removeAll { $0 == path }
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Sends one design turn, with the app's instructions and the record it keeps afterwards.
    func sendDesign(_ turn: DesignTurn) {
        guard canSendDesign, let folder = project.readyFolder, let claude = studio.claude else { return }
        design.prepare()
        let instructions = DesignPrompts.instructions(for: turn, style: design.style, tokens: design.tokens, issues: design.issues(for: turn))
        let readable = [AgentBridge.screenshotDirectory.path, design.store?.previewsFolder.path].compactMap { $0 }
        designChat.send(turn.request, design: ChatModel.DesignCall(turn: turn, instructions: instructions, readableFolders: readable),
                        attachments: turn.references, folder: folder, claude: claude, profile: studio.profiles.active,
                        approve: designApprovalHandler(folder: folder),
                        finishing: { [weak self] reply, _ in self?.design.record(turn, reply: reply) })
    }

    /// Design turns edit only design/: anything else is refused without asking; reads outside it go to the user.
    func designApprovalHandler(folder: String) -> AgentPermissionHandler {
        let others = approvalHandler(folder: folder)
        return { request in
            if let reason = AgentPermissionPolicy.designRefusal(for: request) { return .deny(reason) }
            return await others(request)
        }
    }

    // MARK: Versions

    func chooseVersion(_ version: String, for screen: String) { design.choose(version, for: screen) }

    /// Builds a screen's chosen version into the app, from the main chat, changing only what differs.
    func applyDesign(to screenID: String) {
        guard let screen = design.library.screen(screenID), let version = screen.versions.chosen ?? screen.shown,
              version != DesignVersions.current, chatBlocker == nil, !chat.isSending else { return }
        let preview = design.previewURL(screen: screenID, version: version)?.path
        let current = screen.hasCapture ? design.store?.url(DesignPaths.capture(screenID)).path : nil
        let message = DesignHandoff.applyMessage(screen: screen, version: version, preview: preview, currentPreview: current)
        guard let folder = project.readyFolder, let claude = studio.claude else { return }
        isChatVisible = true
        chat.switchToBuild()
        chat.send(message, designApply: "\(screenID)/\(version)",
                  readableFolders: [design.store?.previewsFolder.path].compactMap { $0 },
                  folder: folder, claude: claude, profile: studio.profiles.active, approve: approvalHandler(folder: folder))
    }

    /// Why Apply to the App can't run for a screen, nil when it can.
    func applyBlocker(for screen: DesignLibrary.Screen) -> String? {
        if !(screen.versions.file != nil || designScreens.first(where: { $0.id == screen.id })?.isBuilt == true) {
            return "This screen isn't built yet. Build it from the plan."
        }
        guard let version = screen.versions.chosen, version != DesignVersions.current else { return "Choose a version first." }
        if screen.versions.inApp == version { return "The app already looks like \(version)." }
        return chatBlocker ?? (chat.isSending ? "Claude is busy in the main chat." : nil)
    }

    func designApplied(_ tag: String) {
        let parts = tag.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return }
        design.setInApp(parts[1], for: parts[0])
    }

    func designApplyUndone(_ tag: String) {
        guard let screen = tag.split(separator: "/").first.map(String.init) else { return }
        design.setInApp(design.library.screen(screen)?.hasCurrent == true ? DesignVersions.current : nil, for: screen)
    }

    // MARK: Undo

    /// Undoes a design answer, and every newer one first, as the main chat's Undo does.
    func undoDesign(_ message: ChatMessage) {
        guard let folder = project.readyFolder, !designChat.isSending else { return }
        let newestFirst = designChat.undoable
        guard let target = newestFirst.firstIndex(where: { $0.id == message.id }) else { return }
        var restored: [FileSnapshot.Change] = []
        for answer in newestFirst[...target] {
            guard let id = answer.checkpointID else { continue }
            do {
                restored += try CheckpointStore.restore(id: id, folder: folder)
                designChat.markUndone(answer.id)
            } catch {
                show(Toast(tone: .warning, text: error.localizedDescription))
                break
            }
        }
        design.refresh()
        applyEdits(restored, done: "Undone")
    }

    // MARK: Use this design

    /// Puts the look into the app: `design_theme.dart` from the tokens, the project's theme pointed at it, and the
    /// fonts bundled, as one undoable change recorded in the design chat.
    func approveDesign() {
        guard let folder = project.readyFolder, let tokens = design.tokens, let package = flutterProject?.name,
              designBlocker == nil, !designChat.isSending else { return }
        let store = DesignStore(folder: folder)
        let id = UUID()
        Task {
            let before = await FileSnapshot.taken(of: folder, keepingContents: true)
            var notes: [String] = []
            var licences: [String] = []
            if ThemeRenderer.needsGoogleFonts(tokens) {
                let (bundled, fontNotes) = await bundleFonts(tokens, store: store)
                licences = bundled
                notes += fontNotes
            }
            store.write(Data(ThemeRenderer.dart(tokens, licences: licences).utf8), to: ThemeRenderer.path)
            var wired = true
            if let theme = store.text(ThemeWiring.themePath) {
                switch ThemeWiring.wire(theme, package: package) {
                case .wired(let text): store.write(Data(text.utf8), to: ThemeWiring.themePath)
                case .alreadyWired: break
                case .notRecognized: wired = false
                }
            } else {
                wired = false
            }
            let after = await FileSnapshot.taken(of: folder)
            let changes = after.changes(since: before)
            let saved = !changes.isEmpty && CheckpointStore.save(id: id, folder: folder, changes: changes, before: before, after: after)
            var summary = "**The app now uses this design's look:** \(tokens.name), \(DesignStyle.named(tokens.style)?.name ?? tokens.style)."
            if !wired { summary += " Claude is connecting it to the app's theme in the main chat." }
            if !notes.isEmpty { summary += "\n\n" + notes.joined(separator: "\n") }
            designChat.appendLocal(request: "Use this design", reply: summary, files: changes, checkpointID: saved ? id : nil)
            design.refresh()
            refreshFlow()
            applyEdits(changes, done: "Updated")
            if !wired, chatBlocker == nil, !chat.isSending {
                isChatVisible = true
                chat.switchToBuild()
                sendChat("Make the app use DesignTheme.light and DesignTheme.dark from \(ThemeRenderer.path) as its theme and darkTheme. "
                         + "Keep everything else the theme file provides.")
            }
        }
    }

    /// `google_fonts` in pubspec and the font files in assets, so the fonts work offline and in store builds, with
    /// their licences. Returns the licences' asset paths and notes for the user.
    private func bundleFonts(_ tokens: DesignTokens, store: DesignStore) async -> (licences: [String], notes: [String]) {
        var notes: [String] = []
        var licences: [String] = []
        let service = GoogleFontsService()
        let cache = service.cache
        for (family, weights) in tokens.neededWeights.sorted(by: { $0.key < $1.key }) {
            if let licence = await service.licence(family: family), let data = try? Data(contentsOf: licence) {
                let path = PubspecAssets.fontsFolder + GoogleFontFile.licenceName(family: family)
                store.write(data, to: path)
                licences.append(path)
            } else {
                notes.append("\(family)'s licence couldn't be downloaded, so it isn't on the app's licence page yet.")
            }
            for weight in weights {
                let name = GoogleFontFile.name(family: family, weight: weight)
                let file = cache.appendingPathComponent(family.filter { !$0.isWhitespace }).appendingPathComponent(name)
                if let data = try? Data(contentsOf: file) {
                    store.write(data, to: PubspecAssets.fontsFolder + name)
                } else {
                    notes.append("\(family) wasn't downloaded, so the app fetches it when it runs.")
                }
            }
        }
        if let pubspec = store.text("pubspec.yaml") {
            store.write(Data(PubspecAssets.adding(to: pubspec).utf8), to: "pubspec.yaml")
            if !pubspec.contains("google_fonts:") {
                let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
                let output = try? await ProcessRunner(timeout: 180).run(
                    shell, ["-ilc", "cd \"$1\" && exec flutter pub add google_fonts", "flutter", store.folder])
                DesignModel.log.append("flutter pub add google_fonts → \(output?.status ?? -1)\n\(output?.stdout ?? "")\n\(output?.stderr ?? "")")
                if output?.status != 0 { notes.append("Couldn't add the google_fonts package. Run `flutter pub add google_fonts` in the project.") }
            }
        }
        return (licences, Array(Set(notes)).sorted())
    }

    // MARK: Events

    /// A design answer finished: read design/ again and carry on with the screens still to draw.
    func designSendingChanged() {
        guard !designChat.isSending else { return }
        design.refresh()
        guard let reply = designChat.messages.last, reply.role == .assistant else { return }
        if reply.error != nil {
            drawQueue = []
            return
        }
        if !drawQueue.isEmpty { drawNextQueued() }
    }
}
