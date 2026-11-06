import AppKit
import WebKit

/// Process-wide lifecycle that doesn't belong to any one model.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Being killed with SIGTERM (kill, pkill, a shutdown) skips willTerminate, which left the flutter tool
        // running with nobody to talk to it. Turn those signals into a normal quit so models can clean up.
        for signalNumber in [SIGTERM, SIGHUP, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { NSApplication.shared.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
        #if DEBUG
        Snapshot.scheduleIfRequested()
        #endif
    }

    /// Emulators this app booted outlive it, so ask whether to keep them running (or follow the saved answer).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Self.isSnapshotRun { return .terminateNow }
        let ours = EmulatorService.runningBootedByApp()
        let choice = AndroidQuitChoice(rawValue: UserDefaults.standard.string(forKey: AndroidQuitChoice.key) ?? "") ?? .ask
        switch choice.action(runningBootedByApp: ours.count) {
        case .quit:
            return .terminateNow
        case .shutDownThenQuit:
            Self.shutDownThenQuit(ours)
            return .terminateLater
        case .askUser:
            let alert = NSAlert()
            let names = ours.map(\.avdName).map { $0.replacingOccurrences(of: "_", with: " ") }
            alert.messageText = ours.count == 1 ? "\(names[0]) is still running." : "\(ours.count) Android emulators are still running."
            alert.informativeText = "Keep it running for next time? It starts much faster that way, but uses memory until you shut it down."
            alert.addButton(withTitle: "Keep Running")
            alert.addButton(withTitle: "Shut Down")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don't ask again"
            let shutDown = alert.runModal() == .alertSecondButtonReturn
            if alert.suppressionButton?.state == .on {
                UserDefaults.standard.set((shutDown ? AndroidQuitChoice.shutDown : .keep).rawValue, forKey: AndroidQuitChoice.key)
            }
            guard shutDown else { return .terminateNow }
            Self.shutDownThenQuit(ours)
            return .terminateLater
        }
    }

    private static func shutDownThenQuit(_ emulators: [RunningEmulator]) {
        Task {
            await EmulatorService.shutDown(emulators)
            await MainActor.run { NSApplication.shared.reply(toApplicationShouldTerminate: true) }
        }
    }

    /// A debug launch that only takes screenshots of the app's own windows; see `Snapshot`.
    static var isSnapshotRun: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment[Snapshot.pathKey] != nil
        #else
        false
        #endif
    }
}

