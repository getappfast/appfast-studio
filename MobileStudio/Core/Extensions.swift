import Foundation

extension String {
    /// Nil for an empty string, so a chain of fallbacks can be written with `??`.
    var nonEmpty: String? { isEmpty ? nil : self }
}

extension UserDefaults {
    /// A value saved with `setEncoded(_:forKey:)`. Nil when missing or saved in an older shape.
    func decoded<Value: Decodable>(_ type: Value.Type, forKey key: String) -> Value? {
        guard let data = data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Saves a value as JSON. Nil removes it.
    func setEncoded<Value: Encodable>(_ value: Value?, forKey key: String) {
        guard let value, let data = try? JSONEncoder().encode(value) else {
            removeObject(forKey: key)
            return
        }
        set(data, forKey: key)
    }
}

/// Per-project storage under ~/Library/Application Support/AppFast Studio, keyed by a hash of the folder path.
enum ProjectStorage {
    static func directory(_ kind: String, for folder: String) -> URL {
        root.appendingPathComponent("\(kind)/\(key(folder))")
    }

    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AppFast Studio")
    }

    static func key(_ folder: String) -> String {
        FileSnapshot.hash(Data(folder.utf8)).prefix(16).description
    }
}
