#if DEBUG
import AppKit

/// `MOBILE_STUDIO_SNAPSHOT_NEW_PROJECT=/tmp/x` creates a project in that folder, runs `flutter analyze` and
/// `flutter test` in it, writes the outcome to snapshot.log, then quits. It needs Flutter and the network, so it
/// is a check for people, not a unit test.
enum NewProjectSmokeTest {
    static let key = "MOBILE_STUDIO_SNAPSHOT_NEW_PROJECT"

    @MainActor
    static func runIfRequested() -> Bool {
        guard let parent = ProcessInfo.processInfo.environment[key] else { return false }
        Task { @MainActor in
            let log = Snapshot.log
            let request = NewProjectRequest(
                displayName: "Smoke Test", packageName: "smoke_test", description: "It's a \"$test\" app.\nSecond line.",
                appID: "com.smoke.testapp", parentFolder: parent, platforms: [.ios, .android], usesGit: true)
            let model = NewProjectModel()
            model.create(request)
            while model.isWorking || model.phase == .idle { try? await Task.sleep(for: .milliseconds(300)) }

            switch model.phase {
            case .done(let path):
                log.append("NEW PROJECT created at \(path); note: \(model.note ?? "none")")
                for tool in ["analyze", "test"] {
                    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
                    let out = try? await ProcessRunner(timeout: 600).run(shell, ["-ilc", "cd \"$1\" && flutter \"$2\"", "flutter", path, tool])
                    log.append("NEW PROJECT flutter \(tool): exit \(out?.status ?? -1)\n\((out?.stdout ?? "") + (out?.stderr ?? ""))")
                }
            case .failed(let step, let message):
                log.append("NEW PROJECT failed at \(step.title): \(message)")
            default: break
            }
            NSApp.terminate(nil)
        }
        return true
    }
}
#endif
