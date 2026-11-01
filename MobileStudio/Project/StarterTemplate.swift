import Foundation

/// Fills `{{placeholder}}` markers in the bundled starter files. A marker with no value is an error, so a typo
/// in a template fails in a test, not in the user's project.
enum TemplateRenderer {
    enum RenderError: Error, Equatable, LocalizedError {
        case unknownPlaceholder(String)

        var errorDescription: String? {
            switch self {
            case .unknownPlaceholder(let name): "The starter template uses {{\(name)}}, which has no value."
            }
        }
    }

    /// `{{app_name}}` inserts the value as is. `{{app_name|dart}}` escapes it for a single-quoted Dart string.
    static func render(_ template: String, values: [String: String]) throws -> String {
        var failure: RenderError?
        let rendered = template.replacing(/\{\{\s*([a-z_]+)(?:\|([a-z]+))?\s*\}\}/) { match in
            let name = String(match.1)
            guard let value = values[name] else {
                failure = failure ?? .unknownPlaceholder(name)
                return ""
            }
            return match.2.map(String.init) == "dart" ? dartString(value) : value
        }
        if let failure { throw failure }
        return rendered
    }

    /// Escapes text for use between single quotes in Dart.
    static func dartString(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n")
    }
}

/// The starter app bundled under Resources/Templates/starter, written into a new project.
enum StarterTemplate {
    static var bundledRoot: URL? { Bundle.main.resourceURL?.appendingPathComponent("Templates/starter") }

    /// The placeholder values every starter file may use.
    static func values(for request: NewProjectRequest) -> [String: String] {
        [
            "app_name": request.displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            "package_name": request.packageName,
            "description": request.description.trimmingCharacters(in: .whitespacesAndNewlines),
            "app_id": request.effectiveAppID,
        ]
    }

    enum WriteError: LocalizedError {
        case templatesMissing

        var errorDescription: String? { "The starter files are missing from the app. Reinstall Mobile Studio." }
    }

    /// Renders every `*.tmpl` under `templates` into `folder`, replacing files of the same name. Returns the
    /// project-relative paths written, sorted.
    @discardableResult
    static func write(
        values: [String: String], to folder: String, templates: URL? = bundledRoot
    ) throws -> [String] {
        guard let templates, let walker = FileManager.default.enumerator(at: templates, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw WriteError.templatesMissing
        }
        let root = templates.resolvingSymlinksInPath().path
        var written: [String] = []
        for case let url as URL in walker where url.pathExtension == "tmpl" {
            let relative = String(url.resolvingSymlinksInPath().path.dropFirst(root.count + 1).dropLast(".tmpl".count))
            let text = try String(contentsOf: url, encoding: .utf8)
            let destination = URL(fileURLWithPath: folder).appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try TemplateRenderer.render(text, values: values).write(to: destination, atomically: true, encoding: .utf8)
            written.append(relative)
        }
        if written.isEmpty { throw WriteError.templatesMissing }
        return written.sorted()
    }
}
