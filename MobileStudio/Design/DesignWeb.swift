import AppKit
import WebKit

/// What an `ms-design://` address asks for. Pure, so what the mockups can reach is testable: files inside the
/// project's `design/`, the app's kit files, a style's sample, or downloaded fonts. Nothing else, and no `..`.
enum DesignURL: Equatable {
    case project(String)
    case kit(String)
    case style(id: String, file: String)
    case font(String)

    static let scheme = "ms-design"

    static func resolve(_ url: URL) -> DesignURL? {
        guard url.scheme == scheme, let host = url.host() else { return nil }
        let parts = url.path(percentEncoded: false).split(separator: "/").map(String.init)
        guard !parts.isEmpty, !parts.contains(where: { $0 == ".." || $0 == "." || $0.hasPrefix("~") }) else { return nil }
        let path = parts.joined(separator: "/")
        switch host {
        case "project": return .project(path)
        case "kit" where parts.count == 1: return .kit(path)
        case "style" where parts.count == 2: return .style(id: parts[0], file: parts[1])
        case "fonts" where parts.count == 2: return .font(path)
        default: return nil
        }
    }

    static func projectURL(_ relativeToDesign: String) -> URL { URL(string: "\(scheme)://project/\(relativeToDesign)")! }

    static func styleURL(_ id: String) -> URL { URL(string: "\(scheme)://style/\(id)/sample.html")! }

    static func mimeType(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html": "text/html"
        case "css": "text/css"
        case "png": "image/png"
        case "otf": "font/otf"
        case "ttf": "font/ttf"
        case "json": "application/json"
        default: "application/octet-stream"
        }
    }
}

/// Serves `ms-design://` to the mockups' web views (see `DesignURL`). It swaps icon names for the font's characters
/// as it serves HTML, and can stand in other tokens for `tokens.css`, which is how the look step tries a colour theme
/// or font pairing without writing anything.
@MainActor
final class DesignSchemeHandler: NSObject, WKURLSchemeHandler {
    /// The project folder.
    var folder: String?
    /// CSS served instead of the project's tokens.css.
    var tokensOverride: String?

    private var stopped = Set<ObjectIdentifier>()

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let target = DesignURL.resolve(url), let data = data(for: target) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let path = url.path(percentEncoded: false)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": DesignURL.mimeType(for: path), "Cache-Control": "no-store"])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    private func data(for target: DesignURL) -> Data? {
        switch target {
        case .project(let path):
            if path == "tokens.css", let tokensOverride { return Data(tokensOverride.utf8) }
            guard let folder else { return nil }
            let file = URL(fileURLWithPath: folder).appendingPathComponent(DesignPaths.folder).appendingPathComponent(path)
            guard let data = try? Data(contentsOf: file) else { return nil }
            return path.hasSuffix(".html") ? html(data) : data
        case .kit(let file):
            return Self.kitData(file)
        case .style(let id, let file):
            switch file {
            case "sample.html": return html(Data(DesignStyle.sampleHTML.utf8))
            case "kit.css": return Self.kitData("kit.css")
            case "tokens.css":
                if let tokensOverride { return Data(tokensOverride.utf8) }
                return DesignStyle.named(id).map { Data(TokensCSS.css($0.tokens, fonts: Self.cachedFonts(for: $0.tokens)).utf8) }
            default: return nil
            }
        case .font(let path):
            return try? Data(contentsOf: GoogleFontsService().cache.appendingPathComponent(path))
        }
    }

    /// The kit's files never change while the app runs, and the icon font is 1.6 MB: read each once.
    private static var kitCache: [String: Data] = [:]

    private static func kitData(_ file: String) -> Data? {
        if let cached = kitCache[file] { return cached }
        guard let data = DesignResources.url(file).flatMap({ try? Data(contentsOf: $0) }) else { return nil }
        kitCache[file] = data
        return data
    }

    private func html(_ data: Data) -> Data {
        guard let icons = IconCatalog.bundled else { return data }
        return Data(IconSubstitution.apply(String(decoding: data, as: UTF8.self), icons: icons).utf8)
    }

    /// Fonts already downloaded for a style's sample, served from the cache rather than a project.
    static func cachedFonts(for tokens: DesignTokens) -> [TokensCSS.FontFile] {
        let cache = GoogleFontsService().cache
        return tokens.neededWeights.sorted { $0.key < $1.key }.flatMap { family, weights in
            weights.sorted().compactMap { weight -> TokensCSS.FontFile? in
                let folder = family.filter { !$0.isWhitespace }
                let name = GoogleFontFile.name(family: family, weight: weight)
                guard FileManager.default.fileExists(atPath: cache.appendingPathComponent("\(folder)/\(name)").path) else { return nil }
                return TokensCSS.FontFile(family: family, weight: weight, italic: false, path: "ms-design://fonts/\(folder)/\(name)")
            }
        }
    }
}

