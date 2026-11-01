import Foundation

/// Plain names for project files, for people who don't read code: "Home screen", not lib/ui/home/home_page.dart.
enum FriendlyName {
    static func of(_ path: String) -> String {
        let file = (path as NSString).lastPathComponent
        let ext = (file as NSString).pathExtension.lowercased()
        let stem = (file as NSString).deletingPathExtension
        let folders = path.split(separator: "/").dropLast().map(String.init)

        switch path {
        case "pubspec.yaml": return "Packages"
        case "pubspec.lock": return "Package versions"
        case "lib/main.dart": return "App start-up"
        case "analysis_options.yaml": return "Code style rules"
        default: break
        }
        for (platform, name) in [("ios", "iOS"), ("android", "Android"), ("macos", "macOS"), ("web", "Web")]
        where folders.first == platform {
            return "\(name) project settings"
        }
        if folders.first == "test" || folders.first == "integration_test" { return "Test: \(words(stem.replacingOccurrences(of: "_test", with: "")))" }
        if ["png", "jpg", "jpeg", "gif", "webp", "svg"].contains(ext) { return "Image: \(file)" }
        if ext == "arb" { return "Translations (\(stem))" }
        guard ext == "dart" else { return file }

        let suffixes: [(String, String)] = [
            ("_page", "screen"), ("_screen", "screen"), ("_view", "screen"),
            ("_widget", "component"), ("_card", "card"), ("_button", "button"), ("_tile", "tile"),
            ("_dialog", "dialog"), ("_sheet", "sheet"), ("_bar", "bar"),
            ("_model", "data"), ("_service", "logic"), ("_repository", "data source"), ("_api", "connection"),
            ("_provider", "logic"), ("_controller", "logic"), ("_bloc", "logic"), ("_cubit", "logic"),
            ("_notifier", "logic"), ("_state", "state"), ("_theme", "theme"), ("_colors", "colours"),
            ("_routes", "navigation"), ("_router", "navigation"),
        ]
        for (suffix, noun) in suffixes where stem.hasSuffix(suffix) && stem.count > suffix.count {
            return "\(words(String(stem.dropLast(suffix.count)))) \(noun)"
        }
        if folders.contains("models") { return "\(words(stem)) data" }
        if folders.contains("widgets") || folders.contains("components") { return "\(words(stem)) component" }
        return words(stem)
    }

    /// "water_intake" -> "Water intake"
    static func words(_ identifier: String) -> String {
        let spaced = identifier.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }

    /// "HomePage" -> "Home", "WaterIntakeScreen" -> "Water intake"
    static func screenName(fromClass name: String) -> String {
        var base = name
        for suffix in ["Page", "Screen", "View"] where base.hasSuffix(suffix) && base.count > suffix.count {
            base = String(base.dropLast(suffix.count))
            break
        }
        let spaced = base.replacing(/([a-z0-9])([A-Z])/) { "\($0.1) \($0.2.lowercased())" }
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }
}

/// A screen of the user's app: a widget class named like FooPage, FooScreen or FooView.
struct AppScreen: Identifiable, Equatable, Sendable {
    let name: String
    let className: String
    /// Relative to the project folder. Empty for a planned screen.
    let file: String
    /// Set for a screen that is in PLAN.md but not in the code yet; the text is what the plan says it is for.
    var purpose: String?
    var id: String { className }
    var isPlanned: Bool { purpose != nil }
}

/// A Dart file of the project, read once and shared by `ScreenFinder` and `FlowFinder`.
struct DartSource: Sendable {
    /// Relative to the project folder.
    let file: String
    let text: String
}

enum ScreenFinder {
    static func screens(in folder: String) -> [AppScreen] { screens(in: sources(in: folder)) }

    static func screens(in sources: [DartSource]) -> [AppScreen] {
        var seen = Set<String>()
        return sources.flatMap { screens(in: $0.text, file: $0.file) }
            .filter { seen.insert($0.className).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The Dart files under lib/, skipping very large ones.
    static func sources(in folder: String) -> [DartSource] {
        let lib = URL(fileURLWithPath: folder).appendingPathComponent("lib")
        guard let walker = FileManager.default.enumerator(at: lib, includingPropertiesForKeys: [.fileSizeKey]) else { return [] }
        var sources: [DartSource] = []
        for case let url as URL in walker where url.pathExtension == "dart" {
            guard (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 < 400_000,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let relative = "lib/" + url.path.components(separatedBy: "/lib/").dropFirst().joined(separator: "/lib/")
            sources.append(DartSource(file: relative, text: text))
        }
        return sources.sorted { $0.file < $1.file }
    }

    static func screens(in source: String, file: String) -> [AppScreen] {
        // A Regex isn't Sendable, so it can't be a static constant under strict concurrency. Private classes
        // (`_WaterView`) are parts of a screen, not screens.
        let declaration = /class\s+([A-Za-z]\w*(?:Page|Screen|View))\s+extends\s+\w*(?:Stateless|Stateful|Consumer|Hook)\w*Widget/
        return source.matches(of: declaration).map { match in
            let className = String(match.1)
            return AppScreen(name: FriendlyName.screenName(fromClass: className), className: className, file: file)
        }
    }
}
