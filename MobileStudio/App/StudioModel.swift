import Foundation
import Observation

enum CLIInstallState: Equatable {
    case checking
    case notInstalled
    case failed(String)
    case installed(path: String, version: String)
}

enum LoginPhase: Equatable {
    case idle
    case running
    case verifying
    case failed(String)
}

@MainActor
@Observable
final class StudioModel {
    let profiles = ProfileStore()
    let models = ClaudeModelsModel()

    private(set) var install: CLIInstallState = .checking
    private(set) var accounts: [UUID: AccountState] = [:]
    private(set) var login: LoginPhase = .idle
    private(set) var loginOutput = ""

    private var loginProcess: ClaudeLoginProcess?
    private var loginCancelled = false

    // MARK: Derived

    var cliPath: String? {
        if case .installed(let path, _) = install { return path }
        return nil
    }

    func account(for profile: Profile) -> AccountState {
        accounts[profile.id] ?? .checking
    }

    /// The CLI as the active account. Nil until Claude can actually be run: the CLI is installed and the
    /// active profile is signed in. Everything that runs Claude (chat, fix, project check) starts here.
    var claude: ClaudeAccess? {
        guard let cliPath, case .signedIn = account(for: profiles.active) else { return nil }
        return ClaudeAccess(cliPath: cliPath, environment: profiles.active.environment)
    }

    var canRunClaude: Bool { claude != nil }

    var canCheckModels: Bool { canRunClaude }

    var projectVerifier: ProjectVerifier? { claude.map(ProjectVerifier.init) }

    /// The sign-in link the CLI printed, if it has by now.
    var loginURL: URL? {
        guard let range = loginOutput.range(of: "https://") else { return nil }
        let token = loginOutput[range.lowerBound...].prefix { !$0.isWhitespace }
        return URL(string: String(token))
    }

    // MARK: Detection

    func refresh() async {
        install = .checking
        for profile in profiles.profiles { accounts[profile.id] = .checking }

        let cli = ClaudeCLIService()
        guard let path = await cli.locate() else {
            install = .notInstalled
            accounts = [:]
            return
        }
        do {
            install = .installed(path: path, version: try await cli.version(at: path))
        } catch {
            install = .failed(error.localizedDescription)
            accounts = [:]
            return
        }

        await withTaskGroup(of: (UUID, AccountState).self) { group in
            for profile in profiles.profiles {
                group.addTask {
                    (profile.id, await ClaudeCLIService(environment: profile.environment).accountState(at: path))
                }
            }
            for await (id, state) in group { accounts[id] = state }
        }
    }

    // MARK: Switching

    func select(_ profile: Profile) {
        guard profile.id != profiles.activeID else { return }
        profiles.activeID = profile.id
        models.reset()
    }

    // MARK: Models

    func checkModels() async {
        guard let path = cliPath, canCheckModels else { return }
        await models.checkAll(cliPath: path, profile: profiles.active)
    }

    func checkCustomModel(_ name: String) async {
        guard let path = cliPath, canCheckModels else { return }
        await models.checkCustom(name, cliPath: path, profile: profiles.active)
    }

    // MARK: Adding an account

    /// Signs in to a new profile and, on success, saves it and makes it active.
    /// Returns when sign-in has finished, failed or been cancelled; see `login`.
    func addAccount(name: String, email: String) async {
        guard let path = cliPath, login != .running, login != .verifying else { return }
        let name = name.trimmingCharacters(in: .whitespaces)
        let email = email.trimmingCharacters(in: .whitespaces)

        loginOutput = ""
        loginCancelled = false
        login = .running

        let directory: URL
        do {
            directory = try profiles.makeConfigDirectory()
        } catch {
            login = .failed(error.localizedDescription)
            return
        }

        let process = ClaudeLoginProcess(
            cliPath: path, configDir: directory.path, email: email.isEmpty ? nil : email
        ) { [weak self] text in
            Task { @MainActor in self?.loginOutput += text }
        }
        loginProcess = process
        defer { loginProcess = nil }

        let profile = Profile(id: UUID(), name: name, configDir: directory.path)
        do {
            let exitStatus = try await process.run()
            if loginCancelled {
                await discard(profile, cliPath: path)
                login = .idle
                return
            }

            login = .verifying
            let state = await ClaudeCLIService(environment: profile.environment).accountState(at: path)
            guard exitStatus == 0, case .signedIn(let status) = state else {
                await discard(profile, cliPath: path)
                login = .failed("Sign-in did not complete. Try again.")
                return
            }
            if let existing = profileSignedIn(as: status.email) {
                await discard(profile, cliPath: path)
                login = .failed(
                    "That is the same account as “\(existing.name)”. Your browser may have signed in "
                    + "automatically. Sign out of claude.ai or open the link in a private window, then try again."
                )
                return
            }

            profiles.add(profile)
            accounts[profile.id] = state
            profiles.activeID = profile.id
            models.reset()
            login = .idle
        } catch {
            await discard(profile, cliPath: path)
            login = .failed(error.localizedDescription)
        }
    }

    func submitLoginCode(_ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        loginProcess?.send(trimmed)
    }

    func cancelLogin() {
        loginCancelled = true
        loginProcess?.cancel()
    }

    func clearLoginError() {
        if case .failed = login { login = .idle }
    }

    // MARK: Helpers

    private func profileSignedIn(as email: String?) -> Profile? {
        guard let email = email?.lowercased() else { return nil }
        return profiles.profiles.first {
            if case .signedIn(let status) = account(for: $0) { return status.email?.lowercased() == email }
            return false
        }
    }

    /// Removes a profile that never made it into the list: drops its credential and its folder.
    private func discard(_ profile: Profile, cliPath: String) async {
        await ClaudeCLIService(environment: profile.environment).logout(at: cliPath)
        if let dir = profile.configDir { try? FileManager.default.removeItem(atPath: dir) }
    }
}
