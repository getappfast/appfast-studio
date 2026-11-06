import Foundation
import Testing
@testable import AppFast_Studio

struct DeviceTests {
    private func device(_ id: String, _ name: String, _ platform: DevicePlatform = .ios, booted: Bool = false) -> Device {
        Device(id: id, name: name, platform: platform, osVersion: platform == .ios ? "iOS 26.5" : "Android 16",
               state: booted ? .booted : .shutdown, runID: nil)
    }

    @Test func selectionRoundTripsAndKeepsColonsInTheID() {
        let selection = DeviceSelection(platform: .android, id: "Pixel_10_Pro")
        #expect(selection.rawValue == "android:Pixel_10_Pro")
        #expect(DeviceSelection(rawValue: selection.rawValue) == selection)
        #expect(DeviceSelection(rawValue: "ios:A:B")?.id == "A:B")
        #expect(DeviceSelection(rawValue: "windows:x") == nil)
        #expect(DeviceSelection(rawValue: "ios:") == nil)
    }

    @Test func aBareV1UDIDReadsAsIOS() {
        #expect(DeviceSelection.saved(v2: nil, v1: "ABC-123") == DeviceSelection(platform: .ios, id: "ABC-123"))
        #expect(DeviceSelection.saved(v2: "android:Pixel_9", v1: "ABC-123") == DeviceSelection(platform: .android, id: "Pixel_9"))
        #expect(DeviceSelection.saved(v2: "garbage", v1: nil) == nil)
        #expect(DeviceSelection.saved(v2: nil, v1: "") == nil)
    }

    @Test func firstChoicePrefersRunningThenIPhoneThenAndroid() {
        let ipad = device("1", "iPad Air")
        let iphone = device("2", "iPhone 17")
        let pixel = device("3", "Pixel 9", .android)
        let runningPixel = device("4", "Pixel 10 Pro", .android, booted: true)
        #expect(DeviceSelection.firstChoice(in: [ipad, iphone, pixel, runningPixel]) == runningPixel)
        #expect(DeviceSelection.firstChoice(in: [ipad, iphone, pixel]) == iphone)
        #expect(DeviceSelection.firstChoice(in: [pixel, ipad]) == pixel)
        #expect(DeviceSelection.firstChoice(in: [ipad]) == ipad)
        #expect(DeviceSelection.firstChoice(in: []) == nil)
    }

    @MainActor @Test func modelMigratesTheV1KeyWithoutTouchingIt() throws {
        let suite = "DeviceTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("UDID-1", forKey: "simulator.selected.v1")
        let model = DeviceModel(services: [], defaults: defaults)
        #expect(model.selection == DeviceSelection(platform: .ios, id: "UDID-1"))
        #expect(defaults.string(forKey: "simulator.selected.v1") == "UDID-1")
    }

    @Test func simctlRuntimeNamesStayIOSOnly() {
        #expect(SimctlService.runtimeName(from: "com.apple.CoreSimulator.SimRuntime.iOS-26-5") == "iOS 26.5")
        #expect(SimctlService.runtimeName(from: "com.apple.CoreSimulator.SimRuntime.watchOS-11-0") == nil)
    }
}
