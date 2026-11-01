import Foundation

/// Pure text rewrites that give a freshly created project the app ID the user chose. Each is idempotent and
/// leaves other IDs (the Android `namespace`, test targets' suffix) alone.
enum AppIDWriter {
    /// iOS and macOS `project.pbxproj` and `AppInfo.xcconfig`. Keeps the `.RunnerTests` suffix on test targets.
    static func rewriteXcode(_ text: String, to id: String) -> String {
        text.replacing(/PRODUCT_BUNDLE_IDENTIFIER = ([^;\n]+)(;?)/) { match in
            let current = String(match.1)
            // `$(PRODUCT_BUNDLE_IDENTIFIER)` and similar are references, not IDs.
            if current.contains("$(") { return String(match.0) }
            let suffix = current.hasSuffix(".RunnerTests") ? ".RunnerTests" : ""
            return "PRODUCT_BUNDLE_IDENTIFIER = \(id)\(suffix)\(match.2)"
        }
    }

    /// `android/app/build.gradle` (`applicationId "x"`) and `build.gradle.kts` (`applicationId = "x"`).
    static func rewriteGradle(_ text: String, to id: String) -> String {
        text.replacing(/(applicationId\s*=?\s*)(["'])[^"'\n]*\2/) { match in
            "\(match.1)\(match.2)\(id)\(match.2)"
        }
    }

    /// Project-relative files that hold the ID, for those that exist.
    static let candidateFiles = [
        "ios/Runner.xcodeproj/project.pbxproj",
        "macos/Runner.xcodeproj/project.pbxproj",
        "macos/Runner/Configs/AppInfo.xcconfig",
        "android/app/build.gradle",
        "android/app/build.gradle.kts",
    ]

    /// Applies the rewrites to every candidate file under `folder`. Returns the files it changed.
    @discardableResult
    static func apply(_ id: String, inProjectAt folder: String) throws -> [String] {
        var changed: [String] = []
        for file in candidateFiles {
            let url = URL(fileURLWithPath: folder).appendingPathComponent(file)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let updated = file.contains("gradle") ? rewriteGradle(text, to: id) : rewriteXcode(text, to: id)
            guard updated != text else { continue }
            try updated.write(to: url, atomically: true, encoding: .utf8)
            changed.append(file)
        }
        return changed
    }
}
