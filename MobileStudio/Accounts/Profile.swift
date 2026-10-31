import Foundation

/// One Claude account Mobile Studio can run the CLI as.
///
/// The CLI keeps a separate login per config directory, selected with CLAUDE_CONFIG_DIR.
/// The built-in default profile leaves it unset so it keeps using the user's normal `~/.claude`
/// login; setting it explicitly would point at a different stored credential.
struct Profile: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var configDir: String?

    static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let `default` = Profile(id: defaultID, name: "Default", configDir: nil)

    var isDefault: Bool { id == Self.defaultID }

    var environment: [String: String] {
        configDir.map { ["CLAUDE_CONFIG_DIR": $0] } ?? [:]
    }

    /// Shown when a profile has to be signed in by hand.
    var loginCommand: String {
        guard let configDir else { return "claude auth login" }
        return "CLAUDE_CONFIG_DIR=\"\(configDir)\" claude auth login"
    }
}
