import Foundation

struct SimulatorDevice: Identifiable, Hashable, Sendable {
    let udid: String
    let name: String
    /// e.g. "iOS 26.5"
    let runtime: String
    let state: String

    var id: String { udid }
    var isBooted: Bool { state == "Booted" }
    var isTransitioning: Bool { state == "Booting" || state == "Shutting Down" }
}

/// Lists, boots and shuts down simulators with `xcrun simctl`, which is stable public tooling.
/// Only the screen itself goes through the private framework (see MSSimulatorDisplay).
struct SimctlService: Sendable {
    private let xcrun = "/usr/bin/xcrun"

    func developerDir() async -> String? {
        let runner = ProcessRunner(timeout: 10)
        guard let out = try? await runner.run("/usr/bin/xcode-select", ["-p"]), out.status == 0 else { return nil }
        let path = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// iPhones and iPads that are installed and usable, newest runtime first.
    func devices() async throws -> [SimulatorDevice] {
        let out = try await ProcessRunner(timeout: 20).run(xcrun, ["simctl", "list", "devices", "available", "-j"])
        guard out.status == 0 else {
            throw ClaudeCLIError.commandFailed(out.failureDetail(fallback: "simctl could not list devices."))
        }
        guard let data = out.stdout.data(using: .utf8) else { return [] }
        let listing = try JSONDecoder().decode(Listing.self, from: data)

        return listing.devices
            .compactMap { runtimeID, entries -> (String, [Listing.Entry])? in
                guard let name = Self.runtimeName(from: runtimeID) else { return nil }
                return (name, entries)
            }
            .flatMap { runtime, entries in
                entries.map { SimulatorDevice(udid: $0.udid, name: $0.name, runtime: runtime, state: $0.state) }
            }
            .sorted {
                if $0.runtime != $1.runtime { return $0.runtime.compare($1.runtime, options: .numeric) == .orderedDescending }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    /// Boots the device if needed and returns once it has finished booting.
    func boot(_ udid: String) async throws {
        let out = try await ProcessRunner(timeout: 240).run(xcrun, ["simctl", "bootstatus", udid, "-b"])
        guard out.status == 0 else {
            throw ClaudeCLIError.commandFailed(out.failureDetail(fallback: "The simulator did not finish booting."))
        }
    }

    func shutdown(_ udid: String) async throws {
        let out = try await ProcessRunner(timeout: 60).run(xcrun, ["simctl", "shutdown", udid])
        // Already-shut-down is not a failure.
        guard out.status == 0 || out.stderr.contains("current state: Shutdown") else {
            throw ClaudeCLIError.commandFailed(out.failureDetail(fallback: "The simulator did not shut down."))
        }
    }

    // MARK: Decoding

    private struct Listing: Decodable {
        struct Entry: Decodable {
            let udid: String
            let name: String
            let state: String
        }
        let devices: [String: [Entry]]
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-26-5" -> "iOS 26.5"; nil for watchOS, tvOS, etc.
    static func runtimeName(from identifier: String) -> String? {
        guard let tail = identifier.components(separatedBy: "SimRuntime.").last, tail.hasPrefix("iOS-") else { return nil }
        let parts = tail.split(separator: "-")
        return "iOS " + parts.dropFirst().joined(separator: ".")
    }
}
