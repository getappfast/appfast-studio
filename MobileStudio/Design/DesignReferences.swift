import AppKit

/// Pictures the user attaches to a Design chat message as reference. They're copied as PNG, so Claude's Read tool
/// can open them whatever format they came in, and the copy stays put if the original moves.
enum DesignReferences {
    /// The picture at `source` as PNG data, or nil when it isn't a picture Mobile Studio can read.
    static func png(of source: URL) -> Data? {
        guard let image = NSImage(contentsOf: source), let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    /// Copies the picture into `folder` as a new PNG and returns its location, nil when it can't be read or written.
    static func save(_ source: URL, to folder: URL) -> URL? {
        guard let data = png(of: source) else { return nil }
        let target = folder.appendingPathComponent(UUID().uuidString + ".png")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
            return target
        } catch {
            return nil
        }
    }
}
