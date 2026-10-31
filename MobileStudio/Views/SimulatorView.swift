import SwiftUI
import AppKit

/// Draws the simulator's frames and turns the mouse into touches: a click is a tap, and a click
/// and drag is a swipe. Each frame is an IOSurface that the simulator renders into, set straight
/// on the layer so the GPU composites it with no copy.
struct SimulatorScreen: NSViewRepresentable {
    let display: MSSimulatorDisplay?

    func makeNSView(context: Context) -> ScreenView { ScreenView() }

    func updateNSView(_ view: ScreenView, context: Context) {
        view.display = display
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

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
        }

        required init?(coder: NSCoder) { fatalError("not used") }

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
            layer.cornerRadius = 34
            layer.cornerCurve = .continuous
            layer.masksToBounds = true
            return layer
        }
    }
}

struct SimulatorPanel<Accessory: View>: View {
    let model: SimulatorModel
    /// Floats under the device screen, centred.
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            toolbar
            screen
            accessory().frame(maxWidth: .infinity)
            caption
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await model.monitor() }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Label("Simulator", systemImage: "iphone").font(.headline)
            Spacer()
            deviceMenu
            homeButton
            actionButton
        }
    }

    private var deviceMenu: some View {
        Menu {
            ForEach(runtimes, id: \.self) { runtime in
                Section(runtime) {
                    ForEach(model.devices.filter { $0.runtime == runtime }) { device in
                        Button {
                            model.select(device)
                        } label: {
                            Text(device.isBooted ? "\(device.name)  ·  running" : device.name)
                        }
                    }
                }
            }
        } label: {
            Text(model.selected?.name ?? "Choose device")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(model.devices.isEmpty)
    }

    @ViewBuilder
    private var homeButton: some View {
        if model.canSendInput {
            Button { model.pressHome() } label: { Label("Home", systemImage: "house").labelStyle(.iconOnly) }
                .help("Home")
        }
    }

    private var runtimes: [String] {
        var seen = Set<String>()
        return model.devices.map(\.runtime).filter { seen.insert($0).inserted }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch model.phase {
        case .booting:
            ProgressView().controlSize(.small)
        default:
            if let device = model.selected {
                if device.isBooted {
                    Button("Shut down") { model.shutdown() }.disabled(model.isBusy)
                } else {
                    Button("Boot") { model.boot() }.disabled(model.isBusy || device.isTransitioning)
                }
            }
        }
    }

    // MARK: Screen

    @ViewBuilder
    private var screen: some View {
        ZStack {
            if model.display != nil, let size = model.screenSize {
                SimulatorScreen(display: model.display)
                    .aspectRatio(size, contentMode: .fit)
                    .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var placeholder: some View {
        VStack(spacing: 10) {
            switch model.phase {
            case .booting:
                ProgressView()
                Text("Booting \(model.selected?.name ?? "simulator")…").foregroundStyle(.secondary)
            case .connecting:
                ProgressView()
                Text("Connecting to the display…").foregroundStyle(.secondary)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Try again") { model.retry() }
            default:
                Image(systemName: "iphone.gen3").font(.system(size: 44)).foregroundStyle(.tertiary)
                Text(model.devices.isEmpty ? "No simulators found." : "Boot a simulator to see its screen here.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    // MARK: Caption

    @ViewBuilder
    private var caption: some View {
        if let device = model.selected, model.phase == .streaming, let size = model.screenSize {
            VStack(spacing: 2) {
                Text("\(device.name) · \(device.runtime) · \(Int(size.width))×\(Int(size.height)) · \(model.framesPerSecond > 0 ? "\(model.framesPerSecond) fps" : "idle")")
                Text(model.canSendInput ? "Click to tap, drag to swipe." : "View only: touch input is unavailable on this Xcode.")
            }
            .font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}
