import Foundation

/// Where the design files live in a project. Everything Claude may write in design mode is under `folder`.
enum DesignPaths {
    static let folder = "design"
    static let readme = "design/README.md"
    static let kit = "design/kit.css"
    static let tokens = "design/tokens.json"
    static let tokensCSS = "design/tokens.css"
    static let palettes = "design/look/palettes.json"
    static let fontPairings = "design/look/fonts.json"
    static let fonts = "design/fonts"
    static let screens = "design/screens"

    static func screen(_ id: String) -> String { "\(screens)/\(id)" }
    static func html(_ id: String, _ version: String) -> String { "\(screen(id))/\(version).html" }
    static func versions(_ id: String) -> String { "\(screen(id))/\(DesignVersions.fileName)" }
    static func capture(_ id: String) -> String { "\(screen(id))/current.png" }

    /// The folder name for a screen: "Habit form" and `HabitFormScreen` are both "habit_form".
    static func screenID(for name: String) -> String {
        var words: [String] = []
        var word = ""
        var previous: Character?
        for character in name {
            if character.isLetter || character.isNumber {
                // A capital after a lower-case letter starts a word, as in HabitForm.
                if character.isUppercase, let previous, previous.isLowercase, !word.isEmpty { words.append(word); word = "" }
                word.append(Character(character.lowercased()))
            } else if !word.isEmpty {
                words.append(word)
                word = ""
            }
            previous = character
        }
        if !word.isEmpty { words.append(word) }
        if words.count > 1, let last = words.last, ["screen", "page", "view"].contains(last) { words.removeLast() }
        return words.joined(separator: "_").nonEmpty ?? "screen"
    }
}

/// What's in a project's `design/` folder, read from disk. The versions come from each screen's `screen.json`;
/// a folder without one still shows, named from its mockup's `ms-screen` tag.
struct DesignLibrary: Equatable, Sendable {
    struct Screen: Equatable, Sendable, Identifiable {
        let id: String
        var versions: DesignVersions
        /// The HTML files in its folder: "current.html", "v1.html", …
        var files: Set<String>
        var hasCapture: Bool

        var name: String { versions.name }
        var hasCurrent: Bool { files.contains(DesignVersions.current + ".html") }
        var isEmpty: Bool { files.isEmpty }
        /// The version that stands for this screen: the chosen one, else the newest, else Current.
        var shown: String? { versions.chosen ?? versions.versions.last?.id ?? (hasCurrent ? DesignVersions.current : nil) }
    }

    var screens: [Screen] = []

    func screen(_ id: String) -> Screen? { screens.first { $0.id == id } }

    /// The screen of that name, matched the way the plan's screens are matched to the code's.
    func screen(named name: String) -> Screen? {
        let key = AppFlow.screenKey(name)
        return screens.first { AppFlow.screenKey($0.name) == key || AppFlow.screenKey($0.id) == key }
    }

    static func load(folder: String) -> DesignLibrary {
        let root = URL(fileURLWithPath: folder).appendingPathComponent(DesignPaths.screens)
        let fm = FileManager.default
        guard let ids = try? fm.contentsOfDirectory(atPath: root.path) else { return DesignLibrary() }
        var screens: [Screen] = []
        for id in ids.sorted() where !id.hasPrefix(".") {
            let directory = root.appendingPathComponent(id)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
            let files = Set(names.filter { $0.hasSuffix(".html") })
            var versions = (try? Data(contentsOf: directory.appendingPathComponent(DesignVersions.fileName)))
                .flatMap { try? JSONDecoder().decode(DesignVersions.self, from: $0) } ?? DesignVersions(name: "")
            if versions.name.isEmpty {
                let any = files.sorted().first.flatMap { try? String(contentsOf: directory.appendingPathComponent($0), encoding: .utf8) }
                versions.name = any.flatMap(Self.screenName(inHTML:)) ?? id.replacingOccurrences(of: "_", with: " ").capitalized
            }
            versions.prune(existingFiles: files)
            screens.append(Screen(id: id, versions: versions, files: files, hasCapture: names.contains("current.png")))
        }
        return DesignLibrary(screens: screens)
    }

    /// The name in `<meta name="ms-screen" content="Home">`.
    static func screenName(inHTML html: String) -> String? {
        html.firstMatch(of: /<meta\s+name\s*=\s*["']ms-screen["']\s+content\s*=\s*["']([^"']+)["']/.ignoresCase())
            .map { String($0.1).trimmingCharacters(in: .whitespaces) }?.nonEmpty
    }
}

/// What the build agent gets from the design: which files are the reference for which screen.
enum DesignHandoff {
    struct Reference: Equatable, Sendable {
        let screen: String
        let html: String
        /// A picture of it, outside the project.
        let preview: String?
    }

    /// The chosen version of every screen a milestone builds, in plan order.
    static func references(for milestone: Int, plan: ProductPlan, library: DesignLibrary,
                           preview: (DesignLibrary.Screen, String) -> String? = { _, _ in nil }) -> [Reference] {
        guard plan.milestones.indices.contains(milestone) else { return [] }
        let titles = Set(plan.milestones[milestone].features.map(AppFlow.screenKey))
        let features = (plan.mustHave + plan.canHave).filter { titles.contains(AppFlow.screenKey($0.title)) }
        var seen = Set<String>()
        var references: [Reference] = []
        for name in features.flatMap(\.screens) {
            guard let screen = library.screen(named: name), seen.insert(screen.id).inserted,
                  let version = screen.versions.chosen ?? screen.versions.versions.last?.id else { continue }
            references.append(Reference(screen: screen.name, html: DesignPaths.html(screen.id, version), preview: preview(screen, version)))
        }
        return references
    }

    /// The lines Build milestone adds to its message.
    static func milestoneNote(_ references: [Reference]) -> String? {
        guard !references.isEmpty else { return nil }
        let lines = references.map { reference in
            "- \(reference.screen): \(reference.html)" + (reference.preview.map { " (picture: \($0))" } ?? "")
        }
        return "Designs for this milestone, the reference for how these screens look:\n" + lines.joined(separator: "\n")
    }

    /// The build turn that applies a redesigned version to the screen's code.
    static func applyMessage(screen: DesignLibrary.Screen, version: String, preview: String?, currentPreview: String?) -> String {
        let target = DesignPaths.html(screen.id, version)
        var text = "Update the \(screen.name) screen"
        if let file = screen.versions.file { text += " (\(file))" }
        text += " to match the design \(target)."
        // How the screen looks now: the version applied last, else the redrawing of the code.
        let applied = screen.versions.inApp.flatMap { $0 != version && screen.files.contains($0 + ".html") ? $0 : nil }
        if let baseID = applied ?? (screen.hasCurrent ? DesignVersions.current : nil) {
            let base = DesignPaths.html(screen.id, baseID)
            text += " \(base) is how the screen looks now: change only what differs between \(base) and \(target), and keep everything else as it is."
        }
        var pictures: [String] = []
        if let preview { pictures.append("the design: \(preview)") }
        if let currentPreview { pictures.append("the app now: \(currentPreview)") }
        if !pictures.isEmpty { text += " Pictures: " + pictures.joined(separator: "; ") + "." }
        return text
    }
}
