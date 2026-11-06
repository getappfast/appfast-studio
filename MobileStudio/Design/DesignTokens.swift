import Foundation

/// The look of an app in one file, `design/tokens.json`: colours, fonts, shape, depth, spacing and type. The mockups
/// read it as CSS variables (`TokensCSS`) and the app as a Flutter theme (`ThemeRenderer`), so the two can't disagree.
struct DesignTokens: Codable, Equatable, Sendable {
    /// Material 3 colour roles, as "#RRGGBB".
    struct Scheme: Codable, Equatable, Sendable {
        var primary, onPrimary, primaryContainer, onPrimaryContainer: String
        var secondary, onSecondary, secondaryContainer, onSecondaryContainer: String
        var surface, onSurface, surfaceContainer, onSurfaceVariant, outline: String
        var error, onError: String

        /// Every role with its name, in the order the CSS and Dart list them.
        var roles: [(name: String, hex: String)] {
            [("primary", primary), ("onPrimary", onPrimary), ("primaryContainer", primaryContainer),
             ("onPrimaryContainer", onPrimaryContainer), ("secondary", secondary), ("onSecondary", onSecondary),
             ("secondaryContainer", secondaryContainer), ("onSecondaryContainer", onSecondaryContainer),
             ("surface", surface), ("onSurface", onSurface), ("surfaceContainer", surfaceContainer),
             ("onSurfaceVariant", onSurfaceVariant), ("outline", outline), ("error", error), ("onError", onError)]
        }

        /// Text colours and what they sit on, with the contrast each needs (WCAG AA: 4.5 for text, 3 for secondary text).
        var textPairs: [(text: String, background: String, label: String, minimum: Double)] {
            [(onPrimary, primary, "text on primary", 4.5),
             (onPrimaryContainer, primaryContainer, "text on primary containers", 4.5),
             (onSecondary, secondary, "text on secondary", 4.5),
             (onSecondaryContainer, secondaryContainer, "text on secondary containers", 4.5),
             (onSurface, surface, "text on the background", 4.5),
             (onSurface, surfaceContainer, "text on cards", 4.5),
             (onSurfaceVariant, surface, "secondary text", 3),
             (onError, error, "text on errors", 4.5)]
        }
    }

    struct Fonts: Codable, Equatable, Sendable {
        /// A Google Fonts family for display and headline text, or "system".
        var display: String
        /// A Google Fonts family for everything else, or "system".
        var body: String

        static let system = "system"
    }

    struct Radius: Codable, Equatable, Sendable {
        var small, medium, large: Double
    }

    enum Elevation: String, Codable, Sendable, CaseIterable { case flat, subtle, raised }
    enum Borders: String, Codable, Sendable, CaseIterable { case none, hairline, bold }
    enum Density: String, Codable, Sendable, CaseIterable {
        case compact, comfortable, airy

        /// The spacing unit the kit multiplies, in points.
        var unit: Int {
            switch self {
            case .compact: 6
            case .comfortable: 8
            case .airy: 10
            }
        }
    }

    struct TypeStyle: Codable, Equatable, Sendable {
        var size: Double
        var weight: Int
    }

    /// A `DesignStyle` id, such as "minimal".
    var style: String
    /// The colour theme's name: "Calm water".
    var name: String
    /// One sentence on how it feels.
    var mood: String
    var light: Scheme
    var dark: Scheme
    var fonts: Fonts
    var radius: Radius
    var elevation: Elevation
    var borders: Borders
    var density: Density
    /// The Material 3 type scale by style name ("displayLarge" … "labelSmall").
    var typeScale: [String: TypeStyle]

    static let fileName = "tokens.json"

    /// The fifteen Material 3 text styles, largest first.
    static let typeStyles = [
        "displayLarge", "displayMedium", "displaySmall", "headlineLarge", "headlineMedium", "headlineSmall",
        "titleLarge", "titleMedium", "titleSmall", "bodyLarge", "bodyMedium", "bodySmall",
        "labelLarge", "labelMedium", "labelSmall",
    ]

