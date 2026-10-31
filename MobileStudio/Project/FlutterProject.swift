import Foundation

struct FlutterProject: Equatable, Sendable {
    let path: String
    let name: String
    let version: String?
    /// The `environment: sdk:` constraint, e.g. "^3.4.0".
    let dartConstraint: String?
    /// Platform folders present, in a fixed display order.
    let platforms: [String]
    let hasMainDart: Bool

    var folderName: String { (path as NSString).lastPathComponent }
}

enum ProjectState: Equatable, Sendable {
    case none
    case ready(FlutterProject)
    /// A folder was chosen but it is not usable as a Flutter project.
    case invalid(path: String, reason: String)
}

enum FlutterProjectInspector {
    static let platformFolders = ["ios", "android", "macos", "web", "linux", "windows"]

    static func inspect(path: String) -> ProjectState {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return .invalid(path: path, reason: "This folder no longer exists.")
        }
        let pubspec = (path as NSString).appendingPathComponent("pubspec.yaml")
        guard let text = try? String(contentsOfFile: pubspec, encoding: .utf8) else {
            return .invalid(path: path, reason: "No pubspec.yaml here. Choose the folder that contains it, the project root.")
        }
        guard let name = topLevelValue("name", in: text) else {
            return .invalid(path: path, reason: "pubspec.yaml has no package name.")
        }
        guard dependsOnFlutter(text) else {
            return .invalid(path: path, reason: "\"\(name)\" is a Dart package, not a Flutter app. It does not depend on the Flutter SDK.")
        }
        return .ready(FlutterProject(
            path: path,
            name: name,
            version: topLevelValue("version", in: text),
            dartConstraint: dartConstraint(in: text),
            platforms: platformFolders.filter { fm.fileExists(atPath: (path as NSString).appendingPathComponent($0)) },
            hasMainDart: fm.fileExists(atPath: (path as NSString).appendingPathComponent("lib/main.dart"))
        ))
    }

    // MARK: Minimal pubspec reading (no YAML dependency; only the few keys we show)

    private static func topLevelValue(_ key: String, in text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("\(key):") {
            return clean(line.dropFirst(key.count + 1))
        }
        return nil
    }

    /// `flutter:` as a top-level key, or `sdk: flutter` under dependencies, marks a Flutter package.
    private static func dependsOnFlutter(_ text: String) -> Bool {
        text.contains(/(?m)^flutter:/) || text.contains(/(?m)^\s+sdk:\s*["']?flutter["']?\s*(#.*)?$/)
    }

    private static func dartConstraint(in text: String) -> String? {
        guard let env = text.range(of: #"(?m)^environment:\s*$"#, options: .regularExpression) else { return nil }
        for line in text[env.upperBound...].split(whereSeparator: \.isNewline) {
            if let first = line.first, !first.isWhitespace { break }  // left the environment block
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("sdk:") { return clean(trimmed.dropFirst(4)) }
        }
        return nil
    }

    private static func clean(_ raw: Substring) -> String? {
        var value = raw
        if let hash = value.range(of: " #") { value = value[..<hash.lowerBound] }
        let result = value.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'")))
        return result.isEmpty ? nil : result
    }
}
