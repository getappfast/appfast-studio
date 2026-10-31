import AppKit

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
            if settings {
                NotificationCenter.default.post(name: openSettingsNotification, object: nil)
                try? await Task.sleep(for: .seconds(2))
                capture(title: "settings", to: base, settings: true)
            }
            NSApp.terminate(nil)
        }
    }

    /// Sends a shortcut such as "cmd+shift+y" through the menu bar, as a key press would.
    @MainActor
    private static func press(_ shortcut: String) {
        var parts = shortcut.lowercased().split(separator: "+").map(String.init)
        let key = parts.removeLast()
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
            + "existing=\(w.run.existing != nil) phase=\(w.run.phase)"
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
    private static func capture(title: String, to base: String, settings: Bool = false) {
        let windows = NSApp.windows.filter { $0.isVisible && $0.frame.width > 300 }
        let isSettings = { (window: NSWindow) in window.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true }
        let window = settings ? windows.first(where: isSettings)
                              : windows.first { !isSettings($0) && $0.identifier?.rawValue.contains("main") == true } ?? windows.first
        // The theme frame includes the title bar and toolbar, not just the content.
        guard let root = window?.contentView?.superview,
              let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
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
