import Foundation

/// One of the looks the user starts from (Minimal, Soft, …): default tokens, the fonts it suggests from, and
/// what the prompt tells Claude about it. Bundled as data (`Resources/Design/styles/<id>.json`), so adding a style
/// is a file, not code.
struct DesignStyle: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    /// One line for the card.
    let feel: String
    /// Families Claude picks pairings from first.
    let fonts: [String]
    /// What the style means for layout and components, for the prompt.
    let guidance: String
    /// Its sample's look, and the base a colour theme and fonts are combined with.
    let tokens: DesignTokens

    /// In the order the cards show them.
    static let order = ["minimal", "soft", "bold", "editorial", "playful", "classic"]

    static let bundled: [DesignStyle] = order.compactMap { id in
        DesignResources.url("styles/\(id).json").flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(DesignStyle.self, from: $0) }
    }

    static func named(_ id: String) -> DesignStyle? { bundled.first { $0.id == id } }

    /// The sample screen every style card draws.
    static var sampleHTML: String { DesignResources.text("styles/sample.html") ?? "" }

    /// The style whose words appear in a description, for Describe your own; Classic when none do.
    static func nearest(to description: String) -> String {
        matching(description.lowercased()) ?? "classic"
    }

    private static let words: [(String, [String])] = [
        ("minimal", ["minimal", "clean", "simple", "calm"]), ("soft", ["soft", "gentle", "pastel", "friendly", "cute"]),
        ("bold", ["bold", "high contrast", "strong", "confident", "brutal"]), ("editorial", ["editorial", "serif", "magazine", "elegant", "luxury"]),
        ("playful", ["playful", "fun", "bright", "colourful", "colorful", "kids"]), ("classic", ["material", "standard", "classic"]),
    ]

    private static func matching(_ text: String) -> String? {
        words.first { $0.1.contains { text.contains($0) } }?.0
    }

    /// The style a plan's look-and-feel decision points at, when it names one.
    static func recommended(for plan: ProductPlan?) -> String? {
        guard let plan else { return nil }
        let text = plan.decisions.filter { decision in
            let title = decision.title.lowercased()
            return ["look", "feel", "style", "design", "visual", "theme"].contains { title.contains($0) }
        }.map { "\($0.choice) \($0.why)" }.joined(separator: " ").lowercased()
        return matching(text)
    }
}

/// Claude's suggestions in the look step: colour themes (`design/look/palettes.json`) and font pairings
/// (`design/look/fonts.json`). The user picks one of each and the app combines them with the style.
struct LookSuggestions: Equatable, Sendable {
    struct Palette: Codable, Equatable, Sendable, Identifiable {
        let name: String
        let mood: String
        /// Why it suits this app.
        let why: String
        let light: DesignTokens.Scheme
        let dark: DesignTokens.Scheme
        var id: String { name }
    }

    struct Pairing: Codable, Equatable, Sendable, Identifiable {
        let display: String
        let body: String
        let why: String
        var id: String { display + "+" + body }
        var title: String { display == body ? display : "\(display) and \(body)" }
    }

    var palettes: [Palette] = []
    var pairings: [Pairing] = []
    /// Why suggestions were left out, to tell Claude next time.
    var dropped: [String] = []

    private struct PaletteFile: Codable { let palettes: [Palette] }
    private struct PairingFile: Codable { let pairings: [Pairing] }