    /// Display and headline styles use the display font; the rest use the body font.
    static func usesDisplayFont(_ style: String) -> Bool { style.hasPrefix("display") || style.hasPrefix("headline") }

    /// Flutter's Material 3 defaults.
    static let materialTypeScale: [String: TypeStyle] = [
        "displayLarge": .init(size: 57, weight: 400), "displayMedium": .init(size: 45, weight: 400),
        "displaySmall": .init(size: 36, weight: 400), "headlineLarge": .init(size: 32, weight: 400),
        "headlineMedium": .init(size: 28, weight: 400), "headlineSmall": .init(size: 24, weight: 400),
        "titleLarge": .init(size: 22, weight: 400), "titleMedium": .init(size: 16, weight: 500),
        "titleSmall": .init(size: 14, weight: 500), "bodyLarge": .init(size: 16, weight: 400),
        "bodyMedium": .init(size: 14, weight: 400), "bodySmall": .init(size: 12, weight: 400),
        "labelLarge": .init(size: 14, weight: 500), "labelMedium": .init(size: 12, weight: 500),
        "labelSmall": .init(size: 11, weight: 500),
    ]

    /// Every weight each font needs for the type scale, for checking against the catalog and downloading.
    var neededWeights: [String: Set<Int>] {
        var weights: [String: Set<Int>] = [:]
        for style in Self.typeStyles {
            let family = Self.usesDisplayFont(style) ? fonts.display : fonts.body
            guard family != Fonts.system else { continue }
            weights[family, default: []].insert(typeScale[style]?.weight ?? 400)
        }
        // Buttons and labels in the kit and in Flutter also use the body font's regular weight.
        if fonts.body != Fonts.system { weights[fonts.body, default: []].insert(400) }
        return weights
    }

    /// What's wrong with these tokens, in words Claude and the user can act on. Empty when they can be used.
    func issues(catalog: GoogleFontsCatalog?) -> [String] {
        var issues: [String] = []
        for (label, scheme) in [("light", light), ("dark", dark)] {
            for role in scheme.roles where HexColor(role.hex) == nil {
                issues.append("The \(label) \(role.name) colour \"\(role.hex)\" isn't a #RRGGBB colour.")
            }
            for pair in scheme.textPairs {
                guard let text = HexColor(pair.text), let background = HexColor(pair.background) else { continue }
                let ratio = text.contrast(with: background)
                if ratio < pair.minimum {
                    issues.append(String(format: "In the %@ theme, %@ is hard to read (contrast %.1f:1, needs %.1f:1).",
                                         label, pair.label, ratio, pair.minimum))
                }
            }
        }
        for style in Self.typeStyles where typeScale[style] == nil {
            issues.append("The type scale has no \(style).")
        }
        for (style, value) in typeScale where !(8...96).contains(value.size) || !(100...900).contains(value.weight) || value.weight % 100 != 0 {
            issues.append("\(style) has size \(value.size) and weight \(value.weight); sizes go from 8 to 96 and weights from 100 to 900 in hundreds.")
        }
        for (name, radius) in [("small", radius.small), ("medium", radius.medium), ("large", radius.large)] where !(0...48).contains(radius) {
            issues.append("The \(name) corner radius \(radius) is outside 0–48.")
        }
        if let catalog {
            for (family, weights) in neededWeights.sorted(by: { $0.key < $1.key }) {
                guard let font = catalog.family(named: family) else {
                    issues.append("\(family) isn't a Google Fonts family. Pick one from fonts.google.com, or \"system\".")
                    continue
                }
                let missing = weights.filter { !font.has(weight: $0) }.sorted()
                if !missing.isEmpty {
                    issues.append("\(font.family) has no weight \(missing.map(String.init).joined(separator: ", ")); "
                                  + "it has \(font.weights.map(String.init).joined(separator: ", ")).")
                }
            }
        }
        return issues
    }
}

