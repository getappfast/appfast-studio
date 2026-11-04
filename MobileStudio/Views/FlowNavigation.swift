import AppKit
import SwiftUI

/// Turns the trackpad and the mouse wheel into pan and zoom over the map: two fingers or the wheel pan, a pinch or
/// ⌘/⌥-scroll zooms around the pointer, and a two-finger double tap zooms in and out. SwiftUI has no scroll-wheel
/// or pinch event on macOS 14 that says where the pointer is, so this watches the window's events and takes the
/// ones over its own bounds, wherever the cards and buttons sit above it.
struct FlowInput: NSViewRepresentable {
    let model: FlowMapModel

    func makeNSView(context: Context) -> InputView { InputView() }

    func updateNSView(_ view: InputView, context: Context) { view.model = model }

    static func dismantleNSView(_ view: InputView, coordinator: ()) { view.stop() }

    final class InputView: NSView {
        var model: FlowMapModel?
        private var monitor: Any?

        // Top-left origin, like the viewport.
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            // Local monitors run on the main thread, and this closure takes this view's isolation.
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify, .smartMagnify, .keyDown]) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// Returns nil for an event this took, so nothing else sees it.
        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let model, event.window === window else { return event }
            if event.type == .keyDown {
                // ⌘= is what most people press for Zoom In. The menu item is ⌘+.
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                guard flags == .command, event.charactersIgnoringModifiers == "=" else { return event }
                model.zoomIn()
                return nil
            }
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point) else { return event }
            switch event.type {
            case .scrollWheel:
                // A wheel reports lines, a trackpad points.
                let unit: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
                let delta = CGSize(width: event.scrollingDeltaX * unit, height: event.scrollingDeltaY * unit)
                if !event.modifierFlags.isDisjoint(with: [.command, .option]) {
                    model.zoom(by: exp(delta.height * 0.01), around: point)
                } else {
                    model.pan(by: delta)
                }
            case .magnify:
                model.zoom(by: 1 + event.magnification, around: point)
            case .smartMagnify:
                model.smartZoom(at: point)
            default:
                return event
            }
            return nil
        }
    }
}

/// The empty canvas behind the cards: drag it to pan. Cards sit above it, so a click on one still asks Claude.
struct FlowPanLayer: View {
    let model: FlowMapModel
    @State private var lastTranslation = CGSize.zero
    @State private var isPanning = false

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        model.pan(by: CGSize(width: value.translation.width - lastTranslation.width,
                                             height: value.translation.height - lastTranslation.height))
                        lastTranslation = value.translation
                        isPanning = true
                    }
                    .onEnded { _ in
                        lastTranslation = .zero
                        isPanning = false
                    }
            )
            .grabCursor(isPanning)
            .accessibilityHidden(true)
    }
}

private extension View {
    @ViewBuilder
    func grabCursor(_ isGrabbing: Bool) -> some View {
        if #available(macOS 15, *) {
            pointerStyle(isGrabbing ? .grabActive : .grabIdle)
        } else {
            self
        }
    }
}

/// Dots that move and scale with the map, so panning and zooming are felt even over empty canvas.
struct FlowGrid: View {
    let model: FlowMapModel
    let leadingInset: CGFloat

    var body: some View {
        let viewport = model.viewport
        Canvas { context, size in
            // Doubled until the dots are far enough apart not to turn into a texture.
            var spacing = 32 * viewport.scale
            while spacing < 20 { spacing *= 2 }
            let startX = (leadingInset + viewport.origin.x).truncatingRemainder(dividingBy: spacing)
            let startY = viewport.origin.y.truncatingRemainder(dividingBy: spacing)
            var dots = Path()
            var x = startX < 0 ? startX + spacing : startX
            while x < size.width {
                var y = startY < 0 ? startY + spacing : startY
                while y < size.height {
                    dots.addEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
                    y += spacing
                }
                x += spacing
            }
            context.fill(dots, with: .color(.primary.opacity(0.14)))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Zoom out, the level (a menu of presets), zoom in, and fit. The View menu has the same actions.
struct FlowZoomControls: View {
    let model: FlowMapModel

    var body: some View {
        HStack(spacing: 2) {
            Button(action: model.zoomOut) { Label("Zoom Out", systemImage: "minus").labelStyle(.iconOnly) }
                .disabled(!model.canZoomOut)
                .help("Zoom Out (⌘−)")
            Menu {
                Button("Zoom to Fit", action: model.fit)
                Button("Actual Size", action: model.actualSize)
                Divider()
                ForEach([0.25, 0.5, 0.75, 1, 1.5, 2] as [CGFloat], id: \.self) { scale in
                    Button("\(Int(scale * 100))%") { model.zoom(to: scale) }
                }
            } label: {
                Text("\(model.percent)%").monospacedDigit().frame(minWidth: 40)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Zoom level")
            .accessibilityLabel("Zoom level")
            .accessibilityValue("\(model.percent) percent")
            Button(action: model.zoomIn) { Label("Zoom In", systemImage: "plus").labelStyle(.iconOnly) }
                .disabled(!model.canZoomIn)
                .help("Zoom In (⌘+)")
            Divider().frame(height: 14).padding(.horizontal, 2)
            Button(action: model.fit) { Label("Zoom to Fit", systemImage: "arrow.up.left.and.arrow.down.right").labelStyle(.iconOnly) }
                .disabled(model.isFitted)
                .help("Zoom to Fit (⌘9)")
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator))
        .accessibilityElement(children: .contain)
    }
}
