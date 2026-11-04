import Foundation

/// One screen's design history, `design/screens/<id>/screen.json`. The app writes it and Claude never does, so the
/// version list can't be lost or invented: Claude only writes the version files the prompt names.
struct DesignVersions: Codable, Equatable, Sendable {
    struct Version: Codable, Equatable, Sendable, Identifiable {
        /// "v3"; also the file name without ".html".
        let id: String
        /// The version it started from: another id, "current", or nil for a screen's first drawing.
        let parent: String?
        /// What the user asked for, in their words.
        let request: String
        /// Claude's one line on what this version tries, when it gave one.
        var summary: String
        /// Versions made by one request share a round ("show me three").
        let round: Int
        /// The chat answer that made it, for Undo.
        let messageID: UUID?
    }

    static let fileName = "screen.json"
    static let current = "current"

    /// The screen's name as the app and the plan call it: "Today".
    var name: String
    /// Its Dart file, relative to the project, when it exists in the code.
    var file: String?
    var versions: [Version] = []
    /// The reference for the build.
    var chosen: String?
    /// The version last applied to the app, or "current" when the app still looks like `current.html`.
    var inApp: String?
    /// The Dart file's hash when `current.html` was drawn, to notice the code changing since.
    var sourceHash: String?

    var rounds: [[Version]] {
        Dictionary(grouping: versions, by: \.round).sorted { $0.key < $1.key }.map(\.value)
    }

    func version(_ id: String) -> Version? { versions.first { $0.id == id } }

    /// The file names for the next `count` versions. Numbers are never reused, even after an undo, so an old picture
    /// or chat message can't point at a different version.
    func nextIDs(count: Int, existingFiles: Set<String> = []) -> [String] {
        let used = versions.compactMap { Int($0.id.dropFirst()) } + existingFiles.compactMap { name in
            name.hasPrefix("v") && name.hasSuffix(".html") ? Int(name.dropFirst().dropLast(5)) : nil
        }
        let start = (used.max() ?? 0) + 1
        return (0..<max(count, 0)).map { "v\(start + $0)" }
    }

    /// Records the versions a turn wrote. The newest of the round becomes chosen.
    mutating func add(ids: [String], parent: String?, request: String, summaries: [String: String] = [:], messageID: UUID?) {
        let round = (versions.map(\.round).max() ?? 0) + 1
        for id in ids where version(id) == nil {
            versions.append(Version(id: id, parent: parent, request: request, summary: summaries[id] ?? "", round: round, messageID: messageID))
        }
        if let last = ids.last(where: { version($0) != nil }) { chosen = last }
    }

    /// Drops versions whose file is gone (an undo removed them), and fixes `chosen` and `inApp` to match.
    mutating func prune(existingFiles: Set<String>) {
        versions.removeAll { !existingFiles.contains($0.id + ".html") }
        let ids = Set(versions.map(\.id)).union(existingFiles.contains(Self.current + ".html") ? [Self.current] : [])
        if let chosen, !ids.contains(chosen) { self.chosen = versions.last?.id }
        if let inApp, !ids.contains(inApp) { self.inApp = nil }
    }

    /// The version a new request starts from, when the user hasn't shown another: the chosen one, else the
    /// newest, else the screen as built.
    func defaultParent(hasCurrent: Bool) -> String? {
        chosen ?? versions.last?.id ?? (hasCurrent ? Self.current : nil)
    }
}

extension DesignVersions {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        file = try c.decodeIfPresent(String.self, forKey: .file)
        versions = (try? c.decodeIfPresent([Version].self, forKey: .versions)) ?? []
        chosen = try c.decodeIfPresent(String.self, forKey: .chosen)
        inApp = try c.decodeIfPresent(String.self, forKey: .inApp)
        sourceHash = try c.decodeIfPresent(String.self, forKey: .sourceHash)
    }

    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(self)) ?? Data("{}".utf8)
    }
}

extension DesignVersions.Version {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        parent = try c.decodeIfPresent(String.self, forKey: .parent)
        request = try c.decodeIfPresent(String.self, forKey: .request) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        round = try c.decodeIfPresent(Int.self, forKey: .round) ?? 0
        messageID = try c.decodeIfPresent(UUID.self, forKey: .messageID)
    }
}
