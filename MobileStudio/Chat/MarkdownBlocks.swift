import Foundation

/// The block structure of Claude's markdown: SwiftUI's `Text` only renders inline markdown, so headings,
/// lists and fenced code are split out here and each block is drawn on its own.
enum MarkdownBlock: Equatable, Sendable {
    case paragraph(String)
    case heading(level: Int, text: String)
    /// `ordinal` is "1." for a numbered item, nil for a bullet.
    case listItem(ordinal: String?, text: String)
    case code(language: String?, text: String)

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String]?
        var language: String?

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }

        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(language: language, text: lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flushParagraph()
                    let tag = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    language = tag.isEmpty ? nil : tag
                    code = []
                }
                continue
            }
            if code != nil { code?.append(raw); continue }

            if line.isEmpty {
                flushParagraph()
            } else if let heading = line.firstMatch(of: /^(#{1,6})\s+(.+)$/) {
                flushParagraph()
                blocks.append(.heading(level: heading.1.count, text: String(heading.2)))
            } else if let bullet = line.firstMatch(of: /^[-*+]\s+(.+)$/) {
                flushParagraph()
                blocks.append(.listItem(ordinal: nil, text: String(bullet.1)))
            } else if let numbered = line.firstMatch(of: /^(\d+[.)])\s+(.+)$/) {
                flushParagraph()
                blocks.append(.listItem(ordinal: String(numbered.1), text: String(numbered.2)))
            } else {
                paragraph.append(line)
            }
        }
        // An unclosed fence still shows its code, e.g. while Claude is mid-answer.
        if let lines = code { blocks.append(.code(language: language, text: lines.joined(separator: "\n"))) }
        flushParagraph()
        return blocks
    }
}

/// Claude is asked to put what changed first, then technical notes after a line of `---`. The outcome is
/// shown; the notes go behind a disclosure.
enum AnswerParts {
    static func split(_ text: String) -> (outcome: String, details: String?) {
        let lines = text.components(separatedBy: "\n")
        guard let rule = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }), rule > 0 else {
            return (text, nil)
        }
        let outcome = lines[..<rule].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let details = lines[(rule + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (outcome.isEmpty ? text : outcome, details.isEmpty ? nil : details)
    }
}

/// Kinds of step `ClaudeEvents` reports, for the chat's step list.
enum ClaudeStep {
    case reading, editing, searching, running, allowed, declined, note

    init(_ activity: String) {
        if activity.hasPrefix("Reading") { self = .reading }
        else if activity.hasPrefix("Editing") { self = .editing }
        else if activity.hasPrefix("Searching") { self = .searching }
        else if activity.hasPrefix("Running") { self = .running }
        else if activity.hasPrefix("Allowed") { self = .allowed }
        else if activity.hasPrefix("Declined") { self = .declined }
        else { self = .note }
    }

    var symbol: String {
        switch self {
        case .reading: "doc.text"
        case .editing: "pencil"
        case .searching: "magnifyingglass"
        case .running: "terminal"
        case .allowed: "checkmark.shield"
        case .declined: "hand.raised"
        case .note: "info.circle"
        }
    }
}
