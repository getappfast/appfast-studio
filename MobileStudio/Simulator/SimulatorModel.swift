import CoreGraphics
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
