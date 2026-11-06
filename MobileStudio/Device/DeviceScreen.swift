import AppKit
import IOSurface

/// Touch phases are the Objective-C bridge's, which every backend reuses.
typealias TouchPhase = MSTouchPhase

/// A live device screen. Frames arrive as `IOSurface`s so the canvas, the Point at… thumbnail and `ms-sim screenshot`
/// work the same for every backend.
protocol DeviceScreen: AnyObject, Sendable {
    var frameHandler: ((IOSurface) -> Void)? { get set }
    var latestFrame: IOSurface? { get }
    var pixelSize: CGSize { get }
    var framesDelivered: UInt64 { get }
    var inputAvailable: Bool { get }

    /// `point` is normalized: (0,0) top-left, (1,1) bottom-right.
    func sendTouch(_ phase: TouchPhase, at point: CGPoint)
    func sendKeyEvent(_ event: NSEvent)
    func pressKey(_ usage: Int32, shift: Bool)
    func press(_ button: DeviceButton)
    func stop()
}

extension MSSimulatorDisplay: DeviceScreen {
    func press(_ button: DeviceButton) {
        // iOS has no Back button.
        if button == .home { pressHome() }
    }
}
