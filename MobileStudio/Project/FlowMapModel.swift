import AppKit
import Observation
import SwiftUI

/// Where the app-flow map is and how big it's drawn. `Workspace` owns it, so the zoom buttons, the View menu,
/// the trackpad and the mouse all move the same viewport.
@MainActor
@Observable
final class FlowMapModel {
    /// What the map needs to place itself, in points.
    struct Layout: Equatable {
        var folder: String
        var content: CGSize
        /// The part of the canvas the map is seen in: the canvas less the floating sidebar's overlap.
        var view: CGSize
        /// The start screen's card in map points, which a map too big to fit opens on.
        var start: CGRect?

        var isUsable: Bool { content.width > 0 && content.height > 0 && view.width > 0 && view.height > 0 }
    }

    /// A map that doesn't fit at this scale opens at it, on its start screen, instead of shrinking past reading.
    static let readableScale: CGFloat = 0.5

    private(set) var viewport = FlowViewport()
    /// True until the user zooms or pans: the map then keeps fitting as the window or the flow changes.
    private(set) var isFitted = true
    /// False until the first layout and while the map isn't shown, so it never flashes in the wrong place.
    private(set) var isPlaced = false

    @ObservationIgnored private var layout: Layout?
    /// The folder the map last opened for; another folder opens it afresh.
    @ObservationIgnored private var openedFolder: String?

    var percent: Int { Int((viewport.scale * 100).rounded()) }
    var canZoomIn: Bool { isPlaced && viewport.scale < FlowViewport.scales.upperBound - 0.001 }
    var canZoomOut: Bool { isPlaced && viewport.scale > FlowViewport.scales.lowerBound + 0.001 }

    // MARK: Layout

    /// The map was laid out, or the view around it resized. Keeps the user's zoom unless they never changed it.
    func update(_ layout: Layout) {
        guard layout.isUsable else { return }
        self.layout = layout
        if openedFolder != layout.folder {
            openedFolder = layout.folder
            open(layout)
        } else if isFitted {
            viewport = .fit(content: layout.content, in: layout.view)
        } else {
            viewport = viewport.clamped(content: layout.content, in: layout.view)
        }
        isPlaced = true
    }

    /// The map left the screen.
    func detach() { isPlaced = false }

    private func open(_ layout: Layout) {
        let fit = FlowViewport.fit(content: layout.content, in: layout.view)
        if fit.scale >= Self.readableScale || layout.start == nil {
            viewport = fit
            isFitted = true
        } else if let start = layout.start {
            viewport = .leading(on: start, scale: Self.readableScale, content: layout.content, in: layout.view)
            isFitted = false
        }
    }

    // MARK: Zoom and pan

    func zoomIn() { zoom(to: FlowViewport.stepIn(from: viewport.scale)) }
    func zoomOut() { zoom(to: FlowViewport.stepOut(from: viewport.scale)) }
    func actualSize() { zoom(to: 1) }

    /// Zooms to `scale` around the middle of the view.
    func zoom(to scale: CGFloat) {
        guard let layout else { return }
        let middle = CGPoint(x: layout.view.width / 2, y: layout.view.height / 2)
        move(animated: true) { $0.zoomed(to: scale, around: middle) }
    }

    func fit() {
        guard let layout else { return }
        move(animated: true, fitted: true) { _ in .fit(content: layout.content, in: layout.view) }
    }

    /// A pinch or ⌘-scroll: zooms by `factor` around the pointer, following the fingers with no animation.
    func zoom(by factor: CGFloat, around anchor: CGPoint) {
        guard factor.isFinite, factor > 0 else { return }
        move(animated: false) { $0.zoomed(to: $0.scale * factor, around: anchor) }
    }

    func pan(by delta: CGSize) {
        move(animated: false) { $0.panned(by: delta) }
    }

    /// A two-finger double tap: close up on the pointer, or back out to the whole map.
    func smartZoom(at point: CGPoint) {
        if viewport.scale < 0.99 {
            move(animated: true) { $0.zoomed(to: 1, around: point) }
        } else {
            fit()
        }
    }

    private func move(animated: Bool, fitted: Bool = false, _ change: (FlowViewport) -> FlowViewport) {
        guard let layout else { return }
        let next = change(viewport).clamped(content: layout.content, in: layout.view)
        // Nothing moved (the map is already centred, or at the zoom limit): that isn't leaving the fitted view.
        if next == viewport {
            if fitted { isFitted = true }
            return
        }
        isFitted = fitted
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            withAnimation(.smooth(duration: 0.22)) { viewport = next }
        } else {
            viewport = next
        }
    }
}
