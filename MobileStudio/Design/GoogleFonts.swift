import Foundation

/// The Google Fonts families, from a snapshot bundled with the app (`scripts/update-google-fonts.sh`), so font names
/// are checked offline and Claude can't pick one that doesn't exist.
struct GoogleFontsCatalog: Sendable {
    struct Family: Codable, Equatable, Sendable {
        let family: String
        let category: String
        /// "400", "400i", "700", …
        let styles: [String]

        var weights: [Int] { Array(Set(styles.compactMap { Int($0.filter(\.isNumber)) })).sorted() }

        func has(weight: Int, italic: Bool = false) -> Bool { styles.contains("\(weight)\(italic ? "i" : "")") }

        /// The available weight nearest to the one asked for, preferring the heavier one on a tie.
        func nearest(to weight: Int) -> Int {
            weights.min { abs($0 - weight) == abs($1 - weight) ? $0 > $1 : abs($0 - weight) < abs($1 - weight) } ?? 400
        }
    }

    let families: [Family]
    private let byKey: [String: Family]

    init(families: [Family]) {
        self.families = families
        byKey = Dictionary(families.map { (Self.key($0.family), $0) }, uniquingKeysWith: { first, _ in first })
    }

    func family(named name: String) -> Family? { byKey[Self.key(name)] }

    private static func key(_ name: String) -> String { name.lowercased().filter { $0.isLetter || $0.isNumber } }

    static func decode(_ data: Data) -> GoogleFontsCatalog? {
        (try? JSONDecoder().decode([Family].self, from: data)).map(GoogleFontsCatalog.init)
    }

    /// The bundled snapshot.
    static let bundled: GoogleFontsCatalog? = DesignResources.url("google-fonts.json")
        .flatMap { try? Data(contentsOf: $0) }.flatMap(decode)
}

/// Font file names, the way the `google_fonts` package looks for them in a project's assets: `Inter-SemiBold.ttf`.
enum GoogleFontFile {
    static let weightNames: [Int: String] = [
        100: "Thin", 200: "ExtraLight", 300: "Light", 400: "Regular", 500: "Medium",
        600: "SemiBold", 700: "Bold", 800: "ExtraBold", 900: "Black",
    ]

    static func name(family: String, weight: Int, italic: Bool = false) -> String {
        let base = family.filter { !$0.isWhitespace }
        var style = weightNames[weight] ?? "Regular"
        if italic { style = style == "Regular" ? "Italic" : style + "Italic" }
        return "\(base)-\(style).ttf"
    }

    /// The bundled licence's file name: `Inter-LICENSE.txt`.
    static func licenceName(family: String) -> String { "\(family.filter { !$0.isWhitespace })-LICENSE.txt" }

    /// Where google/fonts keeps a family's licence: most are under ofl/, a few under apache/ or ufl/, in a folder named
    /// after the family in lower case without spaces.
    static func licenceURLs(family: String) -> [URL] {
        let folder = family.lowercased().filter { $0.isLetter || $0.isNumber }
        return [("ofl", "OFL.txt"), ("apache", "LICENSE.txt"), ("ufl", "UFL.txt")].compactMap { kind, file in
            URL(string: "https://raw.githubusercontent.com/google/fonts/main/\(kind)/\(folder)/\(file)")
        }
    }

    /// The query for Google Fonts' CSS API, asking for each weight.
    static func cssURL(family: String, weights: [Int]) -> URL? {
        var components = URLComponents(string: "https://fonts.googleapis.com/css2")
        let list = Array(Set(weights)).sorted().map(String.init).joined(separator: ";")
        components?.queryItems = [URLQueryItem(name: "family", value: "\(family):wght@\(list)")]
        return components?.url
    }

    struct Face: Equatable, Sendable {
        let weight: Int
        let italic: Bool
        let url: URL
    }

    enum CSSError: Error, Equatable {
        /// The API sent something other than whole TTF files, such as WOFF2 split by script.
        case wrongFormat(String)
        case noFaces
    }

