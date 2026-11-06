import AppKit
import CoreGraphics
import CoreImage
import Foundation
import Observation

enum DevicePhase: Equatable {
    case idle
    case booting
    case connecting
    case streaming
    case failed(String)
}

@MainActor
@Observable
final class DeviceModel {
    private(set) var devices: [Device] = []
    private(set) var selection: DeviceSelection?
    private(set) var phase: DevicePhase = .idle
    private(set) var display: (any DeviceScreen)?
    private(set) var screenSize: CGSize?
    private(set) var framesPerSecond = 0
    /// True while a boot, shutdown or connect is in flight; the UI disables its buttons meanwhile.
    private(set) var isBusy = false
    /// The booted device's appearance and text size, for the preview controls under the screen.
    private(set) var isDark: Bool?
    private(set) var textSize: String?
    /// The last tap on the screen and a picture of the area around it, used as a picked element's thumbnail.
    private(set) var lastTap: (date: Date, image: Data?)?

    private let services: [DevicePlatform: any DeviceService]
    private let defaults: UserDefaults
    private let selectionKey = "device.selected.v2"
    /// Read once for the saved choice from before Android: a bare simulator UDID.
    private let legacySelectionKey = "simulator.selected.v1"

    private var lastFrameCount: UInt64 = 0

    init(services: [any DeviceService] = [SimctlService(), EmulatorService()], defaults: UserDefaults = .standard) {
        self.services = Dictionary(uniqueKeysWithValues: services.map { ($0.platform, $0) })
        self.defaults = defaults
        selection = DeviceSelection.saved(v2: defaults.string(forKey: selectionKey), v1: defaults.string(forKey: legacySelectionKey))
    }

    var selected: Device? {
        devices.first { $0.selection == selection }
    }

    /// The text sizes the selected device's platform offers.
    var textSizes: [TextSizeOption] {
        selected.flatMap { services[$0.platform]?.textSizes } ?? []
    }

    private func service(for device: Device) -> (any DeviceService)? { services[device.platform] }

    /// Whether the stream accepts touch and Home presses.
    var canSendInput: Bool {
        phase == .streaming && display?.inputAvailable == true
    }

    // MARK: Lifecycle

    /// Keeps the device list, the stream and the fps readout current. Run for as long as the
    /// panel is on screen; cancelling it stops the stream.
    func monitor() async {
        var tick = 0
        while !Task.isCancelled {
            if tick % 3 == 0 { await refreshDevices() }
            updateFramesPerSecond()
            tick += 1
            try? await Task.sleep(for: .seconds(1))
        }
        detach()
    }

    /// Xcode was just selected or a runtime added: an error from before Xcode was there no longer applies.
    func toolchainChanged() async {
        if display == nil, !isBusy, case .failed = phase { phase = .idle }
        await refreshDevices()
    }

    private func refreshDevices() async {
        var found: [Device] = []
        var failure: Error?
        var succeeded = false
        for platform in DevicePlatform.allCases {
            guard let service = services[platform] else { continue }
            do {
                found += try await service.devices()
                succeeded = true
            } catch {
                failure = error
            }
        }
        // One platform's tools failing must not hide the other's devices.
        if !succeeded, let failure {
            if display == nil, !isBusy { phase = .failed(failure.localizedDescription) }
            return
        }
        devices = found
        if selected == nil { choose(DeviceSelection.firstChoice(in: devices)?.selection) }
        await reconcile()
    }

    // MARK: User actions

    func select(_ device: Device) {
        guard device.selection != selection else { return }
        detach()
        choose(device.selection)
        phase = .idle
        Task { await reconcile() }
    }

