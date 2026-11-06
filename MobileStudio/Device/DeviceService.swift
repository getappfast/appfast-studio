import Foundation

/// The platform tooling behind a kind of device: listing, booting, preview settings and the screen itself.
protocol DeviceService: Sendable {
    var platform: DevicePlatform { get }
    /// Text sizes this platform offers in the Text Size menu, smallest first.
    var textSizes: [TextSizeOption] { get }

    func devices() async throws -> [Device]
    func boot(_ device: Device) async throws
    func shutdown(_ device: Device) async throws
    func isDark(_ device: Device) async -> Bool?
    func setDark(_ device: Device, _ dark: Bool) async
    func textSize(_ device: Device) async -> String?
    func setTextSize(_ device: Device, _ id: String) async
    func setClipboard(_ device: Device, text: String) async -> Bool
    /// Attaches to a running device's screen and starts frames; throws a message the user can read.
    func screen(for device: Device) async throws -> any DeviceScreen
}
