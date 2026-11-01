import Foundation

/// What the New Project sheet asked for, kept with the project so the planning chat knows the app's idea and
/// whether the kickoff was offered, started or skipped. Only projects made with New Project have one.
struct NewProjectRecord: Codable, Equatable, Sendable {
    enum Kickoff: String, Codable, Sendable {
        /// The card is shown in the chat.
        case offered
        case started
        case skipped
        /// PLAN.md was written.
        case planned
    }

    var request: NewProjectRequest
    var kickoff: Kickoff = .offered
    var created = Date()
    /// Set when git was on but the first version wasn't saved, with what to do about it.
    var gitNote: String?
    /// Claude has changed the project since it was created. Optional so older records still load.
    var changed: Bool?
    /// Indexes of the plan's milestones that were built.
    var doneMilestones: [Int]?

    static func url(forFolder folder: String) -> URL {
        ProjectStorage.directory("NewProject", for: folder).appendingPathComponent("record.json")
    }

    static func load(forFolder folder: String) -> NewProjectRecord? {
        guard let data = try? Data(contentsOf: url(forFolder: folder)) else { return nil }
        return try? JSONDecoder().decode(NewProjectRecord.self, from: data)
    }

    func save(forFolder folder: String) {
        let url = Self.url(forFolder: folder)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: url, options: .atomic) }
    }
}

enum NewProjectDefaults {
    static let lastParentKey = "newProject.lastParent.v1"

    /// Where the sheet starts: `~/Developer`, or the parent used last when that folder still exists.
    static func initialParent(defaults: UserDefaults = .standard, fileManager: FileManager = .default) -> String {
        if let last = defaults.string(forKey: lastParentKey), fileManager.fileExists(atPath: last) { return last }
        return NewProjectRequest.defaultParent
    }
}