    /// The font files a CSS API answer points at, one per weight. Asked without a browser's user agent, the API sends
    /// one TTF per weight; a browser's gets WOFF or WOFF2 split into scripts, which Flutter can't use.
    static func faces(inCSS css: String) -> Result<[Face], CSSError> {
        var faces: [Face] = []
        for block in css.components(separatedBy: "@font-face").dropFirst() {
            guard let url = block.firstMatch(of: /url\(([^)]+)\)/).map({ String($0.1) }).flatMap(URL.init(string:)) else { continue }
            guard url.pathExtension.lowercased() == "ttf" else { return .failure(.wrongFormat(url.pathExtension)) }
            let weight = block.firstMatch(of: /font-weight:\s*(\d+)/).flatMap { Int($0.1) } ?? 400
            let italic = block.contains("font-style: italic")
            if !faces.contains(where: { $0.weight == weight && $0.italic == italic }) {
                faces.append(Face(weight: weight, italic: italic, url: url))
            }
        }
        return faces.isEmpty ? .failure(.noFaces) : .success(faces)
    }
}

/// Downloads Google Fonts files once and keeps them in Application Support, so the mockups and the app's assets can
/// be filled from there without asking again.
struct GoogleFontsService: Sendable {
    static let log = DiagnosticLog(name: "design")

    var cache: URL = ProjectStorage.root.appendingPathComponent("Fonts")

    /// The cached files for a family, downloading what's missing. Throws a message the user can read.
    func files(family: String, weights: [Int]) async throws -> [(weight: Int, url: URL)] {
        let folder = cache.appendingPathComponent(family.filter { !$0.isWhitespace })
        let wanted = Array(Set(weights)).sorted()
        let cached = wanted.map { (weight: $0, url: folder.appendingPathComponent(GoogleFontFile.name(family: family, weight: $0))) }
        if cached.allSatisfy({ FileManager.default.fileExists(atPath: $0.url.path) }) { return cached }

        guard let cssURL = GoogleFontFile.cssURL(family: family, weights: wanted) else { throw failure(family) }
        var request = URLRequest(url: cssURL, timeoutInterval: 20)
        // No browser user agent: that is what makes the API answer with TTF files (see `GoogleFontFile.faces`).
        request.setValue("MobileStudio", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let css = String(decoding: data, as: UTF8.self)
        Self.log.append("FONTS \(cssURL.absoluteString) → \(status)")
        guard status == 200 else { throw failure(family) }
        let faces: [GoogleFontFile.Face]
        switch GoogleFontFile.faces(inCSS: css) {
        case .success(let found): faces = found
        case .failure(let error):
            Self.log.append("FONTS \(family): \(error)\n\(css.prefix(400))")
            throw failure(family)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var saved: [(weight: Int, url: URL)] = []
        for face in faces where !face.italic {
            let target = folder.appendingPathComponent(GoogleFontFile.name(family: family, weight: face.weight))
            if !FileManager.default.fileExists(atPath: target.path) {
                let (font, fontResponse) = try await URLSession.shared.data(from: face.url)
                guard (fontResponse as? HTTPURLResponse)?.statusCode == 200, font.count > 1000 else { throw failure(family) }
                try font.write(to: target, options: .atomic)
            }
            saved.append((face.weight, target))
        }
        Self.log.append("FONTS \(family): \(saved.map { $0.url.lastPathComponent }.joined(separator: ", "))")
        return saved
    }

    /// The family's licence text from the google/fonts repository, cached next to its files. Nil when it can't be
    /// found: the font still works, its licence just isn't bundled.
    func licence(family: String) async -> URL? {
        let folder = cache.appendingPathComponent(family.filter { !$0.isWhitespace })
        let target = folder.appendingPathComponent(GoogleFontFile.licenceName(family: family))
        if FileManager.default.fileExists(atPath: target.path) { return target }
        for url in GoogleFontFile.licenceURLs(family: family) {
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200, data.count > 200 else { continue }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard (try? data.write(to: target, options: .atomic)) != nil else { return nil }
            Self.log.append("FONTS licence for \(family): \(url.absoluteString)")
            return target
        }
        Self.log.append("FONTS no licence found for \(family)")
        return nil
    }

    private func failure(_ family: String) -> NSError {
        NSError(domain: "MobileStudio.Fonts", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Couldn't download \(family). Showing the system font."])
    }
}

/// Files bundled with the app for the design step: the kit, the icon font, the font catalog, the styles.
enum DesignResources {
    static var folder: URL? { Bundle.main.url(forResource: "Design", withExtension: nil) }

    static func url(_ name: String) -> URL? {
        folder.map { $0.appendingPathComponent(name) }.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    static func text(_ name: String) -> String? { url(name).flatMap { try? String(contentsOf: $0, encoding: .utf8) } }
}
