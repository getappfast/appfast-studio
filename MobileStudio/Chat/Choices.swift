import Foundation

/// Options Claude offers at the end of an answer ("what should I do next?"), shown as a card the user picks
/// from instead of a list to answer in prose. Claude writes them as a fenced ```choices block of JSON; the
/// system prompt in `ChatModel` asks for it.
struct ChoiceSet: Codable, Equatable, Sendable {
    struct Option: Codable, Equatable, Hashable, Sendable {
        let label: String
        var detail: String?
        var recommended: Bool?
    }

    var question: String?
    /// More than one option can be picked.
    var multiple: Bool?
    let options: [Option]

    var allowsMultiple: Bool { multiple ?? false }

    /// The answer's text without its choices block, and the choices. A block that is still being written (no
    /// closing fence yet) is left out of the text, so half-written JSON never shows.
    static func extract(from text: String) -> (text: String, choices: ChoiceSet?) {
        guard let open = text.range(of: "```choices", options: .backwards) else { return (text, nil) }
        let before = String(text[..<open.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let rest = text[open.upperBound...]
        guard let close = rest.range(of: "```") else { return (before, nil) }
        let after = String(rest[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        let remaining = [before, after].filter { !$0.isEmpty }.joined(separator: "\n\n")
        guard let data = String(rest[..<close.lowerBound]).data(using: .utf8),
              let choices = try? JSONDecoder().decode(ChoiceSet.self, from: data),
              !choices.options.isEmpty else { return (remaining, nil) }
        return (remaining, choices)
    }

    /// The message sent back when the user picks.
    static func reply(choosing labels: [String]) -> String {
        guard labels.count > 1 else { return labels.first.map { "Go ahead: \($0)." } ?? "" }
        return "Go ahead with these, in this order:\n" + labels.map { "- \($0)" }.joined(separator: "\n")
    }
}
