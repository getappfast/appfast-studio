import AppKit

/// Opens a file in the developer's code editor at a line, so "Open Code" lands on the code instead of in whatever
/// app owns .dart files. Building the arguments is pure; only `detected` and `open` touch the machine.
enum CodeEditor {
    /// An editor AppFast Studio knows how to point at a file and line.
    struct Editor: Equatable, Sendable {
        /// In the order they are preferred when several are installed.
        enum Kind: CaseIterable, Sendable {
            case cursor, vsCode, zed, androidStudio

            var name: String {
                switch self {
                case .cursor: "Cursor"
                case .vsCode: "VS Code"
                case .zed: "Zed"
                case .androidStudio: "Android Studio"
                }
            }

            var bundleIdentifier: String {
                switch self {
                case .cursor: "com.todesktop.230313mzl4w4u92"
                case .vsCode: "com.microsoft.VSCode"
                case .zed: "dev.zed.Zed"
                case .androidStudio: "com.google.android.studio"
                }
            }

            /// Where the app usually lives, for when Launch Services doesn't know it yet (a fresh install).
            var appName: String {
                switch self {
                case .cursor: "Cursor.app"
                case .vsCode: "Visual Studio Code.app"
                case .zed: "Zed.app"
                case .androidStudio: "Android Studio.app"
                }
            }

            /// The command-line entry point inside the app bundle.
            var commandPath: String {
                switch self {
                case .cursor: "Contents/Resources/app/bin/cursor"
                case .vsCode: "Contents/Resources/app/bin/code"
                case .zed: "Contents/MacOS/cli"
                case .androidStudio: "Contents/MacOS/studio"
                }
            }
        }

        let kind: Kind
        let appURL: URL

        var name: String { kind.name }
        var bundleIdentifier: String { kind.bundleIdentifier }
        var executable: URL { appURL.appendingPathComponent(kind.commandPath) }

        /// The arguments that open `folder` as the project and `file` in it, at `line` when there is one.
        /// `file` should be a full path: the editor may not run in the project folder.
        func arguments(file: String, line: Int?, folder: String) -> [String] {
            let line = line.flatMap { $0 > 0 ? $0 : nil }
            switch kind {
            case .cursor, .vsCode:
                return ["-g", folder, line.map { "\(file):\($0)" } ?? file]
            case .zed:
                return [folder, line.map { "\(file):\($0)" } ?? file]
            case .androidStudio:
                return [folder] + (line.map { ["--line", String($0)] } ?? []) + [file]
            }
        }
    }

    static let log = DiagnosticLog(name: "editor")

    /// The editor to use: the first supported one that is installed, nil when there is none.
    static func detected() -> Editor? {
        detected(appURL: installedApp(_:), isExecutable: { FileManager.default.isExecutableFile(atPath: $0.path) })
    }

    /// `detected` with the machine taken out, so the choice can be tested.
    static func detected(appURL: (Editor.Kind) -> URL?, isExecutable: (URL) -> Bool) -> Editor? {
        for kind in Editor.Kind.allCases {
            guard let url = appURL(kind) else { continue }
            let editor = Editor(kind: kind, appURL: url)
            // An app without its command-line tool can't be pointed at a line, so the next editor gets its turn.
            if isExecutable(editor.executable) { return editor }
        }
        return nil
    }

    /// `file` as a full path: project-relative paths are taken from `folder`.
    static func absolutePath(of file: String, inProject folder: String) -> String {
        file.hasPrefix("/") ? file : (folder as NSString).appendingPathComponent(file)
    }

    /// Opens `file` in the detected editor at `line`, or the way macOS would when there is none or it doesn't answer.
    @MainActor
    static func open(file: String, line: Int? = nil, inProject folder: String) {
        let path = absolutePath(of: file, inProject: folder)
        let fileURL = URL(fileURLWithPath: path)
        guard let editor = detected() else {
            NSWorkspace.shared.open(fileURL)
            return
        }
        let arguments = editor.arguments(file: path, line: line, folder: folder)
        let process = Process()
        process.executableURL = editor.executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // These tools hand the request to the editor and exit at once, so a failure shows up as the exit status.
        process.terminationHandler = { finished in
            guard finished.terminationStatus != 0 else { return }
            log.append("\(editor.name) exited with \(finished.terminationStatus): \(editor.executable.path) \(arguments)")
            Task { @MainActor in _ = NSWorkspace.shared.open(fileURL) }
        }
        do {
            try process.run()
        } catch {
            log.append("\(editor.name) did not start: \(error.localizedDescription)")
            NSWorkspace.shared.open(fileURL)
        }
    }

    private static func installedApp(_ kind: Editor.Kind) -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: kind.bundleIdentifier) { return url }
        let applications = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask)
            + FileManager.default.urls(for: .applicationDirectory, in: .userDomainMask)
        return applications.map { $0.appendingPathComponent(kind.appName) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
