import CoreGraphics

/// Where the app-flow map sits in its view: a scale, and where the map's top-left corner is. Pure maths, so zooming,
/// panning and fitting are tested without a window. Points are in the view's own space, origin top-left.
struct FlowViewport: Equatable, Sendable {
    /// How far the map zooms out and in.
    static let scales: ClosedRange<CGFloat> = 0.1...3
    /// What the zoom buttons and shortcuts step through.
    static let steps: [CGFloat] = [0.1, 0.15, 0.25, 0.35, 0.5, 0.75, 1, 1.5, 2, 3]
    /// How far a map bigger than the view may be pulled past its edge, so the margin around it can be seen.
    static let overscroll: CGFloat = 24

    var scale: CGFloat = 1
    /// Where the map's top-left corner is in the view.
    var origin: CGPoint = .zero

    /// The same zoom with the map moved back into reach: centred on an axis where it's smaller than the view,
    /// otherwise never further out than `overscroll`.
    func clamped(content: CGSize, in view: CGSize) -> FlowViewport {
        func axis(_ origin: CGFloat, content: CGFloat, view: CGFloat) -> CGFloat {
            let length = content * scale
            if length <= view { return (view - length) / 2 }
            return min(max(origin, view - length - Self.overscroll), Self.overscroll)
        }
        return FlowViewport(scale: scale, origin: CGPoint(x: axis(origin.x, content: content.width, view: view.width),
                                                          y: axis(origin.y, content: content.height, view: view.height)))
    }

    /// Zoomed to `target` (kept within `scales`), with the map point under `anchor` staying where it is.
    func zoomed(to target: CGFloat, around anchor: CGPoint) -> FlowViewport {
        let next = min(max(target, Self.scales.lowerBound), Self.scales.upperBound)
        let ratio = next / scale
        return FlowViewport(scale: next, origin: CGPoint(x: anchor.x - (anchor.x - origin.x) * ratio,
                                                         y: anchor.y - (anchor.y - origin.y) * ratio))
    }

    func panned(by delta: CGSize) -> FlowViewport {
        FlowViewport(scale: scale, origin: CGPoint(x: origin.x + delta.width, y: origin.y + delta.height))
    }

    /// The next step up from `scale`, or the largest scale.
    static func stepIn(from scale: CGFloat) -> CGFloat {
        steps.first { $0 > scale * 1.01 } ?? scales.upperBound
    }

    /// The next step down from `scale`, or the smallest scale.
    static func stepOut(from scale: CGFloat) -> CGFloat {
        steps.last { $0 < scale / 1.01 } ?? scales.lowerBound
    }

    /// The whole map in view, centred. It's never enlarged past its real size.
    static func fit(content: CGSize, in view: CGSize) -> FlowViewport {
        guard content.width > 0, content.height > 0, view.width > 0, view.height > 0 else { return FlowViewport() }
        let scale = min(1, view.width / content.width, view.height / content.height)
        return FlowViewport(scale: min(max(scale, scales.lowerBound), scales.upperBound))
            .clamped(content: content, in: view)
    }

    /// The map's left edge at the view's, with `focus` (a card, in map points) in the middle from top to bottom.
    /// For a map too big to fit that still opens where the flow starts.
    static func leading(on focus: CGRect, scale: CGFloat, content: CGSize, in view: CGSize) -> FlowViewport {
        FlowViewport(scale: scale, origin: CGPoint(x: 0, y: view.height / 2 - focus.midY * scale))
            .clamped(content: content, in: view)
    }
}
