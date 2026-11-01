import Foundation

/// A platform folder `flutter create` can generate. iOS is always on: the canvas only runs the iOS Simulator.
enum ProjectPlatform: String, CaseIterable, Codable, Sendable {
    case ios, android, web, macos, windows, linux

    var title: String {
        switch self {
        case .ios: "iPhone & iPad"
        case .android: "Android"
        case .web: "Web"
        case .macos: "macOS"
        case .windows: "Windows"
        case .linux: "Linux"
        }
    }

    var isRequired: Bool { self == .ios }
}

/// Turns what someone typed ("Water Tracker") into a Dart package name (`water_tracker`).
enum PackageName {
    static let maxLength = 64

    /// `flutter create` refuses these as project names.
    static let reservedWords: Set<String> = [
        "abstract", "as", "assert", "async", "await", "break", "case", "catch", "class", "const", "continue",
        "covariant", "default", "deferred", "do", "dynamic", "else", "enum", "export", "extends", "extension",
        "external", "factory", "false", "final", "finally", "for", "function", "get", "hide", "if", "implements",
        "import", "in", "inout", "interface", "is", "late", "library", "mixin", "native", "new", "null", "of",
        "on", "operator", "out", "part", "patch", "required", "rethrow", "return", "set", "show", "source",
        "static", "super", "switch", "sync", "this", "throw", "true", "try", "typedef", "var", "void", "while",
        "with", "yield",
    ]

    /// Packages the starter depends on or that the SDK ships; a project with the same name breaks `pub get`.
    static let clashingPackages: Set<String> = [
        "flutter", "flutter_test", "flutter_riverpod", "go_router", "riverpod", "test", "dart", "integration_test",
    ]

    /// "Water Tracker" -> "water_tracker", "2048 Game" -> "game_2048", "Café ☕" -> "cafe". Never empty.
    static func derive(from name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        var out = ""
        for scalar in folded.unicodeScalars {
            if scalar.isASCII, scalar.properties.isAlphabetic || ("0"..."9").contains(Character(scalar)) {
                out.unicodeScalars.append(scalar)
            } else if !out.isEmpty, out.last != "_" {
                out.append("_")
            }
        }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if out.isEmpty { return "my_app" }

        // A package name can't start with a digit, so the number moves to the end.
        if let first = out.first, first.isNumber {
            let digits = out.prefix { $0.isNumber }
            let rest = out.dropFirst(digits.count).drop { $0 == "_" }
            out = rest.isEmpty ? "app_\(digits)" : "\(rest)_\(digits)"
        }
        out = String(out.prefix(maxLength)).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if reservedWords.contains(out) || clashingPackages.contains(out) { out += "_app" }
        return out
    }

    /// Why `name` can't be used as typed, or nil when it can.
    static func problem(with name: String) -> String? {
        if name.isEmpty { return "Package name can't be empty." }
        if name.count > maxLength { return "Package name must be \(maxLength) characters or fewer." }
        if name.wholeMatch(of: /[a-z][a-z0-9_]*/) == nil {
            return "Package name uses lowercase letters, digits and underscores, and starts with a letter."
        }
        if reservedWords.contains(name) { return "\"\(name)\" is a reserved word in Dart. Try another name." }
        if clashingPackages.contains(name) { return "\"\(name)\" is the name of a package the app uses. Try another name." }
        return nil
    }
}

/// An app ID such as `com.leo.watertracker`: the bundle ID on iOS and the application ID on Android.
enum AppID {
    static let defaultOrg = "com.example"

    /// Android rejects these as package segments (`com.new.app` fails to build).
    static let javaKeywords: Set<String> = [
        "abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class", "const", "continue",
        "default", "do", "double", "else", "enum", "extends", "final", "finally", "float", "for", "goto", "if",
        "implements", "import", "instanceof", "int", "interface", "long", "native", "new", "package", "private",
        "protected", "public", "return", "short", "static", "strictfp", "super", "switch", "synchronized", "this",
        "throw", "throws", "transient", "try", "void", "volatile", "while", "true", "false", "null",
    ]

    /// What `flutter create` gives an app that has no ID of its own.
    static func standard(forPackage package: String) -> String { "\(defaultOrg).\(package)" }

