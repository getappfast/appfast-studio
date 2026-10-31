import Foundation

/// Reads the lines of `claude --output-format stream-json`.
enum ClaudeEvents {
    enum Item: Equatable, Sendable {
        /// Something Claude said.
        case text(String)
        /// Something Claude did: "Reading lib/main.dart", "Editing …", "Running …".
        case activity(String)
    }

    struct Result: Equatable, Sendable {
        let isError: Bool
        let subtype: String?
        let text: String
        let errors: String
        let cost: Double?
        /// The `--json-schema` answer, re-encoded so it can be decoded into a typed report.
        let structuredOutput: Data?

        func structured<Value: Decodable>(as type: Value.Type) -> Value? {
            structuredOutput.flatMap { try? JSONDecoder().decode(type, from: $0) }
        }
    }

    static func json(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// What one stream line adds to the transcript, in the order Claude produced it.
    static func items(in line: String, folder: String) -> [Item] {
        guard let object = json(line), object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any], let content = message["content"] as? [[String: Any]] else { return [] }
        func relative(_ path: String?) -> String {
            guard let path else { return "a file" }
            return path.hasPrefix(folder + "/") ? String(path.dropFirst(folder.count + 1)) : path
        }
        var items: [Item] = []
        for item in content {
            let input = item["input"] as? [String: Any] ?? [:]
            switch item["type"] as? String {
            case "text":
                if let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    items.append(.text(text))
                }
            case "tool_use":
                switch item["name"] as? String {
                case "Read": items.append(.activity("Reading \(relative(input["file_path"] as? String))"))
                case "Edit", "Write": items.append(.activity("Editing \(relative(input["file_path"] as? String))"))
                case "Glob", "Grep": items.append(.activity("Searching for \(input["pattern"] as? String ?? "files")"))
                case "Bash": items.append(.activity("Running \((input["command"] as? String ?? "a command").prefix(100))"))
                default: break
                }
            default: break
            }
        }
        return items
    }

    /// The closing `result` event, found from the end of the stream.
    static func result(in lines: [String]) -> Result? {
        for line in lines.reversed() {
            guard let object = json(line), object["type"] as? String == "result" else { continue }
            let structured = object["structured_output"].flatMap { value in
                JSONSerialization.isValidJSONObject(value) ? try? JSONSerialization.data(withJSONObject: value) : nil
            }
            return Result(
                isError: object["is_error"] as? Bool ?? false,
                subtype: object["subtype"] as? String,
                text: object["result"] as? String ?? "",
                errors: (object["errors"] as? [String])?.joined(separator: " ") ?? "",
                cost: object["total_cost_usd"] as? Double,
                structuredOutput: structured
            )
        }
        return nil
    }
}