    func boot() {
        guard let device = selected, let service = service(for: device), !isBusy else { return }
        Task {
            isBusy = true
            phase = .booting
            do {
                try await service.boot(device)
                isBusy = false
                await refreshDevices()
            } catch {
                isBusy = false
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func shutdown() {
        guard let device = selected, let service = service(for: device), !isBusy else { return }
        Task {
            isBusy = true
            detach()
            do {
                try await service.shutdown(device)
                phase = .idle
            } catch {
                phase = .failed(error.localizedDescription)
            }
            isBusy = false
            await refreshDevices()
        }
    }

    func pressHome() {
        display?.press(.home)
    }

    func recordTap(image: Data?) { lastTap = (Date(), image) }

    // MARK: Agent control

    /// Size of the screenshot the agent last saved: its coordinates are pixels of that picture.
    @ObservationIgnored private var lastShotSize: CGSize?
    @ObservationIgnored private var shotCount = 0

    /// Runs one command from the in-app agent and answers in words it can act on.
    func perform(_ command: SimulatorCommand) async -> String {
        guard canSendInput, let display else {
            return "The simulator isn't showing a running app. Ask the user to press Run in AppFast Studio."
        }
        switch command {
        case .screenshot:
            return saveScreenshot(of: display)
        case .home:
            display.press(.home)
            return "Pressed Home."
        case .type(let text):
            let typed = KeyboardMap.keys(for: text)
            for key in typed.keys {
                display.pressKey(key.usage, shift: key.shift)
                // Keys are queued on the display's input queue and each is held for 50 ms, so wait for that.
                try? await Task.sleep(for: .milliseconds(key.shift ? 130 : 110))
            }
            let note = typed.skipped.isEmpty ? "" : " Couldn't type: \(String(typed.skipped))."
            return "Typed \(typed.keys.count) characters.\(note) iOS may autocorrect words; take a screenshot to check."
        case .hold(let x, let y):
            guard let point = normalizedPoint(x, y) else { return Self.needsScreenshot }
            display.sendTouch(.began, at: point)
            try? await Task.sleep(for: .milliseconds(900))
            display.sendTouch(.ended, at: point)
            return "Held. Take a screenshot: a menu such as Paste or Select All may be showing."
        case .paste(let text):
            guard let device = selected, let service = service(for: device), await service.setClipboard(device, text: text) else {
                return "Could not set the simulator's clipboard."
            }
            return "Copied to the simulator's clipboard. Now long-press the text field (ms-sim hold X Y), then tap Paste in the menu that appears."
        case .key(let name):
            guard let key = KeyboardMap.named(name) else { return "Unknown key." }
            display.pressKey(key.usage, shift: false)
            return "Pressed \(name)."
        case .tap(let x, let y):
            guard let point = normalizedPoint(x, y) else { return Self.needsScreenshot }
            display.sendTouch(.began, at: point)
            try? await Task.sleep(for: .milliseconds(60))
            display.sendTouch(.ended, at: point)
            return "Tapped. Take a new screenshot to see the result."
        case .swipe(let x1, let y1, let x2, let y2):
            guard let start = normalizedPoint(x1, y1), let end = normalizedPoint(x2, y2) else { return Self.needsScreenshot }
            display.sendTouch(.began, at: start)
            let steps = 12
            for step in 1...steps {
                let t = Double(step) / Double(steps)
                display.sendTouch(.moved, at: CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
                try? await Task.sleep(for: .milliseconds(16))
            }
            display.sendTouch(.ended, at: end)
            return "Swiped. Take a new screenshot to see the result."
        }
    }

    private static let needsScreenshot = "Take a screenshot first: coordinates are pixels of the latest one."

    private func normalizedPoint(_ x: Double, _ y: Double) -> CGPoint? {
        lastShotSize.flatMap { SimulatorCommand.normalized(x: x, y: y, in: $0) }
    }

    /// Saves the screen as a PNG no larger than 1000 pixels on its long side, which is plenty to read and cheap to send.
    private func saveScreenshot(of display: any DeviceScreen) -> String {
        guard display.latestFrame != nil else { return "The screen has no picture yet. Try again in a second." }
        guard let (png, size) = Self.png(of: display, maxSide: 1000) else { return "Could not capture the screen." }
        shotCount += 1
        let url = AgentBridge.screenshotDirectory.appendingPathComponent("screen-\(shotCount).png")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: url)
        } catch {
            return "Could not save the screenshot: \(error.localizedDescription)"
        }
        lastShotSize = size
        return "\(url.path)\nSize \(Int(size.width))x\(Int(size.height)) pixels. Read this file to see the screen."
    }

    /// A PNG of what the simulator shows now, for the design step's picture of a screen. Nil when nothing is showing.
    func capturePNG() -> Data? {
        guard canSendInput, let display else { return nil }
        return Self.png(of: display, maxSide: 1000)?.data
    }

    /// The latest frame, scaled to at most `maxSide` pixels on its long side: plenty to read and cheap to send.
    private static func png(of display: any DeviceScreen, maxSide: CGFloat) -> (data: Data, size: CGSize)? {
        guard let surface = display.latestFrame else { return nil }
        var image = CIImage(ioSurface: surface)
        let scale = min(1, maxSide / max(image.extent.width, image.extent.height))
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = CIContext().createCGImage(image, from: image.extent),
              let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else { return nil }
        return (png, CGSize(width: cgImage.width, height: cgImage.height))
    }

    func setDark(_ dark: Bool) {
        guard let device = selected, device.isBooted, let service = service(for: device) else { return }
        isDark = dark
        Task { await service.setDark(device, dark) }
    }

    func setTextSize(_ id: String) {
        guard let device = selected, device.isBooted, let service = service(for: device) else { return }
        textSize = id
        Task { await service.setTextSize(device, id) }
    }

    func retry() {
        phase = .idle
        Task { await refreshDevices() }
    }

    // MARK: Streaming

    /// Brings the stream in line with the selected device's state: attach when it is running,
    /// let go when it stops (for example shut down from Xcode).
    private func reconcile() async {
        guard let device = selected else { detach(); return }

        if device.isBooted {
            if display == nil, !isBusy, phase != .booting {
                if case .failed = phase { return }   // wait for an explicit retry
                await connect(to: device)
            }
        } else {
            if display != nil { detach() }
            if phase == .streaming || phase == .connecting { phase = .idle }
        }
    }

    private func connect(to device: Device) async {
        guard let service = service(for: device) else { return }
        isBusy = true
        phase = .connecting
        do {
            let candidate = try await service.screen(for: device)
            // The user may have switched device while the display was attaching.
            guard selection == device.selection else {
                candidate.stop()
                isBusy = false
                return
            }
            display = candidate
            lastFrameCount = 0
            phase = .streaming
            isDark = await service.isDark(device)
            textSize = await service.textSize(device)
        } catch {
            phase = .failed(error.localizedDescription)
        }
        isBusy = false
    }

    private func detach() {
        display?.stop()
        display = nil
        screenSize = nil
        framesPerSecond = 0
        lastFrameCount = 0
    }

    private func updateFramesPerSecond() {
        guard let display else { return }
        let count = display.framesDelivered
        framesPerSecond = Int(count - lastFrameCount)
        lastFrameCount = count
        let size = display.pixelSize
        if size != .zero, size != screenSize { screenSize = size }
    }

    private func choose(_ selection: DeviceSelection?) {
        self.selection = selection
        defaults.set(selection?.rawValue, forKey: selectionKey)
    }
}
