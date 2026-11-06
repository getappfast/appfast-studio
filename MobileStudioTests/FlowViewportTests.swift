import CoreGraphics
import Testing
@testable import AppFast_Studio

struct FlowViewportTests {
    private let content = CGSize(width: 1000, height: 4000)
    private let view = CGSize(width: 800, height: 600)

    private func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.001 }

    @Test func zoomKeepsThePointUnderThePointerStill() {
        let before = FlowViewport(scale: 0.5, origin: CGPoint(x: -120, y: -300))
        let anchor = CGPoint(x: 300, y: 200)
        let mapPoint = CGPoint(x: (anchor.x - before.origin.x) / before.scale, y: (anchor.y - before.origin.y) / before.scale)
        let after = before.zoomed(to: 1.5, around: anchor)
        #expect(near(after.scale, 1.5))
        #expect(near(after.origin.x + mapPoint.x * after.scale, anchor.x))
        #expect(near(after.origin.y + mapPoint.y * after.scale, anchor.y))
    }

    @Test func zoomStaysWithinTheScaleRange() {
        let viewport = FlowViewport()
        #expect(viewport.zoomed(to: 50, around: .zero).scale == FlowViewport.scales.upperBound)
        #expect(viewport.zoomed(to: 0.001, around: .zero).scale == FlowViewport.scales.lowerBound)
    }

    @Test func aMapSmallerThanTheViewIsCentred() {
        let small = CGSize(width: 400, height: 300)
        let viewport = FlowViewport(scale: 1, origin: CGPoint(x: -50, y: 900)).clamped(content: small, in: view)
        #expect(viewport.origin == CGPoint(x: 200, y: 150))
    }

    @Test func aBigMapCantBePannedOutOfReach() {
        let away = FlowViewport(scale: 1, origin: CGPoint(x: -9000, y: -9000)).clamped(content: content, in: view)
        #expect(away.origin == CGPoint(x: view.width - content.width - FlowViewport.overscroll,
                                       y: view.height - content.height - FlowViewport.overscroll))
        let back = FlowViewport(scale: 1, origin: CGPoint(x: 500, y: 500)).clamped(content: content, in: view)
        #expect(back.origin == CGPoint(x: FlowViewport.overscroll, y: FlowViewport.overscroll))
    }

    @Test func eachAxisClampsOnItsOwn() {
        // Narrower than the view but taller: centred across, free along.
        let narrow = CGSize(width: 300, height: 2000)
        let viewport = FlowViewport(scale: 1, origin: CGPoint(x: 0, y: -400)).clamped(content: narrow, in: view)
        #expect(viewport.origin == CGPoint(x: 250, y: -400))
    }

    @Test func fitShowsTheWholeMapCentred() {
        let fit = FlowViewport.fit(content: content, in: view)
        #expect(near(fit.scale, 0.15))
        #expect(near(fit.origin.x, (view.width - content.width * fit.scale) / 2))
        #expect(near(fit.origin.y, 0))
    }

    @Test func fitNeverEnlargesAMapPastItsRealSize() {
        let fit = FlowViewport.fit(content: CGSize(width: 200, height: 100), in: view)
        #expect(fit.scale == 1)
        #expect(fit.origin == CGPoint(x: 300, y: 250))
    }

    @Test func fitOfAnEmptyViewIsTheDefault() {
        #expect(FlowViewport.fit(content: content, in: .zero) == FlowViewport())
    }

    @Test func stepsGoUpAndDownThroughThePresets() {
        #expect(FlowViewport.stepIn(from: 1) == 1.5)
        #expect(FlowViewport.stepOut(from: 1) == 0.75)
        #expect(FlowViewport.stepIn(from: 0.6) == 0.75)
        #expect(FlowViewport.stepOut(from: 0.6) == 0.5)
        #expect(FlowViewport.stepIn(from: 3) == 3)
        #expect(FlowViewport.stepOut(from: 0.1) == 0.1)
        // A scale a hair off a preset still moves on to the next one.
        #expect(FlowViewport.stepIn(from: 0.4999) == 0.75)
    }

    @Test func leadingPutsTheStartCardInTheMiddleAtTheLeftEdge() {
        let wide = CGSize(width: 3000, height: 4000)
        let start = CGRect(x: 48, y: 1900, width: 128, height: 232)
        let viewport = FlowViewport.leading(on: start, scale: 0.5, content: wide, in: view)
        #expect(viewport.scale == 0.5)
        #expect(viewport.origin.x == 0)
        #expect(near(viewport.origin.y + start.midY * 0.5, view.height / 2))
    }
}

