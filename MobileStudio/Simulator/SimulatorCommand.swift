import Foundation

/// One thing the in-app agent can ask the simulator to do through `ms-sim`. Coordinates are pixels in the
/// last screenshot, so what Claude points at on the picture is what gets touched.
enum SimulatorCommand: Equatable, Sendable {
    case screenshot
    case tap(x: Double, y: Double)
    case swipe(fromX: Double, fromY: Double, toX: Double, toY: Double)
    case home
    case type(String)
    case key(String)
    case hold(x: Double, y: Double)
    case paste(String)

    /// Reads a request such as `/tap?x=120&y=300`. Nil when it isn't a known command or a number is missing.
    init?(path: String) {
        guard let components = URLComponents(string: path) else { return nil }
        func number(_ name: String) -> Double? {
            components.queryItems?.first { $0.name == name }?.value.flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil }
        }
        func text(_ name: String) -> String? { components.queryItems?.first { $0.name == name }?.value }
        switch components.path {
        case "/type": guard let value = text("text"), !value.isEmpty else { return nil }; self = .type(value)
        case "/hold":
            guard let x = number("x"), let y = number("y") else { return nil }
            self = .hold(x: x, y: y)
        case "/paste": guard let value = text("text"), !value.isEmpty else { return nil }; self = .paste(value)
        case "/key": guard let value = text("name"), KeyboardMap.named(value) != nil else { return nil }; self = .key(value)
        case "/screenshot": self = .screenshot
        case "/home": self = .home
        case "/tap":
            guard let x = number("x"), let y = number("y") else { return nil }
            self = .tap(x: x, y: y)
        case "/swipe":
            guard let x1 = number("x1"), let y1 = number("y1"), let x2 = number("x2"), let y2 = number("y2") else { return nil }
            self = .swipe(fromX: x1, fromY: y1, toX: x2, toY: y2)
        default: return nil
        }
    }

    /// A point in screenshot pixels as the simulator's 0...1 screen space, clamped to the screen.
    static func normalized(x: Double, y: Double, in size: CGSize) -> CGPoint? {
        guard size.width > 0, size.height > 0 else { return nil }
        return CGPoint(x: min(max(x / size.width, 0), 1), y: min(max(y / size.height, 0), 1))
    }

    /// What the chat shows while the agent does it.
    static func activity(forShell command: String) -> String? {
        let words = command.split(separator: " ").map(String.init)
        guard words.first == "ms-sim" else { return nil }
        switch words.dropFirst().first {
        case "screenshot": return "Looking at the app"
        case "tap": return "Tapping the app"
        case "swipe": return "Swiping in the app"
        case "home": return "Pressing Home"
        case "type": return "Typing in the app"
        case "key": return "Pressing a key"
        case "hold": return "Pressing and holding in the app"
        case "paste": return "Preparing text to paste"
        default: return nil
        }
    }
}