    /// Errors first, then warnings. Empty when the ID is fine.
    static func issues(in id: String) -> [NewProjectRequest.Issue] {
        let segments = id.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard segments.count >= 2 else {
            return [.error(.appID, "An app ID needs at least two parts, like com.yourname.appname.")]
        }
        for segment in segments {
            if segment.wholeMatch(of: /[a-zA-Z][a-zA-Z0-9_]*/) == nil {
                return [.error(.appID, "Each part of the app ID starts with a letter and uses only letters, digits and underscores.")]
            }
            if javaKeywords.contains(segment.lowercased()) {
                return [.error(.appID, "\"\(segment)\" can't be part of an Android app ID. Try another word.")]
            }
        }
        if segments.first?.lowercased() == "com", segments.dropFirst().first?.lowercased() == "example" {
            return [.warning(.appID, "Stores reject com.example IDs. Fine for now.")]
        }
        return []
    }
}

/// Everything the New Project sheet collects. `validate()` holds every rule; the sheet only shows them.
struct NewProjectRequest: Codable, Equatable, Sendable {
    var displayName: String
    var packageName: String
    var description: String
    var appID: String?
    var parentFolder: String
    var platforms: Set<ProjectPlatform>
    var usesGit: Bool

    struct Issue: Equatable, Sendable {
        enum Field: Sendable { case name, appID, folder, platforms }
        enum Severity: Sendable { case error, warning }
        let field: Field
        let severity: Severity
        let message: String

        static func error(_ field: Field, _ message: String) -> Issue { Issue(field: field, severity: .error, message: message) }
        static func warning(_ field: Field, _ message: String) -> Issue { Issue(field: field, severity: .warning, message: message) }
    }

    /// Where the sheet starts and where the folder is created when it is missing.
    static var defaultParent: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer").path
    }

    /// The final project folder.
    var path: String { (parentFolder as NSString).appendingPathComponent(packageName) }

    /// The ID the app will get: the one typed, or what Flutter generates.
    var effectiveAppID: String { appID?.nonEmpty ?? AppID.standard(forPackage: packageName) }

    /// Errors block Create; warnings are shown and allow it.
    func validate(fileManager: FileManager = .default) -> [Issue] {
        var issues: [Issue] = []

        if displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.error(.name, "Give your app a name."))
        }
        if let problem = PackageName.problem(with: packageName) { issues.append(.error(.name, problem)) }
        if let appID = appID?.nonEmpty { issues += AppID.issues(in: appID) }
        if !platforms.contains(.ios) { issues.append(.error(.platforms, "The preview runs in the iOS Simulator, so iPhone & iPad stays on.")) }
        issues += folderIssues(fileManager)

        return issues.sorted { $0.severity == .error && $1.severity == .warning }
    }

    private func folderIssues(_ fileManager: FileManager) -> [Issue] {
        var isDirectory: ObjCBool = false
        let parentExists = fileManager.fileExists(atPath: parentFolder, isDirectory: &isDirectory)
        // The default parent is created when the user presses Create, so it may not exist yet.
        if !parentExists {
            return parentFolder == Self.defaultParent ? [] : [.error(.folder, "That folder doesn't exist.")]
        }
        guard isDirectory.boolValue else { return [.error(.folder, "Pick a folder, not a file.")] }
        guard fileManager.isWritableFile(atPath: parentFolder) else {
            return [.error(.folder, "Mobile Studio can't save to that folder. Pick another.")]
        }

        var issues: [Issue] = []
        var target: ObjCBool = false
        if fileManager.fileExists(atPath: path, isDirectory: &target) {
            let contents = (try? fileManager.contentsOfDirectory(atPath: path))?.filter { $0 != ".DS_Store" } ?? []
            if !target.boolValue || !contents.isEmpty {
                issues.append(.error(.folder, "\"\(packageName)\" already exists in that folder. Pick another folder or name."))
            }
        }
        if let outer = enclosingFlutterProject(fileManager) {
            issues.append(.error(.folder, "That folder is inside the Flutter project \"\((outer as NSString).lastPathComponent)\". Pick a folder outside it."))
        }
        if parentFolder.contains("/Library/Mobile Documents/") {
            issues.append(.warning(.folder, "iCloud Drive can move files off this Mac, which slows builds. A folder outside iCloud is safer."))
        }
        return issues
    }

    private func enclosingFlutterProject(_ fileManager: FileManager) -> String? {
        var folder = URL(fileURLWithPath: parentFolder)
        while folder.path != "/" {
            if fileManager.fileExists(atPath: folder.appendingPathComponent("pubspec.yaml").path) { return folder.path }
            folder.deleteLastPathComponent()
        }
        return nil
    }
}