@MainActor
struct FlowMapModelTests {
    private func layout(content: CGSize, view: CGSize = CGSize(width: 800, height: 600), folder: String = "/a",
                        start: CGRect? = CGRect(x: 48, y: 1900, width: 128, height: 232)) -> FlowMapModel.Layout {
        FlowMapModel.Layout(folder: folder, content: content, view: view, start: start)
    }

    @Test func aMapThatFitsReadablyOpensFitted() {
        let model = FlowMapModel()
        model.update(layout(content: CGSize(width: 1000, height: 700)))
        #expect(model.isFitted)
        #expect(model.isPlaced)
        #expect(model.viewport.scale == 0.8)
    }

    @Test func aMapTooBigToReadOpensAtReadableSizeOnItsStartScreen() {
        let model = FlowMapModel()
        model.update(layout(content: CGSize(width: 1000, height: 4000)))
        #expect(!model.isFitted)
        #expect(model.viewport.scale == FlowMapModel.readableScale)
        #expect(abs(model.viewport.origin.y + 2016 * 0.5 - 300) < 0.001)
    }

    @Test func zoomingAndPanningLeaveTheFittedView() {
        let model = FlowMapModel()
        model.update(layout(content: CGSize(width: 1000, height: 700)))
        model.zoomIn()
        #expect(!model.isFitted)
        model.fit()
        #expect(model.isFitted)
    }

    @Test func panningACentredMapChangesNothing() {
        let model = FlowMapModel()
        model.update(layout(content: CGSize(width: 400, height: 300)))
        let before = model.viewport
        model.pan(by: CGSize(width: 90, height: -40))
        #expect(model.viewport == before)
        #expect(model.isFitted)
    }

    @Test func aFittedMapFollowsTheViewButAZoomedOneKeepsItsScale() {
        let model = FlowMapModel()
        model.update(layout(content: CGSize(width: 1000, height: 700)))
        model.update(layout(content: CGSize(width: 1000, height: 700), view: CGSize(width: 500, height: 600)))
        #expect(model.viewport.scale == 0.5)
        model.zoomOut()
        let zoomed = model.viewport.scale
        model.update(layout(content: CGSize(width: 1000, height: 700), view: CGSize(width: 900, height: 600)))
        #expect(model.viewport.scale == zoomed)
    }

    @Test func anotherFolderOpensTheMapAfresh() {
        let model = FlowMapModel()
        model.update(layout(content: CGSize(width: 1000, height: 700)))
        model.zoomIn()
        model.update(layout(content: CGSize(width: 1000, height: 700), folder: "/b"))
        #expect(model.isFitted)
    }

    @Test func zoomLimitsDisableTheirButtons() {
        let model = FlowMapModel()
        model.update(layout(content: CGSize(width: 1000, height: 700)))
        #expect(model.canZoomIn && model.canZoomOut)
        for _ in 0..<20 { model.zoom(by: 2, around: .zero) }
        #expect(!model.canZoomIn)
        for _ in 0..<40 { model.zoom(by: 0.5, around: .zero) }
        #expect(!model.canZoomOut)
        model.detach()
        #expect(!model.canZoomIn && !model.canZoomOut)
    }

    @Test func aSmartZoomTogglesBetweenCloseUpAndTheWholeMap() {
        let model = FlowMapModel()
        model.update(layout(content: CGSize(width: 1000, height: 700)))
        model.smartZoom(at: CGPoint(x: 400, y: 300))
        #expect(model.viewport.scale == 1)
        model.smartZoom(at: CGPoint(x: 400, y: 300))
        #expect(model.isFitted)
    }
}
