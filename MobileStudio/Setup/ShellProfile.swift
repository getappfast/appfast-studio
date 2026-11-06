import Foundation

/// The login-shell file where a tool's folder is added to PATH, so the user's Terminal, Flutter and Claude's shell
/// find what the app installed. AppFast Studio runs `flutter` and checks for tools through `$SHELL -ilc`, which reads it.
enum ShellProfile {
    enum Kind: Equatable, Sendable {
        case zsh, bash, fish, other

        init(shell: String) {
            switch (shell as NSString).lastPathComponent {
            case "zsh": self = .zsh
            case "bash": self = .bash
            case "fish": self = .fish
            default: self = .other
            }
        }
    }

    /// What to add: a folder in front of PATH, or Homebrew's own environment (PATH, MANPATH and friends).
    enum Entry: Equatable, Sendable {
        case path(String)
        case brewShellenv(brew: String)
    }

    static let marker = "# Added by AppFast Studio"

    /// The file a login shell of this kind reads. Bash reads only the first of .bash_profile, .bash_login and
    /// .profile, so a new .bash_profile would hide an existing .profile; use whichever is already there.
    static func file(for kind: Kind, home: String, exists: (String) -> Bool) -> String {
        switch kind {
        case .zsh:
            return "\(home)/.zprofile"
        case .bash:
            let candidates = [".bash_profile", ".bash_login", ".profile"].map { "\(home)/\($0)" }
            return candidates.first(where: exists) ?? candidates[0]
        case .fish:
            return "\(home)/.config/fish/conf.d/mobile-studio.fish"
        case .other:
            return "\(home)/.profile"
        }
    }

    /// The line for this shell. Folders under home are written with `$HOME`, as people write them by hand.
    static func line(for entry: Entry, kind: Kind, home: String) -> String {
        switch entry {
        case .path(let folder):
            let shown = folder.hasPrefix(home + "/") ? "$HOME" + folder.dropFirst(home.count) : folder
            return kind == .fish ? "fish_add_path -g \"\(shown)\"" : "export PATH=\"\(shown):$PATH\""
        case .brewShellenv(let brew):
            return kind == .fish ? "\(brew) shellenv | source" : "eval \"$(\(brew) shellenv)\""
        }
    }

    /// The file's new text with the entry appended, or nil when it is already there (in any spelling the check
    /// recognises), so running setup twice never adds it twice.
    static func adding(_ entry: Entry, to content: String, kind: Kind, home: String) -> String? {
        let present: Bool
        switch entry {
        case .path(let folder):
            let short = folder.hasPrefix(home + "/") ? "$HOME" + folder.dropFirst(home.count) : folder
            let tilde = folder.hasPrefix(home + "/") ? "~" + folder.dropFirst(home.count) : folder
            present = activeLines(content).contains { $0.contains(folder) || $0.contains(short) || $0.contains(tilde) }
        case .brewShellenv(let brew):
            present = activeLines(content).contains { $0.contains("\(brew) shellenv") }
        }
        guard !present else { return nil }
        let separator = content.isEmpty || content.hasSuffix("\n") ? "" : "\n"
        let gap = content.isEmpty ? "" : "\n"
        return content + separator + gap + marker + "\n" + line(for: entry, kind: kind, home: home) + "\n"
    }

    /// Lines that do something: a commented-out PATH line doesn't count as being there.
    private static func activeLines(_ content: String) -> [Substring] {
        content.split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
    }

    /// Appends the entry to the user's profile. Returns the file it changed, nil when nothing needed changing.
    @discardableResult
    static func add(_ entry: Entry) throws -> String? {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let kind = Kind(shell: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        let path = file(for: kind, home: home) { fm.fileExists(atPath: $0) }
        let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        guard let updated = adding(entry, to: existing, kind: kind, home: home) else { return nil }
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        // Appending rather than rewriting keeps the file's permissions, owner and any link it is.
        if fm.fileExists(atPath: path), let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(updated.dropFirst(existing.count).utf8))
        } else {
            try updated.write(toFile: path, atomically: true, encoding: .utf8)
        }
        return path
    }
}
