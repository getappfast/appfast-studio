import AppKit
import CoreGraphics
import CoreImage
import Foundation
import Observation

enum SimulatorPhase: Equatable {
    case idle
    case booting
    case connecting
    case streaming
    case failed(String)
}

@MainActor
@Observable
final class SimulatorModel {
    private(set) var devices: [SimulatorDevice] = []
    private(set) var selectedUDID: String?
    private(set) var phase: SimulatorPhase = .idle
    private(set) var display: MSSimulatorDisplay?
    private(set) var screenSize: CGSize?
    private(set) var framesPerSecond = 0
    /// True while a boot, shutdown or connect is in flight; the UI disables its buttons meanwhile.
    private(set) var isBusy = false
    /// The booted device's appearance and text size, for the preview controls under the screen.
    private(set) var isDark: Bool?
    private(set) var contentSize: String?
    /// The last tap on the screen and a picture of the area around it, used as a picked element's thumbnail.
    private(set) var lastTap: (date: Date, image: Data?)?

    private let simctl = SimctlService()
    private let defaults = UserDefaults.standard
    private let selectionKey = "simulator.selected.v1"

    private var developerDir: String?
    private var lastFrameCount: UInt64 = 0

    init() {
        selectedUDID = defaults.string(forKey: selectionKey)
    }

    var selected: SimulatorDevice? {
        devices.first { $0.udid == selectedUDID }
    }

    /// Whether the stream accepts touch and Home presses.
    var canSendInput: Bool {
        phase == .streaming && display?.inputAvailable == true
    }

    // MARK: Lifecycle

    /// Keeps the device list, the stream and the fps readout current. Run for as long as the
    /// panel is on screen; cancelling it stops the stream.
    func monitor() async {
        developerDir = await simctl.developerDir()
        var tick = 0
        while !Task.isCancelled {
            if tick % 3 == 0 { await refreshDevices() }
            updateFramesPerSecond()
            tick += 1
            try? await Task.sleep(for: .seconds(1))
        }
        detach()
    }

    private func refreshDevices() async {
        do {
            devices = try await simctl.devices()
        } catch {
            if display == nil, !isBusy { phase = .failed(error.localizedDescription) }
            return
        }
        if selected == nil {
            // Prefer a running device, otherwise the first iPhone.
            let pick = devices.first(where: \.isBooted) ?? devices.first { $0.name.hasPrefix("iPhone") } ?? devices.first
            choose(pick)
        }
        await reconcile()
    }

    // MARK: User actions

    func select(_ device: SimulatorDevice) {
        guard device.udid != selectedUDID else { return }
        detach()
        choose(device)
        phase = .idle
        Task { await reconcile() }
    }

    func boot() {
        guard let device = selected, !isBusy else { return }
        Task {
            isBusy = true
            phase = .booting
            do {
                try await simctl.boot(device.udid)
                isBusy = false
                await refreshDevices()
            } catch {
                isBusy = false
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func shutdown() {
        guard let device = selected, !isBusy else { return }
        Task {
            isBusy = true
            detach()
            do {
                try await simctl.shutdown(device.udid)
                phase = .idle
            } catch {
                phase = .failed(error.localizedDescription)
            }
            isBusy = false
            await refreshDevices()
        }
    }

    func pressHome() {
        display?.pressHome()
    }

    func recordTap(image: Data?) { lastTap = (Date(), image) }

    // MARK: Agent control

    /// Size of the screenshot the agent last saved: its coordinates are pixels of that picture.
    @ObservationIgnored private var lastShotSize: CGSize?
    @ObservationIgnored private var shotCount = 0

    /// Runs one command from the in-app agent and answers in words it can act on.
    func perform(_ command: SimulatorCommand) async -> String {
        guard canSendInput, let display else {
            return "The simulator isn't showing a running app. Ask the user to press Run in Mobile Studio."
        }
        switch command {
        case .screenshot:
            return saveScreenshot(of: display)
        case .home:
            display.pressHome()
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
            guard let udid = selected?.udid, await simctl.setPasteboard(udid, text: text) else {
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
    private func saveScreenshot(of display: MSSimulatorDisplay) -> String {
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
    private static func png(of display: MSSimulatorDisplay, maxSide: CGFloat) -> (data: Data, size: CGSize)? {
        guard let surface = display.latestFrame else { return nil }
        var image = CIImage(ioSurface: surface)
        let scale = min(1, maxSide / max(image.extent.width, image.extent.height))
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = CIContext().createCGImage(image, from: image.extent),
              let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else { return nil }
        return (png, CGSize(width: cgImage.width, height: cgImage.height))
    }

    func setDark(_ dark: Bool) {
        guard let device = selected, device.isBooted else { return }
        isDark = dark
        Task { await simctl.setAppearance(device.udid, dark: dark) }
    }

    func setContentSize(_ size: String) {
        guard let device = selected, device.isBooted else { return }
        contentSize = size
        Task { await simctl.setContentSize(device.udid, size) }
    }

    /// Dynamic Type sizes simctl accepts, smallest first, with a short name for each.
    static let contentSizes: [(id: String, name: String)] = [
        ("extra-small", "Extra Small"), ("small", "Small"), ("medium", "Medium"), ("large", "Default"),
        ("extra-large", "Large"), ("extra-extra-large", "Extra Large"), ("extra-extra-extra-large", "Largest"),
        ("accessibility-medium", "Accessibility M"), ("accessibility-large", "Accessibility L"),
        ("accessibility-extra-large", "Accessibility XL"), ("accessibility-extra-extra-large", "Accessibility XXL"),
        ("accessibility-extra-extra-extra-large", "Accessibility XXXL"),
    ]

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

    private func connect(to device: SimulatorDevice) async {
        guard let developerDir else {
            phase = .failed("Xcode's developer directory was not found. Install Xcode and run xcode-select.")
            return
        }
        isBusy = true
        phase = .connecting
        let candidate = MSSimulatorDisplay(udid: device.udid, developerDir: developerDir)
        do {
            try await candidate.start()
            // The user may have switched device while the display was attaching.
            guard selectedUDID == device.udid else {
                candidate.stop()
                isBusy = false
                return
            }
            display = candidate
            lastFrameCount = 0
            phase = .streaming
            isDark = await simctl.appearance(device.udid).map { $0 == "dark" }
            contentSize = await simctl.contentSize(device.udid)
        } catch {
            candidate.stop()
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

    private func choose(_ device: SimulatorDevice?) {
        selectedUDID = device?.udid
        defaults.set(device?.udid, forKey: selectionKey)
    }
}
