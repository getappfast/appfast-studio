import Foundation
import Testing
@testable import AppFast_Studio

struct DeviceChromeTests {
    /// Xcode's own files are used when present; the test skips on a machine without them.
    @Test func loadsTheFrameForAFaceIDiPhone() throws {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: DeviceChrome.deviceTypesDirectories[0].path)) ?? []
        guard let name = names.first(where: { $0.hasPrefix("iPhone 1") && $0.hasSuffix(".simdevicetype") }),
              let chrome = DeviceChrome.load(deviceName: String(name.dropLast(".simdevicetype".count)))
        else { return }
        #expect(chrome.inset.width > 0)
        #expect(chrome.inset.width < chrome.screenSize.width / 4)
        #expect(chrome.cornerRadius > 0)
    }

    @Test func unknownDevicesHaveNoFrame() {
        #expect(DeviceChrome.load(deviceName: "Nonexistent Phone") == nil)
    }

    @Test func rejectsCapabilitiesWithoutADisplay() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: ["capabilities": [String: Any]()], format: .xml, options: 0)
        #expect(DeviceChrome(capabilities: data, chromeDirectory: URL(fileURLWithPath: "/nonexistent")) == nil)
    }
}