#if DEBUG
/// Saves PNGs of the app's own windows, for checking UI changes without screen-recording permission.
///
///     MOBILE_STUDIO_SNAPSHOT=/tmp/shot          writes /tmp/shot-main.png (and -settings.png), then quits
///     MOBILE_STUDIO_SNAPSHOT_DELAY=8            seconds to wait first (default 6)
///     MOBILE_STUDIO_APPEARANCE=dark|light|contrast|contrast-dark   force an appearance
///     MOBILE_STUDIO_SNAPSHOT_KEYS=cmd+r,cmd+shift+y   press these shortcuts after 4 s (logged to snapshot.log)
///     MOBILE_STUDIO_SNAPSHOT_MAP=in,fit,pan:-300:200   zoom and pan the app flow map after 4 s (the menu bar doesn't refresh here)
///     MOBILE_STUDIO_SNAPSHOT_SETTINGS=1         also open and capture Settings
///     MOBILE_STUDIO_SNAPSHOT_LOG=1              open the build log drawer
///     MOBILE_STUDIO_SNAPSHOT_TREE=1             also write the view hierarchy, for layout bugs
///     MOBILE_STUDIO_SNAPSHOT_RUN=1              press Run as soon as it can (a real flutter run)
///     MOBILE_STUDIO_SNAPSHOT_TIMES=30,120       capture at each of these seconds (main-30.png, …) instead
///     MOBILE_STUDIO_SNAPSHOT_FIX=1              with RUN: press Fix with Claude when the run fails
///     MOBILE_STUDIO_SNAPSHOT_TOOLBAR=1          also write the toolbar's controls: label, enabled, value
///     MOBILE_STUDIO_SNAPSHOT_CHAT="message"     with RUN: send this chat message once the app runs
///     MOBILE_STUDIO_SNAPSHOT_UNDO_AFTER=20      then undo its edits this many seconds after the answer
///     MOBILE_STUDIO_SNAPSHOT_CHOOSE=1           or pick the recommended options of the answer's choice card
///     MOBILE_STUDIO_SNAPSHOT_SHEET=0|1|2        also open the New Project sheet on that step and write -sheet.png
///     MOBILE_STUDIO_SNAPSHOT_DIFF=lib/main.dart  also open that file's diff sheet and write -diff.png (add _DIFF_EDIT=1 for Edit mode)
///     MOBILE_STUDIO_SNAPSHOT_DIFF_SAVE="note"   then save a hand edit of that file (a comment) as the sheet's Save does,
///                                               capture History (-saved.png), undo it, and log both steps to snapshot.log
///     MOBILE_STUDIO_SNAPSHOT_KICKOFF=1          start the planning chat and ask for the plan (with a stand-in CLI)
///     MOBILE_STUDIO_SNAPSHOT_APPROVAL="message" send this chat message; a stand-in CLI that asks permission leaves the card open
///     MOBILE_STUDIO_SNAPSHOT_NEW_PROJECT=/tmp/x  create a project in that folder, run flutter analyze + test, log, quit
///     MOBILE_STUDIO_SNAPSHOT_DESIGN="open,redesign:Today,ask:Show me two calmer headers,shot"
///                                               open the Design window and run these steps, writing -design-N.png at each
///                                               "shot" and after each step; steps wait for Claude: open, look, screens,
///                                               dark, light, style:<id>, palette:<n>, pairing:<n>, use-look, redesign:<screen>,
///                                               capture:<screen>, select:<screen id>, ask:<text>, choose:<version>,
///                                               compare:<version>, approve, apply, wait:<seconds>, shot,
///                                               run (Run Again), sim:/screenshot|/tap?x=&y=|/paste?text= (writes -device-N.png)
///     MOBILE_STUDIO_SNAPSHOT_APPROVE=allow      during those steps, allow approval cards once (default: decline)
///     MOBILE_STUDIO_CLAUDE_CLI=/path/to/stub    use this claude executable instead of the installed one
///
/// Snapshot runs skip Claude's automatic project check, so they cost nothing.
enum Snapshot {
    static let pathKey = "MOBILE_STUDIO_SNAPSHOT"
    /// `ContentView` answers it with SwiftUI's openSettings; AppKit's showSettingsWindow: no longer opens it.
    static let openSettingsNotification = Notification.Name("MobileStudio.snapshot.openSettings")
    /// `ContentView` answers it by pressing Run once the workspace allows it.
    static let runNotification = Notification.Name("MobileStudio.snapshot.run")

