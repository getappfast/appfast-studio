import Foundation
import Observation

/// The Design window's state for the open project: what's in `design/`, what is selected and shown, the look step's
/// picks, and pictures of the mockups. Claude's turns are started by `Workspace`, which owns the design chat; this
/// model reads and writes the files around them.
@MainActor
@Observable
final class DesignModel {
    enum Stage: Equatable { case look, screens }

    enum FontState: Equatable {
        case downloading
        case ready
        case failed(String)
    }

    private(set) var folder: String?
    private(set) var library = DesignLibrary()
    /// The look in `design/tokens.json`, when it can be read.
    private(set) var tokens: DesignTokens?
    /// What's wrong with tokens.json, for Claude and the window.
    private(set) var tokenIssues: [String] = []
    /// Lint issues by mockup path.
    private(set) var lint: [String: [DesignLint.Issue]] = [:]
    private(set) var suggestions = LookSuggestions()
    /// Bumped whenever files on disk change, so artboards load them again.
    private(set) var revision = 0
    private(set) var fonts: [String: FontState] = [:]
    /// Mockup pictures by "screen/version", light.
    private(set) var previews: [String: URL] = [:]
    /// The Dart file of a redrawn screen changed since.
    private(set) var staleScreens: Set<String> = []

    var stage: Stage = .screens
    var selection: Set<String> = []
    /// The version each screen shows on the canvas, when not its chosen one.
    var shown: [String: String] = [:]
    /// A second version of the focused screen, shown next to it.
    var comparing: String?
    var isDark = false
    var zoom: Double = 0.45

    // The look step's picks.
    var styleID: String?
    var paletteID: String?
    var pairingID: String?

    /// What `design/` looked like at the last refresh, so coming back to the window doesn't reload every mockup.
    @ObservationIgnored private var seen: Int?
    @ObservationIgnored private let renderer = DesignRenderer()
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var fontTask: Task<Void, Never>?

    static let log = DiagnosticLog(name: "design")

    var store: DesignStore? { folder.map(DesignStore.init) }

