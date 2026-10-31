import Foundation

enum ShellEnvironment {
    /// The PATH the user's terminal has, read from their login shell. A Finder-launched app has a minimal
    /// one, so tools Claude runs (flutter, dart, pod) would not be found without this.
    static func terminalPATH() async -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard let out = try? await ProcessRunner(timeout: 15).run(shell, ["-ilc", "echo __PATH__${PATH}__END__"]),
              let start = out.stdout.range(of: "__PATH__"), let end = out.stdout.range(of: "__END__", range: start.upperBound..<out.stdout.endIndex)
        else { return nil }
        let path = String(out.stdout[start.upperBound..<end.lowerBound])
        return path.isEmpty ? nil : path
    }
}
