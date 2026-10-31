import AppKit
import SwiftUI
import Testing
@testable import Mobile_Studio

/// Renders the status badge and checks its icon really comes out in the tone's colour, not just that the
/// code asks for it.
@MainActor
struct StatusRenderingTests {
    @Test(arguments: [(StatusTone.success, "green"), (.warning, "orange"), (.failure, "red")])
    func badgeIconIsDrawnInItsColour(tone: StatusTone, expected: String) throws {
        let renderer = ImageRenderer(content: StatusBadge(tone: tone, title: "Status").padding(4).environment(\.colorScheme, .light))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: image)

        var hues: [CGFloat] = []
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      color.alphaComponent > 0.8, color.saturationComponent > 0.5, color.brightnessComponent > 0.4 else { continue }
                hues.append(color.hueComponent * 360)
            }
        }
        #expect(hues.count > 20, "no strongly coloured pixels: the icon lost its tint")
        let hue = hues.sorted()[hues.count / 2]
        switch expected {
        case "green": #expect((90...170).contains(hue), "hue \(hue)")
        case "orange": #expect((20...45).contains(hue), "hue \(hue)")
        default: #expect(hue < 15 || hue > 345, "hue \(hue)")
        }
    }
}