    @MainActor
    static func scheduleIfRequested() {
        let env = ProcessInfo.processInfo.environment
        switch env["MOBILE_STUDIO_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        // What Increase Contrast gives, for this app only.
        case "contrast": NSApp.appearance = NSAppearance(named: .accessibilityHighContrastAqua)
        case "contrast-dark": NSApp.appearance = NSAppearance(named: .accessibilityHighContrastDarkAqua)
        default: break
        }
        if NewProjectSmokeTest.runIfRequested() { return }
        guard let base = env[pathKey] else { return }
        // Menus follow the focused window, so the app has to be frontmost for shortcuts to reach them.
        NSApp.activate()
        let delay = Double(env["MOBILE_STUDIO_SNAPSHOT_DELAY"] ?? "") ?? 6
        let settings = env["MOBILE_STUDIO_SNAPSHOT_SETTINGS"] == "1"
        let times = (env["MOBILE_STUDIO_SNAPSHOT_TIMES"] ?? "").split(separator: ",").compactMap { Double($0) }
        if let keys = env["MOBILE_STUDIO_SNAPSHOT_KEYS"] {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(Double(env["MOBILE_STUDIO_SNAPSHOT_KEYS_DELAY"] ?? "") ?? 4))
                if env["MOBILE_STUDIO_SNAPSHOT_MENUS"] == "1" { logMenus() }
                for key in keys.split(separator: ",") {
                    press(String(key))
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
        }
        if let steps = env["MOBILE_STUDIO_SNAPSHOT_MAP"] {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(Double(env["MOBILE_STUDIO_SNAPSHOT_KEYS_DELAY"] ?? "") ?? 4))
                guard let map = workspace?.flowMap else { return }
                for step in steps.split(separator: ",") {
                    let parts = step.split(separator: ":").map(String.init)
                    switch parts.first {
                    case "in": map.zoomIn()
                    case "out": map.zoomOut()
                    case "actual": map.actualSize()
                    case "fit": map.fit()
                    case "pan" where parts.count == 3: map.pan(by: CGSize(width: Double(parts[1]) ?? 0, height: Double(parts[2]) ?? 0))
                    default: break
                    }
                    try? await Task.sleep(for: .milliseconds(500))
                }
                log.append("SNAPSHOT map \(steps): \(map.percent)% fitted=\(map.isFitted)")
            }
        }
        if env["MOBILE_STUDIO_SNAPSHOT_KICKOFF"] == "1" {
            // The planning chat end to end: start it, answer once, ask for the plan. Needs a stand-in claude CLI.
            Task { @MainActor in
                guard let workspace else { return }
                for _ in 0..<60 where workspace.chatBlocker != nil { try? await Task.sleep(for: .seconds(1)) }
                workspace.startKickoff()
                for step in 0..<2 {
                    try? await Task.sleep(for: .seconds(1))
                    for _ in 0..<60 where workspace.chat.isSending { try? await Task.sleep(for: .seconds(1)) }
                    guard step == 0, let reply = workspace.chat.messages.last else {
                        if env["MOBILE_STUDIO_SNAPSHOT_BUILD_MILESTONE"] == "1" {
                            try? await Task.sleep(for: .seconds(2))
                            workspace.buildMilestone(0)
                        }
                        return
                    }
                    workspace.choose([ProductPlan.writeLabel], in: reply)
                }
            }
        }
        if let steps = env["MOBILE_STUDIO_SNAPSHOT_DESIGN"] {
            Task { @MainActor in await runDesignSteps(steps, base: base) }
        }
        if let message = env["MOBILE_STUDIO_SNAPSHOT_APPROVAL"] {
            Task { @MainActor in
                guard let workspace else { return }
                for _ in 0..<60 where workspace.chatBlocker != nil { try? await Task.sleep(for: .seconds(1)) }
                workspace.sendChat(message)
            }
        }
        if env["MOBILE_STUDIO_SNAPSHOT_RUN"] == "1" {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                NotificationCenter.default.post(name: runNotification, object: nil)
            }
        }
        Task { @MainActor in
            if times.isEmpty {
                try? await Task.sleep(for: .seconds(delay))
                capture(title: "main", to: base)
            } else {
                var elapsed = 0.0
                for time in times.sorted() {
                    try? await Task.sleep(for: .seconds(time - elapsed))
                    elapsed = time
                    capture(title: "main-\(Int(time))", to: base)
                }
            }
            if env["MOBILE_STUDIO_SNAPSHOT_SHEET"] != nil {
                workspace?.newProject()
                try? await Task.sleep(for: .seconds(2))
                captureSheet(to: base)
                workspace?.closeNewProjectSheet()
                try? await Task.sleep(for: .milliseconds(500))
            }
            if let path = env["MOBILE_STUDIO_SNAPSHOT_DIFF"] {
                workspace?.showDiff(of: .init(path: path, kind: .modified))
                try? await Task.sleep(for: .seconds(3))
                captureSheet(to: base, name: "diff")
                workspace?.diffFile = nil
                try? await Task.sleep(for: .milliseconds(500))
                if let note = env["MOBILE_STUDIO_SNAPSHOT_DIFF_SAVE"] { await saveAndUndoHandEdit(path, note: note, base: base) }
            }
            if settings {
                NotificationCenter.default.post(name: openSettingsNotification, object: nil)
                try? await Task.sleep(for: .seconds(2))
                capture(title: "settings", to: base, settings: true)
            }
            NSApp.terminate(nil)
        }
    }

    /// Drives the Design window through `MOBILE_STUDIO_SNAPSHOT_DESIGN`'s steps, capturing it as it goes.
    @MainActor
    private static func runDesignSteps(_ steps: String, base: String) async {
        guard let workspace else { return }
        let env = ProcessInfo.processInfo.environment
        for _ in 0..<60 where workspace.project.readyFolder == nil || workspace.studio.claude == nil {
            try? await Task.sleep(for: .seconds(1))
        }
        // The flow of screens is read in the background; redesign needs it.
        for _ in 0..<30 where workspace.screens.isEmpty { try? await Task.sleep(for: .seconds(1)) }
        var shot = 0
        func snap() async {
            shot += 1
            await captureWithWebViews(title: "design-\(shot)", to: base, window: "main")
        }
        func screen(named name: String) -> AppScreen? {
            workspace.screens.first { AppFlow.screenKey($0.name) == AppFlow.screenKey(name) }
        }
        for step in steps.split(separator: ",").map({ String($0).trimmingCharacters(in: .whitespaces) }) {
            let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
            let argument = parts.count > 1 ? parts[1] : ""
            let design = workspace.design
            log.append("SNAPSHOT design step \(step)")
            switch parts[0] {
            case "open": workspace.openDesign()
            case "look": design.stage = .look
            case "screens": design.stage = .screens
            case "dark": design.isDark = true
            case "light": design.isDark = false
            case "zoom": design.zoom = Double(argument) ?? design.zoom
            case "style": workspace.chooseStyle(argument)
            case "palette": if let index = Int(argument), design.suggestions.palettes.indices.contains(index) { design.paletteID = design.suggestions.palettes[index].id }
            case "pairing": if let index = Int(argument), design.suggestions.pairings.indices.contains(index) { design.pairingID = design.suggestions.pairings[index].id }
            case "use-look": workspace.useLook()
            case "redesign": if let screen = screen(named: argument) { workspace.redesign(screen) }
            case "capture": if let screen = screen(named: argument) { workspace.redesign(screen, capture: true) }
            case "select": design.selection = [argument]
            case "ask": workspace.sendDesignMessage(argument)
            case "choose": if let id = design.selection.first { workspace.chooseVersion(argument, for: id) }
            case "show": if let id = design.selection.first { design.shown[id] = argument }
            case "compare": design.comparing = argument
            case "approve": workspace.approveDesign()
            case "apply": if let id = design.selection.first { workspace.applyDesign(to: id) }
            case "wait": try? await Task.sleep(for: .seconds(Double(argument) ?? 2))
            case "run":
                // Run Again, as the toolbar would: stop an app an earlier run left, then build and run.
                if workspace.run.existing != nil || workspace.run.phase.isActive {
                    workspace.stopExistingApp()
                    workspace.stopApp()
                    try? await Task.sleep(for: .seconds(4))
                }
                for _ in 0..<60 where !workspace.canRun { try? await Task.sleep(for: .seconds(1)) }
                workspace.runApp()
                for _ in 0..<900 where workspace.run.phase != .running {
                    if case .failed = workspace.run.phase { break }
                    try? await Task.sleep(for: .seconds(1))
                }
                log.append("SNAPSHOT design run: \(workspace.run.phase) \(workspace.run.failure?.message ?? "")")
                try? await Task.sleep(for: .seconds(6))
            case "sim":
                // Drives the device like ms-sim: sim:/screenshot, sim:/tap?x=200&y=900, sim:/paste?text=Walk.
                if let command = SimulatorCommand(path: argument) {
                    let answer = await workspace.deviceModel.perform(command)
                    log.append("SNAPSHOT design sim \(argument): \(answer)")
                    if command == .screenshot, let path = answer.split(separator: "\n").first {
                        shot += 1
                        try? FileManager.default.copyItem(atPath: String(path), toPath: "\(base)-device-\(shot).png")
                    }
                }
            case "render":
                // Full-size pictures of the style samples, through the same renderer as the previews.
                let renderer = DesignRenderer()
                for style in DesignStyle.bundled where argument.isEmpty || argument == style.id {
                    await renderer.render(DesignURL.styleURL(style.id), folder: nil, dark: design.isDark,
                                          to: URL(fileURLWithPath: "\(base)-style-\(style.id).png"))
                }
            case "shot": break
            default: log.append("SNAPSHOT design: unknown step \(step)")
            }
            try? await Task.sleep(for: .seconds(2))
            // Wait for whichever chat is working, and the queue of screens to draw.
            for _ in 0..<900 where workspace.designChat.isSending || workspace.chat.isSending || !workspace.drawQueue.isEmpty {
                // Nobody can click an approval card here: answer it as MOBILE_STUDIO_SNAPSHOT_APPROVE says, and log it.
                if let pending = workspace.approvals.current {
                    let allow = env["MOBILE_STUDIO_SNAPSHOT_APPROVE"] == "allow"
                    log.append("SNAPSHOT design approval \(allow ? "allowed" : "declined"): \(pending.request.action.summary)")
                    workspace.approvals.answer(allow ? .allowOnce : .decline)
                }
                try? await Task.sleep(for: .seconds(1))
            }
            try? await Task.sleep(for: .seconds(3))
            let reply = workspace.designChat.messages.last
            log.append("SNAPSHOT design after \(step): sending=\(workspace.designChat.isSending) error=\(reply?.error ?? "-") files=\(reply?.files.map(\.path) ?? []) "
                       + "screens=\(design.library.screens.map { "\($0.id):\($0.files.sorted())" }) tokens=\(design.tokens?.name ?? "-") issues=\(design.tokenIssues) "
                       + "lint=\(design.lint.mapValues { $0.map(\.message) })")
            await snap()
        }
        log.append("SNAPSHOT design done")
        // Claude's turns take as long as they take, so the run ends here rather than at the delay.
        capture(title: "main", to: base)
        NSApp.terminate(nil)
    }

    /// Sends a shortcut such as "cmd+shift+y" through the menu bar, as a key press would.
    @MainActor
    private static func press(_ shortcut: String) {
        var parts = shortcut.lowercased().split(separator: "+").map(String.init)
        // "+" separates the parts, so the keys that are it or "-" go by name: "cmd+plus".
        let name = parts.removeLast()
        let key = ["plus": "+", "minus": "-"][name] ?? name
        var flags: NSEvent.ModifierFlags = []
        if parts.contains("cmd") { flags.insert(.command) }
        if parts.contains("shift") { flags.insert(.shift) }
        if parts.contains("opt") { flags.insert(.option) }
        if parts.contains("ctrl") { flags.insert(.control) }
        let window = NSApp.windows.first { $0.isVisible }
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                           windowNumber: window?.windowNumber ?? 0, context: nil,
                                           characters: key, charactersIgnoringModifiers: key,
                                           isARepeat: false, keyCode: 0) else { return }
        let before = state
        let handled = NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
        log.append("SNAPSHOT key \(shortcut): \(handled ? "handled by the menu" : "NOT handled")\n  before: \(before)\n  after:  \(state)")
    }

    static let log = DiagnosticLog(name: "snapshot")
    /// Set by `MobileStudioApp`, so key presses can be logged with the state they changed.
    @MainActor static weak var workspace: Workspace?

    @MainActor
    private static var state: String {
        guard let w = workspace else { return "no workspace" }
        return "active=\(NSApp.isActive) key=\(NSApp.keyWindow?.identifier?.rawValue ?? "none") chat=\(w.isChatVisible) log=\(w.isLogVisible) canRun=\(w.canRun) blocker=\(w.runBlocker ?? "-") "
            + "existing=\(w.run.existing != nil) phase=\(w.run.phase) map=\(w.flowMap.percent)% fitted=\(w.flowMap.isFitted) placed=\(w.flowMap.isPlaced) canResize=\(w.menuState.canResizeMap)"
    }

    /// Every menu item with a shortcut, and whether it is enabled right now.
    @MainActor
    private static func logMenus() {
        func walk(_ menu: NSMenu, _ path: String) -> [String] {
            menu.update()
            return menu.items.flatMap { item -> [String] in
                var lines: [String] = []
                if !item.keyEquivalent.isEmpty {
                    lines.append("\(path) › \(item.title) [\(item.keyEquivalentModifierMask.rawValue):\(item.keyEquivalent)] \(item.isEnabled ? "enabled" : "disabled")")
                }
                if let sub = item.submenu { lines += walk(sub, path.isEmpty ? item.title : "\(path) › \(item.title)") }
                return lines
            }
        }
        log.append("MENUS\n" + (NSApp.mainMenu.map { walk($0, "") } ?? []).joined(separator: "\n"))
    }

    @MainActor
    @discardableResult
    private static func capture(title: String, to base: String, settings: Bool = false, window name: String = "main") -> NSBitmapImageRep? {
        let windows = NSApp.windows.filter { $0.isVisible && $0.frame.width > 300 }
        let isSettings = { (window: NSWindow) in window.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true }
        let window = settings ? windows.first(where: isSettings)
                              : windows.first { !isSettings($0) && $0.identifier?.rawValue.contains(name) == true } ?? windows.first
        // The theme frame includes the title bar and toolbar, not just the content.
        guard let root = window?.contentView?.superview,
              let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return nil }
        root.cacheDisplay(in: root.bounds, to: rep)
        // cacheDisplay leaves what sits on a visual-effect view (sidebar, inspector) blank, so draw each
        // of those views on its own and paste it in place, over the window background.
        // The sidebar and inspector are SwiftUI hosting views inside glass containers, which cacheDisplay
        // skips from the root. Panel-sized ones are drawn on their own and pasted over a plain background.
        let panels = descendants(of: root).filter {
            !$0.isHidden && "\(type(of: $0))".hasPrefix("NSHostingView")
                && $0.bounds.width > 100 && $0.bounds.width < root.bounds.width * 0.6
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        root.effectiveAppearance.performAsCurrentDrawingAppearance {
            // The toolbar floats over full-height panels on macOS 26, so keep it on top.
            let content = window?.contentLayoutRect ?? root.bounds
            NSBezierPath(rect: content).setClip()
            // Scroll views outside the panels (the app flow map) are skipped too, so paste what each one shows.
            for clip in descendants(of: root) where clip is NSClipView && !clip.isHidden && clip.bounds.width > 100
                && !panels.contains(where: { clip.isDescendant(of: $0) }) {
                guard let clipRep = clip.bitmapImageRepForCachingDisplay(in: clip.bounds) else { continue }
                clip.cacheDisplay(in: clip.bounds, to: clipRep)
                clipRep.draw(in: clip.convert(clip.bounds, to: root), from: .zero, operation: .sourceOver,
                             fraction: 1, respectFlipped: true, hints: nil)
            }
            for panel in panels {
                let frame = panel.convert(panel.bounds, to: root)
                NSColor.windowBackgroundColor.setFill()
                frame.fill()
                guard let panelRep = panel.bitmapImageRepForCachingDisplay(in: panel.bounds) else { continue }
                panel.cacheDisplay(in: panel.bounds, to: panelRep)
                panelRep.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                // List rows (the sidebar's outline view) are skipped even from the panel, so paste them too.
                for row in descendants(of: panel) where row is NSTableRowView && !row.isHidden {
                    guard let rowRep = row.bitmapImageRepForCachingDisplay(in: row.bounds) else { continue }
                    row.cacheDisplay(in: row.bounds, to: rowRep)
                    rowRep.draw(in: row.convert(row.bounds, to: root), from: .zero, operation: .sourceOver,
                                fraction: 1, respectFlipped: true, hints: nil)
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(base)-\(title).png"))
        if ProcessInfo.processInfo.environment["MOBILE_STUDIO_SNAPSHOT_TOOLBAR"] == "1", let items = window?.toolbar?.items {
            let lines = items.map { item in
                let controls = item.view.map { descendants(of: $0) + [$0] } ?? []
                let disabled = controls.compactMap { $0 as? NSControl }.contains { !$0.isEnabled }
                return "\(item.itemIdentifier.rawValue) label=\"\(item.label)\" enabled=\(item.isEnabled && !disabled)"
            }
            try? lines.joined(separator: "\n").write(toFile: "\(base)-\(title)-toolbar.txt", atomically: true, encoding: .utf8)
        }
        if ProcessInfo.processInfo.environment["MOBILE_STUDIO_SNAPSHOT_TREE"] == "1" {
            try? tree(root, root: root, depth: 0).write(toFile: "\(base)-\(title).txt", atomically: true, encoding: .utf8)
        }
        return rep
    }

    /// `capture`, plus what each web view shows: those draw in WebKit's own process, which cacheDisplay can't see,
    /// so the mockups are pasted in from their own snapshots.
    @MainActor
    private static func captureWithWebViews(title: String, to base: String, window name: String) async {
        let path = "\(base)-\(title).png"
        guard let rep = capture(title: title, to: base, window: name),
              let window = NSApp.windows.first(where: { $0.isVisible && $0.identifier?.rawValue.contains(name) == true }),
              let root = window.contentView?.superview, let content = window.contentView else { return }
        // The window's one hosting view fills it, so `capture` skipped it as too wide to be a panel: draw it here, over
        // the window background, keeping the title bar `capture` drew.
        if let contentRep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: contentRep)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            root.effectiveAppearance.performAsCurrentDrawingAppearance {
                let frame = content.convert(content.bounds, to: root)
                NSBezierPath(rect: window.contentLayoutRect).setClip()
                NSColor.windowBackgroundColor.setFill()
                frame.fill()
                contentRep.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                // cacheDisplay skips what scroll views show, so paste each one's contents back on top.
                for clip in descendants(of: content) where clip is NSClipView && !clip.isHidden && clip.bounds.width > 50 {
                    guard let clipRep = clip.bitmapImageRepForCachingDisplay(in: clip.bounds) else { continue }
                    clip.cacheDisplay(in: clip.bounds, to: clipRep)
                    clipRep.draw(in: clip.convert(clip.bounds, to: root), from: .zero, operation: .sourceOver,
                                 fraction: 1, respectFlipped: true, hints: nil)
                }
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        let webViews = descendants(of: root).compactMap { $0 as? WKWebView }.filter { !$0.isHidden && $0.window != nil }
        var pictures: [(NSImage, CGRect, CGRect)] = []
        for webView in webViews {
            let visible = webView.visibleRect
            guard visible.width > 1, visible.height > 1, let picture = try? await webView.takeSnapshot(configuration: nil) else { continue }
            // Only the part a scroll view shows: the paste doesn't go through its clipping.
            pictures.append((picture, webView.convert(webView.bounds, to: root), webView.convert(visible, to: root)))
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSBezierPath(rect: window.contentLayoutRect).setClip()
        for (picture, frame, visible) in pictures {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: visible).addClip()
            picture.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// Saves a comment into `path` through `Workspace.saveManualEdit`, shows the result, then undoes it, logging what happened.
    @MainActor
    private static func saveAndUndoHandEdit(_ path: String, note: String, base: String) async {
        guard let workspace, let folder = workspace.project.readyFolder else { return log.append("HAND EDIT: no project is open") }
        let url = URL(fileURLWithPath: folder).appendingPathComponent(path)
        func text() -> String? { try? String(contentsOf: url, encoding: .utf8) }
        guard let old = text() else { return log.append("HAND EDIT: \(path) can't be read") }
        do {
            try await workspace.saveManualEdit(path: path, content: old + "// \(note)\n", replacing: old)
            let entry = workspace.chat.messages.last
            log.append("HAND EDIT saved: file changed = \(text() != old), history = \(entry?.text ?? "none"), files = \(entry?.files.map(\.path) ?? []), undoable = \(workspace.chat.undoable.count)")
            try? await Task.sleep(for: .seconds(1))
            capture(title: "saved", to: base)
            if let latest = workspace.chat.undoable.first { workspace.undo(latest) }
            log.append("HAND EDIT undone: file restored = \(text() == old), undoable = \(workspace.chat.undoable.count), toast = \(workspace.toast?.text ?? "none")")
        } catch {
            log.append("HAND EDIT failed: \(error.localizedDescription)")
        }
    }

    /// The sheet is its own window, so `capture` doesn't include it.
    @MainActor
    private static func captureSheet(to base: String, name: String = "sheet") {
        guard let root = NSApp.windows.first(where: { $0.isSheet && $0.isVisible })?.contentView?.superview,
              let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
        root.cacheDisplay(in: root.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(base)-\(name).png"))
    }

    @MainActor
    private static func tree(_ view: NSView, root: NSView, depth: Int) -> String {
        let frame = view.convert(view.bounds, to: root).integral
        let line = String(repeating: "  ", count: depth) + "\(type(of: view)) \(frame)\(view.isHidden ? " hidden" : "")\n"
        return line + view.subviews.map { tree($0, root: root, depth: depth + 1) }.joined()
    }

    @MainActor
    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
#endif
