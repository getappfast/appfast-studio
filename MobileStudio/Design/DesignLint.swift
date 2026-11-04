import Foundation

/// Checks a mockup against the design vocabulary: only the kit's classes, flexbox layout, colours from the tokens,
/// Flutter's icon names, no scripts and nothing from the network. What it finds goes back to Claude to fix, because
/// whatever breaks a rule here is something the build can't copy faithfully.
enum DesignLint {
    struct Issue: Equatable, Sendable {
        let file: String
        let message: String
    }

    static func issues(in html: String, file: String, icons: IconCatalog?) -> [Issue] {
        var found: [String] = []
        let lower = html.lowercased()
        if lower.contains("<script") { found.append("Uses JavaScript, which mockups don't run. Remove the <script>.") }
        if lower.contains("http://") || lower.contains("https://") { found.append("Loads something from the internet. Mockups only use the kit and tokens.css.") }
        if lower.contains("<img") { found.append("Uses <img>. Show pictures as <div class=\"image\">caption</div> placeholders.") }
        if !lower.contains("name=\"ms-screen\"") { found.append("Has no <meta name=\"ms-screen\" content=\"…\">, so the app can't tell which screen it is.") }
        if !lower.contains("class=\"screen") && !lower.contains("class='screen") { found.append("Has no element with class \"screen\" around it.") }

        let styles = styleText(in: html)
        if styles.contains(/display\s*:\s*grid/.ignoresCase()) { found.append("Uses CSS grid. Lay it out with .row and .column (flexbox).") }
        if styles.contains(/position\s*:\s*(absolute|fixed)/.ignoresCase()) {
            found.append("Positions something with absolute or fixed. Only the kit's .fab, .sheet, .dialog, .snackbar and .scrim float.")
        }
        if styles.contains(/float\s*:/.ignoresCase()) { found.append("Uses float. Lay it out with .row and .column.") }
        if let colour = styles.firstMatch(of: /(#[0-9a-fA-F]{3,8}\b|rgba?\(|hsla?\()/) {
            found.append("Uses a literal colour (\(colour.0)). Use the tokens, e.g. var(--primary), or a kit class.")
        }
        if styles.contains(/font-family\s*:/.ignoresCase()) { found.append("Sets font-family. Fonts come from the tokens through the type classes.") }

        let unknown = classes(in: html).subtracting(kitClasses).sorted()
        if !unknown.isEmpty { found.append("Uses classes the kit doesn't have: \(unknown.prefix(8).joined(separator: ", ")). See design/README.md.") }

        if let icons {
            let names = iconNames(in: html)
            let missing = names.filter { icons.codepoint(of: $0) == nil }
            if !missing.isEmpty {
                found.append("Uses icons Flutter doesn't have: \(Array(Set(missing)).sorted().prefix(8).joined(separator: ", ")). Use names from Flutter's Icons class.")
            }
        }
        return found.map { Issue(file: file, message: $0) }
    }

    /// Every class the kit defines. A test checks this against kit.css both ways.
    static let kitClasses: Set<String> = [
        "screen", "with-nav", "row", "column", "grow", "spacer", "scroll", "wrap", "center", "space-between", "justify-end",
        "align-start", "align-end", "align-stretch", "full",
        "gap-1", "gap-2", "gap-3", "gap-4", "gap-5", "gap-6", "pad-1", "pad-2", "pad-3", "pad-4", "pad-5", "pad-6",
        "pad-x-1", "pad-x-2", "pad-x-3", "pad-x-4", "pad-y-1", "pad-y-2", "pad-y-3", "pad-y-4",
        "display-large", "display-medium", "display-small", "headline-large", "headline-medium", "headline-small",
        "title-large", "title-medium", "title-small", "body-large", "body-medium", "body-small",
        "label-large", "label-medium", "label-small",
        "text-primary", "text-secondary", "text-variant", "text-error", "bg-primary", "bg-primary-container",
        "bg-secondary-container", "bg-surface-container", "rounded-s", "rounded-m", "rounded-l",
        "icon", "small", "large", "icon-unknown",
        "app-bar", "app-bar-title", "card", "filled", "outlined", "list", "list-tile", "list-tile-title", "list-tile-subtitle",
        "button", "tonal", "text", "elevated", "icon-button", "fab", "extended",
        "text-field", "text-field-label", "text-field-input", "placeholder", "chip", "selected",
        "switch", "on", "checkbox", "radio", "slider", "progress", "progress-circular",
        "divider", "avatar", "badge", "nav-bar", "nav-item", "tab-bar", "tab", "segmented", "segment",
        "scrim", "sheet", "dialog", "snackbar", "image",
    ]

    /// The contents of `<style>` blocks and `style=""` attributes, where layout and colour rules hide.
    static func styleText(in html: String) -> String {
        var parts: [String] = []
        for match in html.matches(of: /(?s)<style[^>]*>(.*?)<\/style>/.ignoresCase()) { parts.append(String(match.1)) }
        for match in html.matches(of: /style\s*=\s*"([^"]*)"/.ignoresCase()) { parts.append(String(match.1)) }
        for match in html.matches(of: /style\s*=\s*'([^']*)'/.ignoresCase()) { parts.append(String(match.1)) }
        return parts.joined(separator: "\n")
    }

    static func classes(in html: String) -> Set<String> {
        var names = Set<String>()
        for match in html.matches(of: /class\s*=\s*["']([^"']*)["']/.ignoresCase()) {
            names.formUnion(match.1.split(whereSeparator: \.isWhitespace).map(String.init))
        }
        return names
    }

    /// The names inside `<span class="icon …">name</span>`.
    static func iconNames(in html: String) -> [String] {
        html.matches(of: IconSubstitution.pattern).map { String($0.2).trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}

/// Flutter's `Icons` names and their code points in the Material Icons font, from the file Flutter ships
/// (`bin/cache/artifacts/material_fonts/codepoints`), bundled with the app.
struct IconCatalog: Sendable {
    private let codepoints: [String: UInt32]

    init(text: String) {
        var map: [String: UInt32] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ")
            if parts.count == 2, let value = UInt32(parts[1], radix: 16) { map[String(parts[0])] = value }
        }
        codepoints = map
    }

    var count: Int { codepoints.count }

    func codepoint(of name: String) -> UInt32? { codepoints[name] }

    static let bundled: IconCatalog? = DesignResources.text("icon-codepoints.txt").map(IconCatalog.init)
}

/// The Material Icons font Flutter uses draws code points, not names, so the app swaps each icon's name for its
/// character when it serves a mockup. An unknown name becomes a dashed box, so it shows instead of raw text.
enum IconSubstitution {
    /// `<span class="icon small">water_drop</span>`: the classes, then the name.
    static var pattern: Regex<(Substring, Substring, Substring)> {
        /<span\s+class\s*=\s*["']((?:[^"']*\s)?icon(?:\s[^"']*)?)["']\s*>([^<]*)<\/span>/
    }

    static func apply(_ html: String, icons: IconCatalog) -> String {
        html.replacing(pattern) { match in
            let classes = String(match.1)
            let name = String(match.2).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let point = icons.codepoint(of: name), let scalar = Unicode.Scalar(point) else {
                return "<span class=\"\(classes) icon-unknown\" title=\"\(name)\"></span>"
            }
            return "<span class=\"\(classes)\" title=\"\(name)\">&#x\(String(scalar.value, radix: 16));</span>"
        }
    }
}
