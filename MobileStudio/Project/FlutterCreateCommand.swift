import Foundation

/// The `flutter create` arguments for a request. Built as an argv array so the description can contain quotes,
/// newlines or `$` without ever passing through a shell string.
enum FlutterCreateCommand {
    /// How the user's app ID reaches the project.
    enum AppIDPlan: Equatable, Sendable {
        /// Flutter derives the ID from `--org` and the package name, so nothing needs rewriting.
        case org(String)
        /// The ID doesn't end in the package name, so create with the default org and rewrite afterwards.
        case rewrite(to: String)
    }

    static func appIDPlan(for request: NewProjectRequest) -> AppIDPlan {
        guard let id = request.appID?.nonEmpty else { return .org(AppID.defaultOrg) }
        let segments = id.split(separator: ".").map(String.init)
        if segments.count >= 2, segments.last == request.packageName {
            return .org(segments.dropLast().joined(separator: "."))
        }
        return .rewrite(to: id)
    }

    /// Run in the parent folder; the last argument is the folder to create.
    static func arguments(for request: NewProjectRequest) -> [String] {
        let org = switch appIDPlan(for: request) {
        case .org(let org): org
        case .rewrite: AppID.defaultOrg
        }
        let platforms = ProjectPlatform.allCases.filter { request.platforms.contains($0) }.map(\.rawValue)

        var arguments = ["create", "--project-name", request.packageName, "--org", org, "--platforms", platforms.joined(separator: ",")]
        if let description = request.description.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            arguments += ["--description", description]
        }
        // The packages step downloads, so an offline create fails there with a clear message, not here.
        return arguments + ["--no-pub", "--empty", request.packageName]
    }
}