    /// The screen the version strip is about: the only one selected.
    var focused: DesignLibrary.Screen? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return library.screen(id)
    }

    func shownVersion(of screen: DesignLibrary.Screen) -> String? {
        shown[screen.id].flatMap { screen.files.contains($0 + ".html") ? $0 : nil } ?? screen.shown
    }

    // MARK: Loading

    func load(folder: String?) {
        guard folder != self.folder else { return }
        self.folder = folder
        selection = []
        shown = [:]
        comparing = nil
        styleID = nil
        paletteID = nil
        pairingID = nil
        previews = [:]
        seen = nil
        refresh()
        stage = tokens == nil && library.screens.isEmpty ? .look : .screens
    }

    /// Reads `design/` again: after a turn, an undo, or the window coming forward.
    func refresh() {
        guard let store else {
            library = DesignLibrary()
            tokens = nil
            return
        }
        let before = store.fingerprint()
        if before == seen {
            // Only the app's code can have changed.
            let stale = Set(library.screens.compactMap { screen -> String? in
                guard screen.hasCurrent, let file = screen.versions.file, let hash = screen.versions.sourceHash else { return nil }
                return store.sourceHash(file) == hash ? nil : screen.id
            })
            if stale != staleScreens { staleScreens = stale }
            return
        }
        library = DesignLibrary.load(folder: store.folder)
        switch store.readTokens() {
        case .success(let read)?:
            tokens = read
            tokenIssues = read.issues(catalog: GoogleFontsCatalog.bundled)
            store.writeTokensCSS(read)
        case .failure(let error)?:
            tokenIssues = [error.message]
        case nil:
            tokens = nil
            tokenIssues = []
        }
        suggestions = store.readSuggestions(catalog: GoogleFontsCatalog.bundled)
        lint = store.lint(library, icons: IconCatalog.bundled)
        staleScreens = Set(library.screens.compactMap { screen in
            guard screen.hasCurrent, let file = screen.versions.file, let hash = screen.versions.sourceHash else { return nil }
            return store.sourceHash(file) == hash ? nil : screen.id
        })
        selection = selection.filter { library.screen($0) != nil }
        // Restyling an app with a look starts from keeping it.
        if paletteID == nil { paletteID = palettes.first?.id }
        if pairingID == nil { pairingID = pairings.first?.id }
        // After the writes above, so the next refresh compares against the files as they are now.
        seen = store.fingerprint()
        revision += 1
        if let tokens { downloadFonts(for: tokens) }
        renderPreviews()
    }

    /// Writes the README and kit, so Claude and the mockups have them before the first turn.
    func prepare() {
        store?.ensureKit()
        if let tokens { store?.writeTokensCSS(tokens) }
    }

    // MARK: Look step

    var style: DesignStyle? { (styleID ?? tokens?.style).flatMap(DesignStyle.named) }
    /// When restyling an app that has a look, keeping its colours and fonts is the first choice of each row.
    var palettes: [LookSuggestions.Palette] {
        let current = tokens.map {
            LookSuggestions.Palette(name: Self.currentName, mood: "The colours the app has now.", why: "Keep the app's colours.",
                                    light: $0.light, dark: $0.dark)
        }
        return (current.map { [$0] } ?? []) + suggestions.palettes
    }

    var pairings: [LookSuggestions.Pairing] {
        let current = tokens.map { LookSuggestions.Pairing(display: $0.fonts.display, body: $0.fonts.body, why: "The fonts the app has now.") }
        return (current.map { [$0] } ?? []) + suggestions.pairings.filter { $0.id != current?.id }
    }

    static let currentName = "Current"

    var palette: LookSuggestions.Palette? { palettes.first { $0.id == paletteID } }
    var pairing: LookSuggestions.Pairing? { pairings.first { $0.id == pairingID } }

    /// The look the step's picks make, for previews and Use this look.
    func lookTokens(palette: LookSuggestions.Palette? = nil, pairing: LookSuggestions.Pairing? = nil) -> DesignTokens? {
        LookSuggestions.tokens(style: style?.tokens ?? tokens, palette: palette ?? self.palette, pairing: pairing ?? self.pairing,
                               catalog: GoogleFontsCatalog.bundled)
    }

    /// tokens.css for a look that isn't saved yet, with whatever of its fonts is downloaded.
    func css(for look: DesignTokens) -> String {
        TokensCSS.css(look, fonts: DesignSchemeHandler.cachedFonts(for: look))
    }

    /// The screen drawn in the look step: the first version of the screen the look turn drew.
    var lookScreen: DesignLibrary.Screen? {
        library.screens.first { screen in screen.versions.versions.contains { $0.request.hasPrefix(Self.lookRequestPrefix) } }
            ?? library.screens.first
    }

    static let lookRequestPrefix = "Look: "

    /// Saves the picked look as tokens.json, with the fonts it needs. Returns false when nothing is picked.
    @discardableResult
    func useLook() -> Bool {
        guard let store, let look = lookTokens() else { return false }
        store.writeTokens(look)
        refresh()
        stage = .screens
        return true
    }

    /// Fetches the families a look uses, into the cache and the project's design/fonts/.
    func downloadFonts(for look: DesignTokens, install: Bool = true) {
        let needed = look.neededWeights.filter { fonts[$0.key] != .ready && fonts[$0.key] != .downloading }
        guard !needed.isEmpty else {
            if install { installFonts(for: look) }
            return
        }
        for family in needed.keys { fonts[family] = .downloading }
        let previous = fontTask
        fontTask = Task {
            await previous?.value
            let service = GoogleFontsService()
            for (family, weights) in needed.sorted(by: { $0.key < $1.key }) {
                do {
                    _ = try await service.files(family: family, weights: Array(weights))
                    fonts[family] = .ready
                } catch {
                    fonts[family] = .failed(error.localizedDescription)
                }
            }
            if install { installFonts(for: look) }
            revision += 1
        }
    }

    private func installFonts(for look: DesignTokens) {
        guard let store else { return }
        let cache = GoogleFontsService().cache
        let files = look.neededWeights.flatMap { family, weights in
            weights.map { cache.appendingPathComponent(family.filter { !$0.isWhitespace }).appendingPathComponent(GoogleFontFile.name(family: family, weight: $0)) }
        }.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty else { return }
        store.installFonts(files)
        store.writeTokensCSS(look)
    }

    /// The fonts the six style cards use, so their samples show in their own type.
    func downloadStyleFonts() {
        for style in DesignStyle.bundled { downloadFonts(for: style.tokens, install: false) }
    }

    // MARK: Versions

    /// Records what a design turn wrote, before the after-snapshot so Undo removes the record with the files.
    func record(_ turn: DesignTurn, reply: ChatMessage) {
        guard let store else { return }
        let summaries = Self.summaries(in: reply.text)
        switch turn.kind {
        case .look(let style, let start):
            styleID = style
            paletteID = nil
            pairingID = nil
            record(start, request: Self.lookRequestPrefix + turn.request, summaries: summaries, reply: reply, store: store)
        case .versions(let targets):
            for target in targets { record(target, request: turn.request, summaries: summaries, reply: reply, store: store) }
        case .current(let screen, let name, let file, _):
            guard store.exists(DesignPaths.html(screen, DesignVersions.current)) else { return }
            var versions = library.screen(screen)?.versions ?? DesignVersions(name: name, file: file)
            versions.name = name
            versions.file = file ?? versions.file
            versions.sourceHash = versions.file.flatMap(store.sourceHash)
            versions.inApp = DesignVersions.current
            store.writeVersions(versions, screen: screen)
        case .suggestions, .freeform:
            break
        }
    }

    private func record(_ target: DesignTurn.Target, request: String, summaries: [String: String], reply: ChatMessage, store: DesignStore) {
        let written = target.ids.filter { store.exists(DesignPaths.html(target.screenID, $0)) }
        guard !written.isEmpty else { return }
        var versions = library.screen(target.screenID)?.versions ?? DesignVersions(name: target.name)
        if versions.name.isEmpty { versions.name = target.name }
        versions.add(ids: written, parent: target.parent, request: request, summaries: summaries, messageID: reply.id)
        store.writeVersions(versions, screen: target.screenID)
        shown[target.screenID] = nil
    }

    /// "v4: the total moves to the top." lines of an answer, by version.
    nonisolated static func summaries(in text: String) -> [String: String] {
        var found: [String: String] = [:]
        for match in text.matches(of: /(?m)^\s*(?:[-*]\s*)?\**(v\d+)\**\s*[:—–-]\s*(.+)$/) {
            found[String(match.1)] = String(match.2).trimmingCharacters(in: .whitespaces)
        }
        return found
    }

    func choose(_ version: String, for screen: String) {
        guard let store, var versions = library.screen(screen)?.versions, versions.version(version) != nil else { return }
        versions.chosen = version
        store.writeVersions(versions, screen: screen)
        shown[screen] = nil
        refresh()
    }

    /// The app now matches this version (an apply turn changed the code), or no longer does (it was undone).
    func setInApp(_ version: String?, for screen: String) {
        guard let store, var versions = library.screen(screen)?.versions else { return }
        versions.inApp = version
        if let file = versions.file, version != nil { versions.sourceHash = store.sourceHash(file) }
        store.writeVersions(versions, screen: screen)
        refresh()
    }

    /// Lint issues of the files a turn will start from, and of tokens.json, for the prompt.
    func issues(for turn: DesignTurn) -> [String] {
        var paths: [String] = []
        if case .versions(let targets) = turn.kind {
            paths = targets.compactMap { target in target.parent.map { DesignPaths.html(target.screenID, $0) } }
        }
        return tokenIssues + paths.flatMap { lint[$0] ?? [] }.map { "\($0.file): \($0.message)" }
    }

    // MARK: Previews

    func previewURL(screen: String, version: String) -> URL? { previews["\(screen)/\(version)"] }

    /// The picture for a screen of App Flow: its chosen version, matched by name.
    func preview(forScreenNamed name: String) -> URL? {
        guard let screen = library.screen(named: name), let version = screen.shown else { return nil }
        return previewURL(screen: screen.id, version: version)
    }

    /// Draws every mockup whose picture is missing or older than it.
    func renderPreviews() {
        guard let store else { return }
        let folder = store.folder
        var known: [String: URL] = [:]
        var stale: [(screen: String, version: String)] = []
        for screen in library.screens {
            for file in screen.files {
                let version = String(file.dropLast(5))
                known["\(screen.id)/\(version)"] = store.previewURL(screen: screen.id, version: version)
                if store.previewIsStale(screen: screen.id, version: version) { stale.append((screen.id, version)) }
            }
        }
        previews = known.filter { FileManager.default.fileExists(atPath: $0.value.path) }
        guard !stale.isEmpty else { return }
        previewTask?.cancel()
        previewTask = Task {
            for item in stale {
                guard !Task.isCancelled, self.folder == folder else { return }
                let target = store.previewURL(screen: item.screen, version: item.version)
                let url = DesignURL.projectURL("screens/\(item.screen)/\(item.version).html")
                if await renderer.render(url, folder: folder, dark: false, to: target), self.folder == folder {
                    previews["\(item.screen)/\(item.version)"] = target
                }
            }
        }
    }
}
