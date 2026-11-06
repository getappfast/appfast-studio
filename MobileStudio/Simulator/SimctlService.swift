import Foundation

/// Lists, boots and shuts down simulators with `xcrun simctl`, which is stable public tooling.
/// Only the screen itself goes through the private framework (see MSSimulatorDisplay).
struct SimctlService: DeviceService {
    private let xcrun = "/usr/bin/xcrun"

    var platform: DevicePlatform { .ios }

    /// Dynamic Type sizes simctl accepts, smallest first, with a short name for each.
    let textSizes: [TextSizeOption] = [
        ("extra-small", "Extra Small"), ("small", "Small"), ("medium", "Medium"), ("large", "Default"),
        ("extra-large", "Large"), ("extra-extra-large", "Extra Large"), ("extra-extra-extra-large", "Largest"),
        ("accessibility-medium", "Accessibility M"), ("accessibility-large", "Accessibility L"),
        ("accessibility-extra-large", "Accessibility XL"), ("accessibility-extra-extra-large", "Accessibility XXL"),
        ("accessibility-extra-extra-extra-large", "Accessibility XXXL"),
    ].map { TextSizeOption(id: $0.0, name: $0.1) }

    func developerDir() async -> String? {
        let runner = ProcessRunner(timeout: 10)
        guard let out = try? await runner.run("/usr/bin/xcode-select", ["-p"]), out.status == 0 else { return nil }
        let path = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// iPhones and iPads that are installed and usable, newest runtime first.
    func devices() async throws -> [Device] {
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
                entries.map { Device(id: $0.udid, name: $0.name, platform: .ios, osVersion: runtime, state: Self.state(from: $0.state), runID: $0.udid) }
            }
            .sorted {
                if $0.osVersion != $1.osVersion { return $0.osVersion.compare($1.osVersion, options: .numeric) == .orderedDescending }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    /// Boots the device if needed and returns once it has finished booting.
    func boot(_ device: Device) async throws {
        let out = try await ProcessRunner(timeout: 240).run(xcrun, ["simctl", "bootstatus", device.id, "-b"])
        guard out.status == 0 else {
            throw ClaudeCLIError.commandFailed(out.failureDetail(fallback: "The simulator did not finish booting."))
        }
    }

    func shutdown(_ device: Device) async throws {
        let out = try await ProcessRunner(timeout: 60).run(xcrun, ["simctl", "shutdown", device.id])
        // Already-shut-down is not a failure.
        guard out.status == 0 || out.stderr.contains("current state: Shutdown") else {
            throw ClaudeCLIError.commandFailed(out.failureDetail(fallback: "The simulator did not shut down."))
        }
    }

    /// Puts text on the device's pasteboard. `simctl pbcopy` reads stdin, which ProcessRunner doesn't offer, so the text goes through a file.
    func setClipboard(_ device: Device, text: String) async -> Bool {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ms-paste-\(UUID().uuidString).txt")
        guard (try? text.write(to: file, atomically: true, encoding: .utf8)) != nil else { return false }
        defer { try? FileManager.default.removeItem(at: file) }
        let out = try? await ProcessRunner(timeout: 15).run("/bin/sh", ["-c", "\"$0\" simctl pbcopy \"$1\" < \"$2\"", xcrun, device.id, file.path])
        return out?.status == 0
    }

    // MARK: Preview settings

    func isDark(_ device: Device) async -> Bool? {
        await ui(device.id, ["appearance"]).map { $0 == "dark" }
    }

    func setDark(_ device: Device, _ dark: Bool) async {
        _ = await ui(device.id, ["appearance", dark ? "dark" : "light"])
    }

    /// The Dynamic Type size, e.g. "large" or "accessibility-extra-large".
    func textSize(_ device: Device) async -> String? {
        await ui(device.id, ["content_size"])
    }

    func setTextSize(_ device: Device, _ id: String) async {
        _ = await ui(device.id, ["content_size", id])
    }

    func screen(for device: Device) async throws -> any DeviceScreen {
        guard let developerDir = await developerDir() else {
            throw ClaudeCLIError.commandFailed("Xcode's developer directory was not found. Install Xcode and run xcode-select.")
        }
        let display = MSSimulatorDisplay(udid: device.id, developerDir: developerDir)
        do {
            try await display.start()
        } catch {
            display.stop()
            throw error
        }
        return display
    }

    private func ui(_ udid: String, _ arguments: [String]) async -> String? {
        guard let out = try? await ProcessRunner(timeout: 15).run(xcrun, ["simctl", "ui", udid] + arguments),
              out.status == 0 else { return nil }
        return out.stdout.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    // MARK: Decoding

    private static func state(from name: String) -> Device.State {
        switch name {
        case "Booted": .booted
        case "Booting": .booting
        case "Shutting Down": .shuttingDown
        default: .shutdown
        }
    }

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
