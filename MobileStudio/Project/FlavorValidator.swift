import Foundation

/// Claude names the flavors it sees; this checks the files so only flavors that `flutter run --flavor`
/// can actually build are kept. A flavor must exist natively on a platform and have its entry point.
enum FlavorValidator {
    struct Result: Sendable {
        let runnable: [RunFlavor]
        /// "name: reason", for the log.
        let rejected: [String]
    }

    static func validate(_ candidates: [RunFlavor], in folder: String) -> Result {
        let fm = FileManager.default
        func path(_ relative: String) -> String { (folder as NSString).appendingPathComponent(relative) }

        let gradle = ["android/app/build.gradle", "android/app/build.gradle.kts"]
            .compactMap { try? String(contentsOfFile: path($0), encoding: .utf8) }.first
        let pbxproj = try? String(contentsOfFile: path("ios/Runner.xcodeproj/project.pbxproj"), encoding: .utf8)
        let hasMain = fm.fileExists(atPath: path("lib/main.dart"))

        var runnable: [RunFlavor] = []
        var rejected: [String] = []
        var seen = Set<String>()

        for candidate in candidates where seen.insert(candidate.name).inserted {
            let name = candidate.name

            var platforms: [String] = []
            if let gradle, declaresAndroidFlavor(name, in: gradle) { platforms.append("android") }
            if let pbxproj, fm.fileExists(atPath: path("ios/Runner.xcodeproj/xcshareddata/xcschemes/\(name).xcscheme")),
               pbxproj.contains("Debug-\(name)") { platforms.append("ios") }
            guard !platforms.isEmpty else {
                rejected.append("\(name): not defined as an Android flavor or iOS scheme with Debug-\(name) configuration")
                continue
            }

            let entry = candidate.entryPoint.isEmpty ? nil : candidate.entryPoint
            let guesses = ["lib/main-\(name).dart", "lib/main_\(name).dart"]
            let entryPoint: String
            if let entry, fm.fileExists(atPath: path(entry)) {
                entryPoint = entry
            } else if let found = guesses.first(where: { fm.fileExists(atPath: path($0)) }) {
                entryPoint = found
            } else if entry == nil, hasMain {
                entryPoint = ""
            } else {
                rejected.append("\(name): entry point \(entry ?? "lib/main.dart") does not exist")
                continue
            }
            runnable.append(RunFlavor(name: name, platforms: platforms, entryPoint: entryPoint))
        }
        return Result(runnable: runnable, rejected: rejected)
    }

    /// `name { … }`, `create("name")` or `register("name")` after the productFlavors keyword.
    private static func declaresAndroidFlavor(_ name: String, in gradle: String) -> Bool {
        guard let start = gradle.range(of: "productFlavors") else { return false }
        let block = String(gradle[start.upperBound...])
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = #"(?m)^\s*(?:(?:create|register)\(\s*["']\#(escaped)["']\s*\)|["']?\#(escaped)["']?\s*\{)"#
        return block.range(of: pattern, options: .regularExpression) != nil
    }
}
