import Foundation

/// What changed in one file, as git shows it.
enum GitDiff {
    struct Line: Equatable, Sendable, Identifiable {
        enum Kind: Sendable { case added, removed, hunk, header, context }
        let id: Int
        let kind: Kind
        let text: String
    }

    enum Result: Equatable, Sendable {
        case diff([Line])
        /// The file is unchanged against HEAD, e.g. the change was committed since.
        case unchanged
        /// Git can't help: not a repository, or git failed. The reason is shown instead.
        case unavailable(String)

        /// Where the editor should land: the first changed line of the new file, nil without a diff.
        var firstChangedLine: Int? {
            if case .diff(let lines) = self { return GitDiff.firstChangedLine(in: lines) }
            return nil
        }
    }

    /// The new-file line a hunk header (`@@ -12,3 +14,4 @@ …`) starts at, nil when it isn't one.
    static func newStartLine(ofHunk header: String) -> Int? {
        guard header.hasPrefix("@@"), let plus = header.firstIndex(of: "+") else { return nil }
        let digits = header[header.index(after: plus)...].prefix { $0.isNumber }
        return Int(digits)
    }

    /// The line of the new file the first change is at. The hunk header names where its context begins, so the
    /// context lines before the first added or removed line are counted on top of it. A deletion lands on the line
    /// after the removed text, and the answer is never below 1 (a hunk at the very top starts at line 0).
    static func firstChangedLine(in lines: [Line]) -> Int? {
        guard let hunk = lines.firstIndex(where: { $0.kind == .hunk }),
              let start = newStartLine(ofHunk: lines[hunk].text) else { return nil }
        var line = max(start, 1)
        for next in lines[(hunk + 1)...] {
            switch next.kind {
            case .added, .removed, .hunk: return line
            case .context: line += 1
            case .header: continue
            }
        }
        return line
    }

    /// The working-tree diff of `path` against HEAD. A new, untracked file shows as fully added.
    static func diff(of path: String, in folder: String) async -> Result {
        let runner = ProcessRunner(timeout: 10)
        let git = "/usr/bin/git"
        guard let inside = try? await runner.run(git, ["-C", folder, "rev-parse", "--is-inside-work-tree"]),
              inside.status == 0 else {
            return .unavailable("This project isn't a git repository, so there is nothing to compare the file with.")
        }
        guard let tracked = try? await runner.run(git, ["-C", folder, "diff", "--no-color", "--no-ext-diff", "HEAD", "--", path]) else {
            return .unavailable("git diff did not answer.")
        }
        var text = tracked.stdout
        if text.isEmpty, FileManager.default.fileExists(atPath: (folder as NSString).appendingPathComponent(path)) {
            // Untracked files have no diff against HEAD. --no-index exits 1 when the files differ, which is the point.
            let untracked = try? await runner.run(git, ["-C", folder, "diff", "--no-color", "--no-index", "--", "/dev/null", path])
            text = untracked?.stdout ?? ""
        }
        if tracked.status != 0, text.isEmpty {
            return .unavailable(tracked.failureDetail(fallback: "git diff failed."))
        }
        let lines = parse(text)
        return lines.isEmpty ? .unchanged : .diff(lines)
    }

    static func parse(_ text: String) -> [Line] {
        text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { index, raw in
            let line = String(raw)
            let kind: Line.Kind
            if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ")
                || line.hasPrefix("new file") || line.hasPrefix("deleted file") || line.hasPrefix("similarity") {
                kind = .header
            } else if line.hasPrefix("@@") {
                kind = .hunk
            } else if line.hasPrefix("+") {
                kind = .added
            } else if line.hasPrefix("-") {
                kind = .removed
            } else if line.isEmpty, index > 0 {
                return nil
            } else {
                kind = .context
            }
            return Line(id: index, kind: kind, text: line)
        }
        .filter { $0.kind != .header }
    }
}
