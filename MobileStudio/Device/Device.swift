import Foundation

enum DevicePlatform: String, Sendable, Hashable, CaseIterable {
    case ios
    case android
}

/// A phone the app can run on and show: an iOS Simulator today, an Android emulator later.
struct Device: Identifiable, Hashable, Sendable {
    enum State: Sendable { case booted, booting, shuttingDown, shutdown }

    /// The simulator's UDID, or the emulator's AVD name.
    let id: String
    let name: String
    let platform: DevicePlatform
    /// e.g. "iOS 26.5"; also the toolbar menu's section title.
    let osVersion: String
    let state: State
    /// What `flutter run -d` and the platform tools take: the UDID, or the adb serial of a running emulator (nil when it isn't running).
    let runID: String?

    var isBooted: Bool { state == .booted }
    var isTransitioning: Bool { state == .booting || state == .shuttingDown }
    var selection: DeviceSelection { DeviceSelection(platform: platform, id: id) }
}

/// Which device the user chose, saved as `device.selected.v2`.
struct DeviceSelection: Hashable, Sendable {
    let platform: DevicePlatform
    let id: String

    /// "ios:<udid>" or "android:<avd>".
    var rawValue: String { "\(platform.rawValue):\(id)" }

    init(platform: DevicePlatform, id: String) {
        self.platform = platform
        self.id = id
    }

    init?(rawValue: String) {
        guard let colon = rawValue.firstIndex(of: ":"),
              let platform = DevicePlatform(rawValue: String(rawValue[..<colon])) else { return nil }
        let id = String(rawValue[rawValue.index(after: colon)...])
        guard !id.isEmpty else { return nil }
        self.init(platform: platform, id: id)
    }

    /// The saved choice. The v1 key held a bare simulator UDID, so it reads as iOS.
    static func saved(v2: String?, v1: String?) -> DeviceSelection? {
        if let v2, let selection = DeviceSelection(rawValue: v2) { return selection }
        return v1.flatMap(\.nonEmpty).map { DeviceSelection(platform: .ios, id: $0) }
    }

    /// With nothing saved: a running device, else the first iPhone, else the first Android emulator, so iOS wins when it is there.
    static func firstChoice(in devices: [Device]) -> Device? {
        devices.first(where: \.isBooted)
            ?? devices.first { $0.platform == .ios && $0.name.hasPrefix("iPhone") }
            ?? devices.first { $0.platform == .android }
            ?? devices.first
    }
}

struct TextSizeOption: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

enum DeviceButton: Sendable { case home, back }