extension DesignTokens {
    /// Lenient about what can be filled in, so a file Claude wrote with a field missing still loads: the type scale,
    /// shape, depth and density fall back to Material's defaults. Colours and fonts must be there.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        style = try c.decodeIfPresent(String.self, forKey: .style) ?? "classic"
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Custom"
        mood = try c.decodeIfPresent(String.self, forKey: .mood) ?? ""
        light = try c.decode(Scheme.self, forKey: .light)
        dark = try c.decode(Scheme.self, forKey: .dark)
        fonts = try c.decodeIfPresent(Fonts.self, forKey: .fonts) ?? Fonts(display: Fonts.system, body: Fonts.system)
        radius = try c.decodeIfPresent(Radius.self, forKey: .radius) ?? Radius(small: 8, medium: 12, large: 16)
        elevation = try c.decodeIfPresent(Elevation.self, forKey: .elevation) ?? .subtle
        borders = try c.decodeIfPresent(Borders.self, forKey: .borders) ?? .none
        density = try c.decodeIfPresent(Density.self, forKey: .density) ?? .comfortable
        typeScale = Self.materialTypeScale.merging(try c.decodeIfPresent([String: TypeStyle].self, forKey: .typeScale) ?? [:]) { _, new in new }
    }

    static func decode(_ data: Data) -> Result<DesignTokens, DesignFileError> {
        do {
            return .success(try JSONDecoder().decode(DesignTokens.self, from: data))
        } catch {
            return .failure(DesignFileError(file: fileName, reason: DesignFileError.describe(error)))
        }
    }

    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(self)) ?? Data("{}".utf8)
    }
}

/// A design file that couldn't be read, with a reason Claude can fix.
struct DesignFileError: Error, Equatable, Sendable {
    let file: String
    let reason: String

    var message: String { "\(file) couldn't be read: \(reason)" }

    static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, let context):
            return "\(path(context.codingPath + [key])) is missing."
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
            return "\(path(context.codingPath)) has the wrong type."
        case DecodingError.dataCorrupted(let context):
            return context.codingPath.isEmpty ? "it isn't valid JSON." : "\(path(context.codingPath)) is invalid."
        default:
            return error.localizedDescription
        }
    }

    private static func path(_ keys: [CodingKey]) -> String {
        keys.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".").replacingOccurrences(of: ".[", with: "[")
    }
}

/// A colour from "#RRGGBB", with the maths for contrast.
struct HexColor: Equatable, Sendable {
    let red, green, blue: Double

    init?(_ hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("#") else { return nil }
        text.removeFirst()
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        red = Double((value >> 16) & 0xFF) / 255
        green = Double((value >> 8) & 0xFF) / 255
        blue = Double(value & 0xFF) / 255
    }

