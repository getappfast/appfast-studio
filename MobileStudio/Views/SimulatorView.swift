import SwiftUI
import AppKit
import CoreImage
import IOSurface

/// Draws the simulator's frames and turns the mouse into touches: a click is a tap, and a click
/// and drag is a swipe. Each frame is an IOSurface that the simulator renders into, set straight
/// on the layer so the GPU composites it with no copy.
struct SimulatorScreen: NSViewRepresentable {
    let display: MSSimulatorDisplay?
    /// The screen's corner radius as a share of its width, so the corners match the device at any size.
    var cornerFraction: CGFloat
    /// What VoiceOver says for the screen.
    var accessibilityName: String
    /// Called on each tap with a PNG of the area around it.
    var onTap: (Data?) -> Void = { _ in }

    func makeNSView(context: Context) -> ScreenView { ScreenView() }

    func updateNSView(_ view: ScreenView, context: Context) {
        view.display = display
        view.cornerFraction = cornerFraction
        view.setAccessibilityLabel(accessibilityName)
        view.onTap = onTap
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

        var onTap: (Data?) -> Void = { _ in }

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

        override func mouseDown(with event: NSEvent) {
            sendTouch(.began, event)
            onTap(thumbnail(around: convert(event.locationInWindow, from: nil)))
        }
        override func mouseDragged(with event: NSEvent) { sendTouch(.moved, event) }
        override func mouseUp(with event: NSEvent) { sendTouch(.ended, event) }

        /// The view is sized to the screen's aspect ratio, so the view bounds are the screen.
        /// AppKit's origin is bottom-left; the simulator's is top-left.
        private func sendTouch(_ phase: MSTouchPhase, _ event: NSEvent) {
            guard bounds.width > 0, bounds.height > 0 else { return }
            let point = convert(event.locationInWindow, from: nil)
            display?.sendTouch(phase, at: CGPoint(x: point.x / bounds.width, y: 1 - point.y / bounds.height))
        }

        /// A PNG of the screen around `point`: the width of the screen and a band of its height, so the picked
        /// element shows with a little context.
        private func thumbnail(around point: CGPoint) -> Data? {
            guard let contents = layer?.contents, CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID(),
                  bounds.width > 0, bounds.height > 0 else { return nil }
            let image = CIImage(ioSurface: unsafeBitCast(contents as AnyObject, to: IOSurfaceRef.self))
            let size = image.extent.size
            let band = size.height * 0.16
            // Both AppKit and Core Image put the origin at the bottom left.
            let centre = point.y / bounds.height * size.height
            let crop = CGRect(x: 0, y: min(max(centre - band / 2, 0), size.height - band), width: size.width, height: band)
            guard let cgImage = CIContext().createCGImage(image.cropped(to: crop), from: crop) else { return nil }
            let rep = NSBitmapImageRep(cgImage: cgImage)
            return rep.representation(using: .png, properties: [:])
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
    /// Pick is waiting for a tap: the screen gets an outline and a crosshair so it's clear where to click.
    var isPicking = false
    /// Draw the device's hardware frame around the screen when Xcode has one for it.
    var showsFrame = true
    @State private var hovering = false
    @State private var chrome: DeviceChrome?

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
            framed(screen(of: device, size: size), chrome: showsFrame ? chrome : nil)
                .shadow(color: .black.opacity(0.25), radius: 14, y: 5)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task(id: device.name) { chrome = DeviceChrome.load(deviceName: device.name) }
                .onHover { inside in
                    hovering = inside
                    if isPicking { inside ? NSCursor.crosshair.push() : NSCursor.pop() }
                }
        } else {
            placeholder.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func screen(of device: SimulatorDevice, size: CGSize) -> some View {
        // With a frame, the screen's corners come from the device itself, so they meet the frame's inner edge.
        let corner = showsFrame ? chrome.map { $0.cornerRadius / $0.screenSize.width } ?? device.screenCornerFraction
            : device.screenCornerFraction
        return SimulatorScreen(display: model.display, cornerFraction: corner,
                               accessibilityName: "\(device.name) screen", onTap: model.recordTap)
            .aspectRatio(size, contentMode: .fit)
            .overlay {
                if isPicking {
                    GeometryReader { proxy in
                        RoundedRectangle(cornerRadius: proxy.size.width * corner, style: .continuous)
                            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 5]))
                    }
                    .allowsHitTesting(false)
                }
            }
    }

    /// The screen on top of the frame's artwork, scaled together. The frame never takes clicks.
    @ViewBuilder
    private func framed(_ screen: some View, chrome: DeviceChrome?) -> some View {
        if let chrome, let image = NSImage(contentsOf: chrome.compositeURL) {
            GeometryReader { proxy in
                let scale = proxy.size.width / chrome.compositeSize.width
                ZStack {
                    Image(nsImage: image).resizable().allowsHitTesting(false)
                    screen.padding(.horizontal, chrome.inset.width * scale).padding(.vertical, chrome.inset.height * scale)
                }
            }
            .aspectRatio(chrome.compositeSize, contentMode: .fit)
        } else {
            screen
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

    /// Home, the preview settings people check most (dark mode, bigger text), and what is on screen. The
    /// technical details only show while the pointer is over the device.
    @ViewBuilder
    private var footer: some View {
        if let device = model.selected, model.phase == .streaming {
            // Labelled when there's room, icons only when not. The footer must never ask for width: on macOS 26 a
            // minimum here is paid twice and pushes the sidebar and chat off the window.
            ViewThatFits(in: .horizontal) {
                controls(device, labelled: true)
                controls(device, labelled: false)
            }
            .frame(minWidth: 0, maxWidth: .infinity)
            .font(.callout)
            .controlSize(.small)
        }
    }

    private func controls(_ device: SimulatorDevice, labelled: Bool) -> some View {
        HStack(spacing: 10) {
            Group {
                Button { model.pressHome() } label: { Label("Home", systemImage: "house") }
                    .disabled(!model.canSendInput)
                    .help(model.canSendInput ? "Press the Home button" : "Touch input is unavailable on this Xcode.")
                if let dark = model.isDark {
                    Button { model.setDark(!dark) } label: {
                        Label(dark ? "Dark" : "Light", systemImage: dark ? "moon.fill" : "sun.max.fill")
                    }
                    .help("Switch the simulator to \(dark ? "light" : "dark") mode")
                }
                if let size = model.contentSize {
                    Menu {
                        ForEach(SimulatorModel.contentSizes, id: \.id) { option in
                            Toggle(option.name, isOn: Binding(get: { size == option.id }, set: { _ in model.setContentSize(option.id) }))
                        }
                    } label: {
                        Label("Text Size", systemImage: "textformat.size")
                    }
                    .fixedSize()
                    .help("Preview the app with a different text size")
                }
            }
            .labelStyle(AdaptiveLabelStyle(showsTitle: labelled))
            if labelled {
                Text(caption(device)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
        }
    }

    private func caption(_ device: SimulatorDevice) -> String {
        if isPicking { return "Click the element you mean." }
        guard hovering, let size = model.screenSize else {
            return model.canSendInput ? "Click to tap, drag to swipe." : "View only."
        }
        let fps = model.framesPerSecond > 0 ? "\(model.framesPerSecond) fps" : "idle"
        return "\(device.name) · \(device.runtime) · \(Int(size.width))×\(Int(size.height)) · \(fps)"
    }
}

/// Title and icon, or the icon alone (VoiceOver still reads the title).
private struct AdaptiveLabelStyle: LabelStyle {
    let showsTitle: Bool

    func makeBody(configuration: Configuration) -> some View {
        if showsTitle {
            Label(configuration)
        } else {
            Label(configuration).labelStyle(.iconOnly)
        }
    }
}
