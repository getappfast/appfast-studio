import CoreGraphics
import Foundation

/// A simulator's hardware frame, read from the files Xcode installs for its own Simulator window.
/// Nothing is copied into the app: Apple's artwork stays where Xcode put it, and a device without one just
/// shows its bare screen.
struct DeviceChrome: Equatable, Sendable {
    /// The frame drawn behind the screen; its middle is solid black, so the live screen goes on top.
    let compositeURL: URL
    /// The frame's size in points, screen included.
    let compositeSize: CGSize
    /// The screen's size in points.
    let screenSize: CGSize
    /// The screen's corner radius in points; 0 for Home-button devices.
    let cornerRadius: CGFloat

    /// Space between the frame's edge and the screen, in points.
    var inset: CGSize {
        CGSize(width: (compositeSize.width - screenSize.width) / 2, height: (compositeSize.height - screenSize.height) / 2)
    }

    static let deviceTypesDirectories = [
        "/Library/Developer/CoreSimulator/Profiles/DeviceTypes",
    ].map { URL(fileURLWithPath: $0) }
    static let chromeDirectory = URL(fileURLWithPath: "/Library/Developer/DeviceKit/Chrome")

    /// The frame for a device named like `simctl` names it ("iPhone 17 Pro"), or nil if Xcode has none.
    static func load(deviceName: String, deviceTypes: [URL] = deviceTypesDirectories, chromeDirectory: URL = chromeDirectory) -> DeviceChrome? {
        for directory in deviceTypes {
            let capabilities = directory.appendingPathComponent("\(deviceName).simdevicetype/Contents/Resources/capabilities.plist")
            if let data = try? Data(contentsOf: capabilities),
               let chrome = DeviceChrome(capabilities: data, chromeDirectory: chromeDirectory) {
                return chrome
            }
        }
        return nil
    }

    init?(capabilities data: Data, chromeDirectory: URL) {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let capabilities = plist["capabilities"] as? [String: Any],
              let displays = capabilities["displays"] as? [[String: Any]],
              let display = displays.first(where: { $0["displayType"] as? String == "integrated" }),
              let identifier = display["chromeIdentifier"] as? String,
              let width = (display["width"] as? NSNumber)?.doubleValue,
              let height = (display["height"] as? NSNumber)?.doubleValue,
              let scale = (display["scale"] as? NSNumber)?.doubleValue, scale > 0
        else { return nil }

        // "com.apple.dt.devicekit.chrome.phone11" lives in "phone11.devicechrome".
        guard let name = identifier.split(separator: ".").last else { return nil }
        let resources = chromeDirectory.appendingPathComponent("\(name).devicechrome/Contents/Resources")
        guard let json = try? Data(contentsOf: resources.appendingPathComponent("chrome.json")),
              let chrome = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let images = chrome["images"] as? [String: Any],
              let composite = images["composite"] as? String
        else { return nil }

        let url = resources.appendingPathComponent("\(composite).pdf")
        guard let pdf = CGPDFDocument(url as CFURL), let page = pdf.page(at: 1) else { return nil }
        let size = page.getBoxRect(.mediaBox).size
        let screen = CGSize(width: width / scale, height: height / scale)
        // A frame smaller than its screen would be a mismatched file; drawing it would clip the screen.
        guard size.width >= screen.width, size.height >= screen.height else { return nil }

        compositeURL = url
        compositeSize = size
        screenSize = screen
        cornerRadius = CGFloat((display["cornerRadiusUL"] as? NSNumber)?.doubleValue ?? 0)
    }
}
