import SwiftUI
import AppKit

/// Draws the simulator's frames and turns the mouse into touches: a click is a tap, and a click
/// and drag is a swipe. Each frame is an IOSurface that the simulator renders into, set straight
/// on the layer so the GPU composites it with no copy.
struct SimulatorScreen: NSViewRepresentable {
    let display: MSSimulatorDisplay?
    /// The screen's corner radius as a share of its width, so the corners match the device at any size.
    var cornerFraction: CGFloat
    /// What VoiceOver says for the screen.
    var accessibilityName: String

    func makeNSView(context: Context) -> ScreenView { ScreenView() }

    func updateNSView(_ view: ScreenView, context: Context) {
        view.display = display
        view.cornerFraction = cornerFraction
        view.setAccessibilityLabel(accessibilityName)
    }

    final class ScreenView: NSView {
        var display: MSSimulatorDisplay? {
            didSet {
                guard display !== oldValue else { return }
                oldValue?.frameHandler = nil
                display?.frameHandler = { [weak self] surface in
                    MainActor.assumeIsolated { self?.layer?.contents = surface }
                }
                if display == nil { layer?.contents = nil }
            }
        }

        var cornerFraction: CGFloat = 0 {
            didSet { if cornerFraction != oldValue { needsLayout = true } }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            setAccessibilityElement(true)
            setAccessibilityRole(.image)
            setAccessibilityHelp("Click to tap, drag to swipe.")
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func layout() {
            super.layout()
            layer?.cornerRadius = bounds.width * cornerFraction
        }

        // MARK: Mouse -> touch

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) { sendTouch(.began, event) }
        override func mouseDragged(with event: NSEvent) { sendTouch(.moved, event) }
        override func mouseUp(with event: NSEvent) { sendTouch(.ended, event) }

        /// The view is sized to the screen's aspect ratio, so the view bounds are the screen.
        /// AppKit's origin is bottom-left; the simulator's is top-left.
        private func sendTouch(_ phase: MSTouchPhase, _ event: NSEvent) {
            guard bounds.width > 0, bounds.height > 0 else { return }
            let point = convert(event.locationInWindow, from: nil)
            display?.sendTouch(phase, at: CGPoint(x: point.x / bounds.width, y: 1 - point.y / bounds.height))
        }

        override func makeBackingLayer() -> CALayer {
            let layer = CALayer()
            layer.contentsGravity = .resizeAspect
            layer.backgroundColor = NSColor.black.cgColor
            layer.cornerCurve = .continuous
            layer.masksToBounds = true
            return layer
        }
    }
}

extension SimulatorDevice {
    /// Roughly the display's corner radius over its width: rounded for Face ID iPhones, square for
    /// Home-button ones, slight for iPads.
    var screenCornerFraction: CGFloat {
        if name.contains("iPad") { return 0.025 }
        if name.contains("SE") || name.contains("iPhone 8") { return 0 }
        return 0.135
    }
}

/// The device, centred on the canvas, with its empty and error states. Device choice and Boot live in
/// the toolbar's destination menu.
struct SimulatorCanvas: View {
    let model: SimulatorModel
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 12) {
            screen
            footer
        }
        .padding(.horizontal, 32)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
        .task { await model.monitor() }
    }

    // MARK: Screen

    @ViewBuilder
    private var screen: some View {
        if model.display != nil, let size = model.screenSize, let device = model.selected {
            SimulatorScreen(display: model.display, cornerFraction: device.screenCornerFraction,
                            accessibilityName: "\(device.name) screen")
                .aspectRatio(size, contentMode: .fit)
                .shadow(color: .black.opacity(0.25), radius: 14, y: 5)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onHover { hovering = $0 }
        } else {
            placeholder.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        switch model.phase {
        case .booting:
            ContentUnavailableView {
                ProgressView().controlSize(.large)
            } description: {
                Text("Booting \(model.selected?.name ?? "the simulator")…")
            }
        case .connecting:
            ContentUnavailableView {
                ProgressView().controlSize(.large)
            } description: {
                Text("Connecting to the display…")
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Can't Show the Simulator", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { model.retry() }
            }
        default:
            if model.devices.isEmpty {
                ContentUnavailableView("No Simulators", systemImage: "iphone.slash",
                                       description: Text("Add an iOS runtime in Xcode › Settings › Components."))
            } else if let device = model.selected {
                ContentUnavailableView {
                    Label("\(device.name) Is Off", systemImage: "iphone")
                } description: {
                    Text("Boot it to see its screen here, or press Run to boot and run in one go.")
                } actions: {
                    Button("Boot \(device.name)") { model.boot() }
                        .disabled(model.isBusy || device.isTransitioning)
                }
            } else {
                ContentUnavailableView("Choose a Simulator", systemImage: "iphone",
                                       description: Text("Pick a device from the menu in the toolbar."))
            }
        }
    }

    // MARK: Footer

    /// Home, and what is on screen. The technical details only show while the pointer is over the device.
    @ViewBuilder
    private var footer: some View {
        if let device = model.selected, model.phase == .streaming {
            HStack(spacing: 10) {
                Button { model.pressHome() } label: { Label("Home", systemImage: "house") }
                    .disabled(!model.canSendInput)
                    .help(model.canSendInput ? "Press the Home button" : "Touch input is unavailable on this Xcode.")
                Text(caption(device)).foregroundStyle(.secondary).monospacedDigit()
            }
            .font(.callout)
            .controlSize(.small)
        }
    }

    private func caption(_ device: SimulatorDevice) -> String {
        guard hovering, let size = model.screenSize else {
            return model.canSendInput ? "Click to tap, drag to swipe." : "View only."
        }
        let fps = model.framesPerSecond > 0 ? "\(model.framesPerSecond) fps" : "idle"
        return "\(device.name) · \(device.runtime) · \(Int(size.width))×\(Int(size.height)) · \(fps)"
    }
}