/// A web view set up for mockups: no JavaScript from the page, `ms-design://` only, no scrolling, no menus.
@MainActor
enum DesignWebView {
    /// One store for every mockup: a store per web view starts its own web process, which is what made many artboards slow.
    private static let sharedStore = WKWebsiteDataStore.nonPersistent()

    static func make(handler: DesignSchemeHandler) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(handler, forURLScheme: DesignURL.scheme)
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = sharedStore
        configuration.suppressesIncrementalRendering = true
        let view = MockupWebView(frame: CGRect(x: 0, y: 0, width: DesignCanvasSize.width, height: DesignCanvasSize.height),
                                 configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.allowsMagnification = false
        view.allowsBackForwardNavigationGestures = false
        return view
    }
}

/// The phone screen every mockup is drawn at, in points.
enum DesignCanvasSize {
    static let width: CGFloat = 393
    static let height: CGFloat = 852
    /// The phone's screen corner at a scale; the host, the clip and the frame around it all use this, so they stay concentric.
    static func cornerRadius(scale: Double) -> CGFloat { 44 * scale }
}

/// Lets clicks and scrolls pass to the SwiftUI canvas around it: a mockup is a picture, not a page to use.
final class MockupWebView: WKWebView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) { menu.removeAllItems() }
}

/// Makes PNGs of mockups off screen, one at a time: for App Flow's cards, the version strip and the build turn.
@MainActor
final class DesignRenderer: NSObject, WKNavigationDelegate {
    private let handler = DesignSchemeHandler()
    private lazy var webView: WKWebView = {
        let view = DesignWebView.make(handler: handler)
        view.navigationDelegate = self
        return view
    }()
    /// Off screen but on a window, because a web view outside one doesn't draw.
    private lazy var window: NSWindow = {
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: DesignCanvasSize.width, height: DesignCanvasSize.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.contentView = webView
        window.orderBack(nil)
        return window
    }()
    private var loaded: CheckedContinuation<Void, Never>?
    private var queue: Task<Void, Never>?

    /// Draws the page at `url` and saves it as a PNG. Returns whether it worked.
    @discardableResult
    func render(_ url: URL, folder: String?, tokensOverride: String? = nil, dark: Bool, to target: URL) async -> Bool {
        let previous = queue
        let task = Task { [weak self] () -> Bool in
            await previous?.value
            return await self?.draw(url, folder: folder, tokensOverride: tokensOverride, dark: dark, to: target) ?? false
        }
        queue = Task { _ = await task.value }
        return await task.value
    }

    private func draw(_ url: URL, folder: String?, tokensOverride: String?, dark: Bool, to target: URL) async -> Bool {
        _ = window
        handler.folder = folder
        handler.tokensOverride = tokensOverride
        webView.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        await withCheckedContinuation { continuation in
            loaded = continuation
            webView.load(URLRequest(url: url))
        }
        // Fonts and layout settle just after the load finishes.
        try? await Task.sleep(for: .milliseconds(250))
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: 0, y: 0, width: DesignCanvasSize.width, height: DesignCanvasSize.height)
        configuration.snapshotWidth = NSNumber(value: Double(DesignCanvasSize.width))
        guard let image = try? await webView.takeSnapshot(configuration: configuration),
              let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            return false
        }
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? png.write(to: target, options: .atomic)) != nil
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { finishLoad() }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        MainActor.assumeIsolated { finishLoad() }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        MainActor.assumeIsolated { finishLoad() }
    }

    private func finishLoad() {
        loaded?.resume()
        loaded = nil
    }
}
