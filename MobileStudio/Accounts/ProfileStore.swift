import Foundation
import Observation

/// The saved profiles and which one is active. Only the profiles the user added are
/// persisted; the default profile is always present.
@MainActor
@Observable
final class ProfileStore {
    private(set) var profiles: [Profile]
    var activeID: UUID {
        didSet { defaults.set(activeID.uuidString, forKey: Keys.active) }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let profiles = "profiles.v1"
        static let active = "activeProfile.v1"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.data(forKey: Keys.profiles)
            .flatMap { try? JSONDecoder().decode([Profile].self, from: $0) } ?? []
        let all = [Profile.default] + saved.filter { !$0.isDefault }
        let stored = defaults.string(forKey: Keys.active).flatMap(UUID.init(uuidString:))
        profiles = all
        activeID = all.contains { $0.id == stored } ? stored! : Profile.defaultID
    }

    var active: Profile {
        profiles.first { $0.id == activeID } ?? Profile.default
    }

    func add(_ profile: Profile) {
        profiles.append(profile)
        save()
    }

    func isNameTaken(_ name: String) -> Bool {
        let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
        return profiles.contains { $0.name.lowercased() == wanted }
    }

    /// A fresh, empty config directory for a profile that is about to sign in.
    func makeConfigDirectory() throws -> URL {
        let base = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("AppFast Studio/Profiles", isDirectory: true)
        let dir = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func save() {
        let custom = profiles.filter { !$0.isDefault }
        defaults.set(try? JSONEncoder().encode(custom), forKey: Keys.profiles)
    }
}