    /// WCAG relative luminance.
    var luminance: Double {
        func channel(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    func contrast(with other: HexColor) -> Double {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// "0xFFRRGGBB", for Dart's `Color`.
    var dart: String {
        String(format: "0xFF%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }
}

/// `tokens.css`: the tokens as CSS variables for the kit, with the fonts the mockups load.
enum TokensCSS {
    /// A font file the mockups can load, relative to `design/`.
    struct FontFile: Equatable, Sendable {
        let family: String
        let weight: Int
        let italic: Bool
        let path: String
    }

    static let fileName = "tokens.css"

    static func css(_ tokens: DesignTokens, fonts: [FontFile] = []) -> String {
        var out = ["/* Written by AppFast Studio from tokens.json (\(tokens.name), \(tokens.style)). Change tokens.json, not this file. */", ""]
        for font in fonts {
            out.append("@font-face { font-family: '\(cssEscaped(font.family))'; font-style: \(font.italic ? "italic" : "normal"); "
                       + "font-weight: \(font.weight); src: url('\(font.path)'); }")
        }
        if !fonts.isEmpty { out.append("") }
        out.append(":root {")
        out += variables(tokens.light).map { "  \($0)" }
        out.append("  --font-display: \(family(tokens.fonts.display));")
        out.append("  --font-body: \(family(tokens.fonts.body));")
        out.append("  --radius-s: \(px(tokens.radius.small)); --radius-m: \(px(tokens.radius.medium)); --radius-l: \(px(tokens.radius.large));")
        out.append("  --radius-button: \(px(tokens.radius.large));")
        out.append("  --space: \(tokens.density.unit)px;")
        out.append("  --card-shadow: \(cardShadow(tokens.elevation)); --raised-shadow: \(raisedShadow(tokens.elevation));")
        out.append("  --card-border: \(cardBorder(tokens.borders));")
        for style in DesignTokens.typeStyles {
            let value = tokens.typeScale[style] ?? DesignTokens.materialTypeScale[style]!
            out.append("  --\(kebab(style))-size: \(px(value.size)); --\(kebab(style))-weight: \(value.weight);")
        }
        out.append("}")
        out.append("@media (prefers-color-scheme: dark) {")
        out.append("  :root {")
        out += variables(tokens.dark).map { "    \($0)" }
        out.append("  }")
        out.append("}")
        return out.joined(separator: "\n") + "\n"
    }

    static func kebab(_ name: String) -> String {
        name.reduce(into: "") { result, character in
            if character.isUppercase { result += "-" + character.lowercased() } else { result.append(character) }
        }
    }

    private static func variables(_ scheme: DesignTokens.Scheme) -> [String] {
        scheme.roles.map { "--\(kebab($0.name)): \($0.hex);" }
    }

    private static func family(_ name: String) -> String {
        name == DesignTokens.Fonts.system ? "-apple-system, sans-serif" : "'\(cssEscaped(name))', -apple-system, sans-serif"
    }

    private static func cssEscaped(_ text: String) -> String { text.replacingOccurrences(of: "'", with: "\\'") }

    private static func px(_ value: Double) -> String {
        value.rounded() == value ? "\(Int(value))px" : String(format: "%.1fpx", value)
    }

    private static func cardShadow(_ elevation: DesignTokens.Elevation) -> String {
        switch elevation {
        case .flat: "none"
        case .subtle: "0 1px 3px rgba(0, 0, 0, 0.12)"
        case .raised: "0 4px 12px rgba(0, 0, 0, 0.18)"
        }
    }

    private static func raisedShadow(_ elevation: DesignTokens.Elevation) -> String {
        switch elevation {
        case .flat: "0 1px 2px rgba(0, 0, 0, 0.16)"
        case .subtle: "0 3px 8px rgba(0, 0, 0, 0.18)"
        case .raised: "0 8px 20px rgba(0, 0, 0, 0.24)"
        }
    }

    private static func cardBorder(_ borders: DesignTokens.Borders) -> String {
        switch borders {
        case .none: "none"
        case .hairline: "1px solid var(--outline)"
        case .bold: "2px solid var(--on-surface)"
        }
    }
}

/// `lib/app/design_theme.dart`: the tokens as a Flutter theme. The app's own theme file is pointed at it
/// (`ThemeWiring`) rather than replaced, so whatever else the project keeps there stays.
enum ThemeRenderer {
    static let path = "lib/app/design_theme.dart"

    /// Whether the theme uses the `google_fonts` package.
    static func needsGoogleFonts(_ tokens: DesignTokens) -> Bool {
        tokens.fonts.display != DesignTokens.Fonts.system || tokens.fonts.body != DesignTokens.Fonts.system
    }

    /// `licences` are asset paths of the bundled fonts' licences, registered for the app's licence page.
    static func dart(_ tokens: DesignTokens, licences: [String] = []) -> String {
        let fonts = needsGoogleFonts(tokens)
        var out: [String] = []
        if !licences.isEmpty { out.append("import 'package:flutter/foundation.dart';") }
        out.append("import 'package:flutter/material.dart';")
        if !licences.isEmpty { out.append("import 'package:flutter/services.dart';") }
        if fonts { out.append("import 'package:google_fonts/google_fonts.dart';") }
        out += [
            "",
            "/// Written by AppFast Studio from design/tokens.json (\(dartComment(tokens.name)), \(dartComment(tokens.style))).",
            "/// Change the design in AppFast Studio's Design window rather than this file: it is written again from there.",
            "class DesignTheme {",
            "  const DesignTheme._();",
            "",
            "  static final light = _build(_light);",
            "  static final dark = _build(_dark);",
            "",
            "  static const _light = \(scheme(tokens.light, brightness: "light"));",
            "",
            "  static const _dark = \(scheme(tokens.dark, brightness: "dark"));",
            "",
        ]
        if !licences.isEmpty {
            out += [
                "  static bool _licencesAdded = false;",
                "",
                "  /// The bundled Google Fonts' licences, for the app's licence page. Added once, the first time a theme is built.",
                "  static void _addFontLicences() {",
                "    if (_licencesAdded) return;",
                "    _licencesAdded = true;",
                "    LicenseRegistry.addLicense(() async* {",
                "      for (final file in const [\(licences.map(dartString).joined(separator: ", "))]) {",
                "        yield LicenseEntryWithLineBreaks(const ['google_fonts'], await rootBundle.loadString(file));",
                "      }",
                "    });",
                "  }",
                "",
            ]
        }
        out += [
            "  static ThemeData _build(ColorScheme scheme) {",
        ]
        if !licences.isEmpty { out.append("    _addFontLicences();") }
        out += [
            "    final base = ThemeData(useMaterial3: true, colorScheme: scheme);",
        ]
        // Each style goes through getFont: it takes and returns plain TextStyles, while google_fonts 9's getTextTheme
        // returns material_ui's TextTheme, which Flutter's ThemeData doesn't accept.
        out.append("    final text = base.textTheme;")
        for (name, family) in [("display", tokens.fonts.display), ("body", tokens.fonts.body)] {
            if family != DesignTokens.Fonts.system {
                out.append("    TextStyle? \(name)(TextStyle? style) => GoogleFonts.getFont(\(dartString(family)), textStyle: style);")
            } else {
                out.append("    TextStyle? \(name)(TextStyle? style) => style;")
            }
        }
        out.append("    return base.copyWith(")
        out.append("      textTheme: text.copyWith(")
        for style in DesignTokens.typeStyles {
            let value = tokens.typeScale[style] ?? DesignTokens.materialTypeScale[style]!
            let sized = "text.\(style)?.copyWith(fontSize: \(number(value.size)), fontWeight: FontWeight.w\(value.weight))"
            out.append("        \(style): \(DesignTokens.usesDisplayFont(style) ? "display" : "body")(\(sized)),")
        }
        out.append("      ),")
        out.append("      visualDensity: \(density(tokens.density)),")
        let side = borderSide(tokens.borders)
        out.append("      cardTheme: CardThemeData(")
        out.append("        elevation: \(cardElevation(tokens.elevation)),")
        out.append("        color: scheme.surfaceContainer,")
        out.append("        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(\(number(tokens.radius.medium)))\(side.map { ", side: \($0)" } ?? "")),")
        out.append("      ),")
        let button = "RoundedRectangleBorder(borderRadius: BorderRadius.circular(\(number(tokens.radius.large))))"
        out.append("      filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(shape: \(button))),")
        out.append("      outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(shape: \(button))),")
        out.append("      elevatedButtonTheme: ElevatedButtonThemeData(style: ElevatedButton.styleFrom(shape: \(button))),")
        out.append("      textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(shape: \(button))),")
        out.append("      floatingActionButtonTheme: FloatingActionButtonThemeData(")
        out.append("        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(\(number(tokens.radius.large)))),")
        out.append("      ),")
        out.append("      chipTheme: ChipThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(\(number(tokens.radius.small))))),")
        out.append("      inputDecorationTheme: InputDecorationTheme(")
        out.append("        border: OutlineInputBorder(borderRadius: BorderRadius.circular(\(number(tokens.radius.small)))),")
        out.append("      ),")
        out.append("    );")
        out.append("  }")
        out.append("}")
        return out.joined(separator: "\n") + "\n"
    }

    private static func scheme(_ scheme: DesignTokens.Scheme, brightness: String) -> String {
        var lines = ["ColorScheme(", "    brightness: Brightness.\(brightness),"]
        for role in scheme.roles {
            lines.append("    \(role.name): Color(\(HexColor(role.hex)?.dart ?? "0xFF000000")),")
        }
        lines.append("  )")
        return lines.joined(separator: "\n")
    }

    private static func density(_ density: DesignTokens.Density) -> String {
        switch density {
        case .compact: "VisualDensity.compact"
        case .comfortable: "VisualDensity.standard"
        case .airy: "VisualDensity.comfortable"
        }
    }

    private static func cardElevation(_ elevation: DesignTokens.Elevation) -> String {
        switch elevation {
        case .flat: "0"
        case .subtle: "1"
        case .raised: "4"
        }
    }

    private static func borderSide(_ borders: DesignTokens.Borders) -> String? {
        switch borders {
        case .none: nil
        case .hairline: "BorderSide(color: scheme.outline)"
        case .bold: "BorderSide(color: scheme.onSurface, width: 2)"
        }
    }

    private static func number(_ value: Double) -> String {
        value.rounded() == value ? "\(Int(value))" : String(format: "%.1f", value)
    }

    static func dartString(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "$", with: "\\$") + "'"
    }

    private static func dartComment(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
    }
}

/// Points the project's own theme at `DesignTheme`, keeping everything else in the file. The starter's `AppTheme`
/// builds both themes in `_build(Brightness)`, so that method is what gets replaced.
enum ThemeWiring {
    static let themePath = "lib/app/theme.dart"

    enum Outcome: Equatable {
        /// The new text of the theme file.
        case wired(String)
        /// It already uses `DesignTheme`.
        case alreadyWired
        /// The file isn't shaped like the starter's, so Claude has to wire it.
        case notRecognized
    }

    static func wire(_ text: String, package: String) -> Outcome {
        if text.contains("DesignTheme.") { return .alreadyWired }
        let signature = "static ThemeData _build(Brightness brightness)"
        guard let start = text.range(of: signature), let open = text[start.upperBound...].firstIndex(where: { !$0.isWhitespace }) else {
            return .notRecognized
        }
        var end: String.Index
        if text[open] == "{" {
            var depth = 0
            var index = open
            var closing: String.Index?
            while index < text.endIndex {
                if text[index] == "{" { depth += 1 }
                if text[index] == "}" {
                    depth -= 1
                    if depth == 0 { closing = index; break }
                }
                index = text.index(after: index)
            }
            guard let closing else { return .notRecognized }
            end = text.index(after: closing)
        } else if text[open...].hasPrefix("=>"), let semicolon = text[open...].firstIndex(of: ";") {
            end = text.index(after: semicolon)
        } else {
            return .notRecognized
        }
        var result = text
        result.replaceSubrange(start.lowerBound..<end, with: "static ThemeData _build(Brightness brightness) =>\n"
                               + "      brightness == Brightness.dark ? DesignTheme.dark : DesignTheme.light;")
        let importLine = "import 'package:\(package)/app/design_theme.dart';"
        if let lastImport = result.ranges(of: /(?m)^import [^\n]*;\n/).last {
            result.insert(contentsOf: importLine + "\n", at: lastImport.upperBound)
        } else {
            result = importLine + "\n\n" + result
        }
        return .wired(result)
    }
}