    /// Reads both files, keeping only themes that are readable and fonts that exist.
    static func read(palettes: Data?, pairings: Data?, catalog: GoogleFontsCatalog?) -> LookSuggestions {
        var result = LookSuggestions()
        if let palettes {
            do {
                for palette in try JSONDecoder().decode(PaletteFile.self, from: palettes).palettes {
                    let issues = Self.tokens(style: DesignStyle.bundled.first?.tokens, palette: palette, pairing: nil)
                        .map { $0.issues(catalog: nil) } ?? []
                    if issues.isEmpty { result.palettes.append(palette) } else { result.dropped.append("\(palette.name): \(issues[0])") }
                }
            } catch {
                result.dropped.append(DesignFileError(file: "look/palettes.json", reason: DesignFileError.describe(error)).message)
            }
        }
        if let pairings {
            do {
                for pairing in try JSONDecoder().decode(PairingFile.self, from: pairings).pairings {
                    let missing = [pairing.display, pairing.body].filter { family in
                        family != DesignTokens.Fonts.system && catalog?.family(named: family) == nil && catalog != nil
                    }
                    if missing.isEmpty { result.pairings.append(pairing) } else { result.dropped.append("\(missing[0]) isn't a Google Fonts family.") }
                }
            } catch {
                result.dropped.append(DesignFileError(file: "look/fonts.json", reason: DesignFileError.describe(error)).message)
            }
        }
        return result
    }

    /// The style's tokens with a colour theme and fonts in place of its own. Weights a font doesn't have move to
    /// the nearest one it does, so a pairing never fails on a weight.
    static func tokens(style: DesignTokens?, palette: Palette?, pairing: Pairing?, catalog: GoogleFontsCatalog? = nil) -> DesignTokens? {
        guard var tokens = style else { return nil }
        if let palette {
            tokens.name = palette.name
            tokens.mood = palette.mood
            tokens.light = palette.light
            tokens.dark = palette.dark
        }
        if let pairing {
            tokens.fonts = DesignTokens.Fonts(display: pairing.display, body: pairing.body)
        }
        if let catalog {
            for style in DesignTokens.typeStyles {
                let family = DesignTokens.usesDisplayFont(style) ? tokens.fonts.display : tokens.fonts.body
                guard let font = catalog.family(named: family), let value = tokens.typeScale[style], !font.has(weight: value.weight) else { continue }
                tokens.typeScale[style]?.weight = font.nearest(to: value.weight)
            }
        }
        return tokens
    }

    static func encode(palettes: [Palette]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(PaletteFile(palettes: palettes))) ?? Data()
    }

    static func encode(pairings: [Pairing]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(PairingFile(pairings: pairings))) ?? Data()
    }
}

/// Adds the bundled fonts' folder to a project's `pubspec.yaml`, keeping the rest of the file as it is.
enum PubspecAssets {
    static let fontsFolder = "assets/google_fonts/"

    static func adding(_ folder: String = fontsFolder, to pubspec: String) -> String {
        var lines = pubspec.components(separatedBy: "\n")
        let entry = "    - \(folder)"
        if lines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == "- \(folder)" }) { return pubspec }
        // The top-level `flutter:` key, not the SDK dependency (indented) or `flutter_lints:`.
        let isFlutterKey = { (line: String) -> Bool in
            guard line.hasPrefix("flutter:") else { return false }
            let rest = line.dropFirst("flutter:".count).trimmingCharacters(in: .whitespaces)
            return rest.isEmpty || rest.hasPrefix("#")
        }
        guard let flutter = lines.firstIndex(where: isFlutterKey) else {
            let trimmed = pubspec.hasSuffix("\n") ? pubspec : pubspec + "\n"
            return trimmed + "\nflutter:\n  assets:\n\(entry)\n"
        }
        // The flutter: section runs until the next line that starts at the margin.
        var end = flutter + 1
        while end < lines.count, lines[end].isEmpty || lines[end].hasPrefix(" ") || lines[end].hasPrefix("\t") { end += 1 }
        while end > flutter + 1, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
        if let assets = lines[(flutter + 1)..<end].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "assets:" }) {
            var insert = assets + 1
            while insert < end, lines[insert].trimmingCharacters(in: .whitespaces).hasPrefix("- ") { insert += 1 }
            lines.insert(entry, at: insert)
        } else {
            lines.insert(contentsOf: ["  assets:", entry], at: end)
        }
        return lines.joined(separator: "\n")
    }
}
