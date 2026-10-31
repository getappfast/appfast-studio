import Foundation

/// A failed `flutter run`, kept so it can be shown again after a relaunch and handed to Claude.
struct RunFailure: Equatable, Sendable, Codable {
    let date: Date
    let folder: String
    let deviceID: String
    let deviceName: String
    /// Nil for a project without flavors, and for failures saved before flavors could be run.
    var flavor: RunFlavor?
    let message: String
    /// The last lines of Flutter's output.
    let output: [String]
}
