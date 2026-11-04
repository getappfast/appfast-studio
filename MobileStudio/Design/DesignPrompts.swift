import Foundation

/// One turn of the design chat, as the app plans it: what Claude is asked to do, which files it must write, and
/// what the call may cost. The app picks the file names (`DesignVersions.nextIDs`), so Claude never overwrites a
/// version and the app knows what to record afterwards.
struct DesignTurn: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Draw the start screen in a style and suggest colour themes and font pairings.
        case look(style: String, start: Target)
        /// New colour themes or font pairings, with what the user said.
        case suggestions(Suggestions, hint: String?)
        /// Redraw a screen as it is built now, from its code (and a picture of it, when there is one).
        case current(screen: String, name: String, file: String?, hasCapture: Bool)
        /// New versions of one or more screens.
        case versions([Target])
        /// Anything else the user types with no screen selected.
        case freeform
    }

    enum Suggestions: String, Sendable { case palettes, pairings }

    /// One screen of a versions turn.
    struct Target: Equatable, Sendable {
        let screenID: String
        let name: String
        /// The version to start from, nil for a screen's first drawing.
        let parent: String?
        /// The files to write, "v4" for design/screens/<id>/v4.html.
        let ids: [String]
        /// What the plan says the screen is for, or its Dart file, for a screen not drawn yet.
        let about: String?
    }

    let kind: Kind
    /// The user's words, as the chat shows them.
    let request: String
    /// Reference pictures the user attached, as saved copies Claude reads before drawing.
    var references: [String] = []

    var model: String {
        if case .look = kind { return "opus" }
        return "sonnet"
    }

    var maxBudgetUSD: Double {
        switch kind {
        case .look: 3
        case .suggestions: 0.5
        case .current, .versions, .freeform: 2
        }
    }

    /// What Claude may change in this turn.
    var editablePattern: String {
        if case .suggestions = kind { return "\(DesignPaths.folder)/look/**" }
        return "\(DesignPaths.folder)/**"
    }

    /// The files this turn must write, relative to the project.
    var expectedFiles: [String] {
        switch kind {
        case .look(_, let start): start.ids.map { DesignPaths.html(start.screenID, $0) } + [DesignPaths.palettes, DesignPaths.fontPairings]
        case .suggestions(let kind, _): [kind == .palettes ? DesignPaths.palettes : DesignPaths.fontPairings]
        case .current(let screen, _, _, _): [DesignPaths.html(screen, DesignVersions.current)]
        case .versions(let targets): targets.flatMap { target in target.ids.map { DesignPaths.html(target.screenID, $0) } }
        case .freeform: []
        }
    }
}

/// The design chat's system prompt and each turn's instructions. Pure, so what Claude is told is testable.
enum DesignPrompts {
    /// Screens per turn: enough to keep a change consistent across them, few enough to undo as one.
    static let screensPerTurn = 4

    static func batches(_ targets: [DesignTurn.Target]) -> [[DesignTurn.Target]] {
        stride(from: 0, to: targets.count, by: screensPerTurn).map { Array(targets[$0..<min($0 + screensPerTurn, targets.count)]) }
    }

    /// How many versions a request asks for: "show me three", "2 options", "a few versions". One unless it says.
    static func versionCount(in text: String) -> Int {
        let lower = text.lowercased()
        let numbers = ["two": 2, "three": 3, "four": 4, "2": 2, "3": 3, "4": 4]
        for match in lower.matches(of: /\b(two|three|four|2|3|4)\s+(versions|options|variants|alternatives|ideas|ways|takes|designs)\b/) {
            if let count = numbers[String(match.1)] { return count }
        }
        if lower.contains(/\b(show me|give me) (two|three|four|2|3|4)\b/), let match = lower.firstMatch(of: /\b(two|three|four|2|3|4)\b/) {
            return numbers[String(match.1)] ?? 1
        }
        if lower.contains(/\b(a few|some|several) (versions|options|variants|alternatives|ideas)\b/) { return 3 }
        return 1
    }

    static let systemPrompt = """
        You are the designer inside Mobile Studio, a desktop app where people make Flutter apps without reading code. \
        In this chat you only make mockups: you change files in design/ and nothing else, and the app refuses any \
        other edit. The current directory is their project; read lib/ to understand the app when it helps.

        A mockup is one HTML file of a 393 × 852 pt phone screen, made only of the component kit in design/kit.css and \
        the tokens in design/tokens.css. Read design/README.md once: it lists every class, the Flutter widget it \
        stands for, and the rules. In short: layout only with .row/.column and the gap/pad classes (flexbox, no grid, \
        no floats, no absolute positioning except the kit's overlays); colours only through tokens or the colour \
        classes, never literal values; no font-family, no <script>, no <img>, nothing from the internet; icons as \
        <span class="icon">name</span> with names from Flutter's Icons class; pictures as <div class="image">caption\
        </div>. Every file starts with <meta name="ms-screen" content="Screen name"> and links ../../tokens.css and \
        ../../kit.css, with everything inside <div class="screen">. Use real text from the app or the plan, never \
        lorem ipsum. The app checks each mockup and sends back anything that breaks a rule; fix those first.

        Write only the files the message names, and never edit a version file that already exists: each request makes \
        new versions so the user can compare them. Keep what the user didn't ask to change exactly as it was in the \
        version you start from.

        Answer in two parts. First, one to three short plain sentences on what you drew, as the user will see it; for \
        several versions, one line per version starting with its name, like "v4: the total moves to the top." Then a \
        line with only `---`, then brief technical notes. If you end by offering options, put them last as a fenced \
        `choices` block holding JSON: {"question": "…", "multiple": false, "options": [{"label": "…", "detail": "…", \
        "recommended": true}]}.
        """

