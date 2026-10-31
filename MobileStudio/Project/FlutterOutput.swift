import Foundation

/// The text `flutter run` / `flutter attach` prints, turned into lines and the few facts the app reads from
/// them. Pure, so it can be tested without running Flutter.
struct FlutterOutput: Equatable, Sendable {
    /// Finished lines, newest last, capped at `maxLines`.
    private(set) var lines: [String] = []
    /// The line still being written, e.g. a build progress line Flutter keeps rewriting with \r.
    private(set) var partial = ""
    /// The VM service address, which Hot reload's inspector and Pick connect to. Set once it is printed.
    private(set) var serviceURL: URL?
    /// Flutter printed its key help: the app is built, launched and attached.
    private(set) var isLaunched = false

    var maxLines = 400

    /// The last few lines, including the one being written.
    func tail(_ count: Int) -> [String] {
        Array((partial.isEmpty ? lines : lines + [partial]).suffix(count))
    }

    mutating func append(_ chunk: String) {
        var text = partial + Self.stripANSI(chunk).replacingOccurrences(of: "\r\n", with: "\n")
        var segments = text.components(separatedBy: "\n")
        text = segments.removeLast()
        for segment in segments {
            let line = Self.lastCarriageReturnSegment(segment)
            guard !line.isEmpty else { continue }
            lines.append(line)
            if serviceURL == nil { serviceURL = Self.serviceURL(in: line) }
            if !isLaunched { isLaunched = Self.launchMarkers.contains { line.contains($0) } }
        }
        partial = Self.lastCarriageReturnSegment(text)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
    }

    /// Ends the output: the line being written counts as finished.
    mutating func close() {
        if !partial.isEmpty { lines.append(partial); partial = "" }
    }

    /// The most useful single line to show for a run that exited with `status`.
    func failureReason(status: Int32) -> String {
        // The generic "Error launching application" closes the output; the cause is just under the build failure.
        if let index = lines.firstIndex(where: { $0.hasPrefix("Failed to build") }),
           let cause = lines[(index + 1)...].first(where: { !$0.isEmpty }) {
            return "\(lines[index]): \(cause)"
        }
        let markers = ["error", "exception", "could not", "not found", "no devices", "failed", "unable"]
        if let hit = lines.last(where: { line in markers.contains { line.lowercased().contains($0) } }) { return hit }
        return lines.last ?? "flutter run exited with status \(status)."
    }

    // MARK: Parsing

    private static let launchMarkers = ["Flutter run key commands", "Syncing files to device"]

    static func serviceURL(in line: String) -> URL? {
        guard line.contains("Dart VM Service"),
              let match = line.firstMatch(of: /http:\/\/127\.0\.0\.1:\d+\/[^\s]*/) else { return nil }
        return URL(string: String(match.0))
    }

    /// Flutter rewrites progress lines with \r; keep what ended up on screen.
    static func lastCarriageReturnSegment(_ text: String) -> String {
        let parts = text.components(separatedBy: "\r").map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.last { !$0.isEmpty } ?? ""
    }

    static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
    }
}
