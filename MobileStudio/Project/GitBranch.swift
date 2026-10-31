import Foundation

/// The checked-out branch of the git repository a folder belongs to.
enum GitBranch {
    /// Nil when the folder isn't inside a git repository. A detached HEAD reads "detached at <sha>".
    static func current(in folder: String) async -> String? {
        let runner = ProcessRunner(timeout: 5)
        func git(_ arguments: [String]) async -> String? {
            guard let out = try? await runner.run("/usr/bin/git", ["-C", folder] + arguments), out.status == 0 else { return nil }
            let text = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        // symbolic-ref also works on a new repository that has no commits yet.
        if let branch = await git(["symbolic-ref", "--short", "-q", "HEAD"]) { return branch }
        if let sha = await git(["rev-parse", "--short", "HEAD"]) { return "detached at \(sha)" }
        return nil
    }
}