    /// What the app adds to the user's words for a turn.
    static func instructions(for turn: DesignTurn, style: DesignStyle?, tokens: DesignTokens?, issues: [String]) -> String {
        var parts: [String] = []
        switch turn.kind {
        case .look(let styleID, let start):
            let style = style ?? DesignStyle.named(styleID)
            let startFile = DesignPaths.html(start.screenID, start.ids.first ?? "v1")
            parts.append("""
                The user picked the \(style?.name ?? styleID) style for this app. \(style?.guidance ?? "")
                Read PLAN.md if it exists, and the app's code, to know what the app is. Then write three files:
                1. \(startFile): the \(start.name) screen, where the app opens, drawn in this style with real \
                content\(start.about.map { " (\($0))" } ?? "").
                2. \(DesignPaths.palettes): four colour themes for this app in this style, as \
                {"palettes": [{"name": "Calm water", "mood": "one short line", "why": "why it suits this app", \
                "light": {…}, "dark": {…}}]}. Each of light and dark has every role of design/tokens.json's schemes \
                (primary, onPrimary, primaryContainer, onPrimaryContainer, secondary, onSecondary, secondaryContainer, \
                onSecondaryContainer, surface, onSurface, surfaceContainer, onSurfaceVariant, outline, error, onError) as \
                "#RRGGBB". Text roles need 4.5:1 contrast on what they sit on (onSurfaceVariant 3:1); unreadable themes \
                are dropped. Make the four clearly different from each other.
                3. \(DesignPaths.fontPairings): three Google Fonts pairings, as {"pairings": [{"display": "Fraunces", \
                "body": "Inter", "why": "…"}]}. Prefer \((style?.fonts ?? []).joined(separator: ", ")); "system" means \
                the phone's own font. Only real Google Fonts families.
                Don't write tokens.json: the app makes it from what the user picks.
                """)
        case .suggestions(let kind, let hint):
            let current = kind == .palettes ? DesignPaths.palettes : DesignPaths.fontPairings
            parts.append("Rewrite \(current) with " + (kind == .palettes
                ? "four new colour themes, in the same JSON shape, different from the ones it has now."
                : "three new font pairings, in the same JSON shape, different from the ones it has now.")
                + (hint.map { " The user wants: \($0)." } ?? "") + " Change nothing else.")
        case .current(let screen, let name, let file, let hasCapture):
            parts.append("""
                Redraw the \(name) screen as it is built now, as \(DesignPaths.html(screen, DesignVersions.current)), by \
                reading its Dart code\(file.map { " (\($0))" } ?? "") and the widgets it uses. Draw what the code shows with \
                typical content, not an improvement. Anything the kit can't show (custom painting, charts, maps, real \
                images) becomes a labelled .image placeholder.
                """)
            if hasCapture {
                parts.append("\(DesignPaths.capture(screen)) is a picture of this screen in the running app: read it and match it.")
            }
            if tokens == nil {
                parts.append("""
                    There is no \(DesignPaths.tokens) yet. Write it too, taken from the app's ThemeData (lib/app/theme.dart \
                    or wherever MaterialApp's theme comes from): the same shape as Mobile Studio's tokens, \
                    {"style": one of "minimal", "soft", "bold", "editorial", "playful", "classic" (the nearest), "name", \
                    "mood", "light": {roles}, "dark": {roles}, "fonts": {"display", "body"}, "radius": {"small", "medium", \
                    "large"}, "elevation": "flat"|"subtle"|"raised", "borders": "none"|"hairline"|"bold", "density": \
                    "compact"|"comfortable"|"airy"}. Colours from ColorScheme.fromSeed are Material's tonal palette for \
                    that seed; work them out as closely as you can. A font the app doesn't set is "system".
                    """)
            }
        case .versions(let targets):
            for target in targets {
                let files = target.ids.map { DesignPaths.html(target.screenID, $0) }
                var line = "\(target.name): write \(files.joined(separator: " and "))"
                if let parent = target.parent {
                    line += ", starting from \(DesignPaths.html(target.screenID, parent))"
                } else if let about = target.about {
                    line += ". It is new: \(about)"
                }
                parts.append(line + ".")
            }
            if targets.contains(where: { $0.ids.count > 1 }) {
                parts.append("Where a screen gets several versions, make each a different answer to the request, and say in one line what each tries.")
            }
            if targets.count > 1 {
                parts.append("These screens belong together: apply the request the same way on each.")
            }
            parts.append("Versions can't change the tokens (colours, fonts, shapes are app-wide). If the request is really about those, draw the rest and say that Restyle the whole app changes them.")
        case .freeform:
            parts.append("No screen is selected. Answer, or change the mockups the request is about by writing new version files next to them (never edit existing ones).")
        }
        if let tokens, let style = style ?? DesignStyle.named(tokens.style), turn.kind != .freeform {
            if case .look = turn.kind {} else { parts.append("The app's style is \(style.name): \(style.guidance)") }
        }
        if !turn.references.isEmpty {
            let count = turn.references.count == 1 ? "a reference screenshot" : "\(turn.references.count) reference screenshots"
            parts.append("""
                The user attached \(count) to this request: \(turn.references.joined(separator: ", ")). Read \
                \(turn.references.count == 1 ? "it" : "them") with the Read tool before drawing. They show what the user \
                has in mind, so draw the request in line with them: the layout, the content and the look. The kit and the \
                tokens still apply, so take colours and fonts from the tokens rather than from the picture.
                """)
        }
        if !issues.isEmpty {
            parts.append("Fix these first:\n" + issues.prefix(12).map { "- \($0)" }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }
}
