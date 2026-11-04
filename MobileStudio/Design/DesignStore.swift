import Foundation

/// Reads and writes a project's `design/` folder: the files the app owns (README, kit, tokens.css, screen.json,
/// fonts) and the ones it only reads (tokens.json, the mockups, the suggestions).
struct DesignStore: Sendable {
    let folder: String

    private var root: URL { URL(fileURLWithPath: folder) }

    func url(_ relative: String) -> URL { root.appendingPathComponent(relative) }

    /// A cheap stand-in for "did anything in `design/` change": names, sizes and times, not contents.
    func fingerprint() -> Int {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = FileManager.default.enumerator(at: root.appendingPathComponent(DesignPaths.folder),
                                                         includingPropertiesForKeys: keys) else { return 0 }
        var hasher = Hasher()
        var entries: [String] = []
        for case let file as URL in files {
            let values = try? file.resourceValues(forKeys: Set(keys))
            entries.append("\(file.path)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values?.fileSize ?? 0)")
        }
        entries.sort()
        for entry in entries { hasher.combine(entry) }
        return hasher.finalize()
    }

    func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: url(relative).path) }

    func data(_ relative: String) -> Data? { try? Data(contentsOf: url(relative)) }

    func text(_ relative: String) -> String? { data(relative).map { String(decoding: $0, as: UTF8.self) } }

    /// Writes only when the contents differ, so an unchanged file doesn't show as a change in the turn.
    @discardableResult
    func write(_ data: Data, to relative: String) -> Bool {
        if self.data(relative) == data { return false }
        let target = url(relative)
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: target, options: .atomic)) != nil
    }

    /// The README and the kit, as the app ships them now.
    func ensureKit() {
        if let readme = DesignResources.text("README.md") { write(Data(readme.utf8), to: DesignPaths.readme) }
        if let kit = DesignResources.text("kit.css") { write(Data(kit.utf8), to: DesignPaths.kit) }
    }

    /// Nil when there is no tokens.json yet.
    func readTokens() -> Result<DesignTokens, DesignFileError>? {
        data(DesignPaths.tokens).map(DesignTokens.decode)
    }

    func writeTokens(_ tokens: DesignTokens) { write(tokens.encoded(), to: DesignPaths.tokens) }

    func writeTokensCSS(_ tokens: DesignTokens) {
        write(Data(TokensCSS.css(tokens, fonts: fontFiles(for: tokens)).utf8), to: DesignPaths.tokensCSS)
    }

    func readSuggestions(catalog: GoogleFontsCatalog?) -> LookSuggestions {
        LookSuggestions.read(palettes: data(DesignPaths.palettes), pairings: data(DesignPaths.fontPairings), catalog: catalog)
    }

    func writeVersions(_ versions: DesignVersions, screen id: String) {
        write(versions.encoded(), to: DesignPaths.versions(id))
    }

    /// Every mockup's lint issues, by path relative to the project.
    func lint(_ library: DesignLibrary, icons: IconCatalog?) -> [String: [DesignLint.Issue]] {
        var found: [String: [DesignLint.Issue]] = [:]
        for screen in library.screens {
            for file in screen.files {
                let path = "\(DesignPaths.screen(screen.id))/\(file)"
                guard let html = text(path) else { continue }
                let issues = DesignLint.issues(in: html, file: path, icons: icons)
                if !issues.isEmpty { found[path] = issues }
            }
        }
        return found
    }

    /// The font files already in `design/fonts/` for the tokens' families and weights.
    func fontFiles(for tokens: DesignTokens) -> [TokensCSS.FontFile] {
        tokens.neededWeights.sorted { $0.key < $1.key }.flatMap { family, weights in
            weights.sorted().compactMap { weight -> TokensCSS.FontFile? in
                let name = GoogleFontFile.name(family: family, weight: weight)
                guard exists("\(DesignPaths.fonts)/\(name)") else { return nil }
                return TokensCSS.FontFile(family: family, weight: weight, italic: false, path: "fonts/\(name)")
            }
        }
    }

    /// Copies downloaded font files into `design/fonts/`, with a note on their licences.
    func installFonts(_ files: [URL]) {
        for file in files {
            if let data = try? Data(contentsOf: file) { write(data, to: "\(DesignPaths.fonts)/\(file.lastPathComponent)") }
        }
        let note = """
            These fonts come from Google Fonts (fonts.google.com) and are free to use under their own open licences, \
            most of them the SIL Open Font License 1.1. Each family's licence is on its page there, under License.

            """
        write(Data(note.utf8), to: "\(DesignPaths.fonts)/LICENSES.md")
    }

    /// A fingerprint of a Dart file, to notice the code changing after a screen was redrawn from it.
    func sourceHash(_ relative: String) -> String? { data(relative).map(FileSnapshot.hash) }

    // MARK: Previews

    /// Pictures of the mockups, outside the project: they're made again from the HTML whenever it changes.
    var previewsFolder: URL { ProjectStorage.directory("Design", for: folder) }

    /// Pictures attached to design requests, kept with the previews so Claude can read them from there.
    var referencesFolder: URL { previewsFolder.appendingPathComponent("References") }

    func previewURL(screen: String, version: String, dark: Bool = false) -> URL {
        previewsFolder.appendingPathComponent("\(screen)-\(version)-\(dark ? "dark" : "light").png")
    }

    /// The picture is missing or older than the mockup or the tokens it was drawn with.
    func previewIsStale(screen: String, version: String, dark: Bool = false) -> Bool {
        let picture = previewURL(screen: screen, version: version, dark: dark)
        guard let made = modified(picture) else { return true }
        let sources = [url(DesignPaths.html(screen, version)), url(DesignPaths.tokensCSS)]
        return sources.contains { (modified($0) ?? .distantPast) > made }
    }

    private func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
