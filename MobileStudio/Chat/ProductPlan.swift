import Foundation

/// The written product plan the kickoff chat ends in. Claude fills it in through `--json-schema`, and the app
/// writes PLAN.md from it, so the file always has the shape later turns expect.
struct ProductPlan: Codable, Equatable, Sendable {
    struct Decision: Codable, Equatable, Sendable {
        let title: String
        let choice: String
        let why: String
        let alternatives: [String]
    }

    struct Feature: Codable, Equatable, Sendable {
        let title: String
        let detail: String
        let screens: [String]
    }

    struct PlannedScreen: Codable, Equatable, Sendable {
        let name: String
        let purpose: String
        let leadsTo: [String]
    }

    struct Milestone: Codable, Equatable, Sendable {
        let title: String
        let features: [String]
        let doneWhen: String
    }

    let summary: String
    let audience: String
    let decisions: [Decision]
    let mustHave: [Feature]
    let canHave: [Feature]
    let notNow: [String]
    let screens: [PlannedScreen]
    let openQuestions: [String]
    let milestones: [Milestone]

    static let fileName = "PLAN.md"

    // The labels of the choice cards in the kickoff chat. The prompt and `Workspace.choose` both depend on them.
    static let writeLabel = "Write the plan"
    static let moreQuestionsLabel = "A few more questions"
    static let buildLabel = "Build milestone 1"
    static let changeLabel = "Change the plan"
    static let notNowLabel = "Not now"

    /// What the chat offers once the plan is written.
    static var nextSteps: ChoiceSet {
        ChoiceSet(question: "What next?", multiple: false, options: [
            .init(label: buildLabel, detail: "Claude builds the first milestone, and you watch it appear.", recommended: true),
            .init(label: changeLabel, detail: "Say what to adjust, then write the plan again."),
            .init(label: notNowLabel, detail: "Keep PLAN.md and come back later."),
        ])
    }

    /// The JSON Schema `--json-schema` takes. Every field is required so the plan is never half filled.
    static let schema: String = {
        func strings(_ description: String) -> [String: Any] { ["type": "array", "items": ["type": "string"], "description": description] }
        func object(_ properties: [String: Any]) -> [String: Any] {
            ["type": "object", "properties": properties, "required": properties.keys.sorted(), "additionalProperties": false]
        }
        let feature = object(["title": ["type": "string"], "detail": ["type": "string"], "screens": strings("Names of the screens it appears on")])
        let root = object([
            "summary": ["type": "string", "description": "Two sentences on what the app is"],
            "audience": ["type": "string"],
            "decisions": ["type": "array", "items": object([
                "title": ["type": "string"], "choice": ["type": "string"], "why": ["type": "string"], "alternatives": strings("Options not chosen"),
            ])],
            "mustHave": ["type": "array", "items": feature],
            "canHave": ["type": "array", "items": feature],
            "notNow": strings("Explicitly out of scope"),
            "screens": ["type": "array", "items": object([
                "name": ["type": "string"], "purpose": ["type": "string"], "leadsTo": strings("Names of screens it leads to"),
            ])],
            "openQuestions": strings("Things still undecided"),
            "milestones": ["type": "array", "items": object([
                "title": ["type": "string"], "features": strings("Titles of must-have features built in this milestone"),
                "doneWhen": ["type": "string", "description": "What the user can see or do when it is done"],
            ])],
        ])
        let data = (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }()
}

// In an extension so the memberwise initializer stays.
extension ProductPlan {
    /// A missing field reads as empty, so a plan saved in an older or looser shape still loads with its chat.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        audience = try c.decodeIfPresent(String.self, forKey: .audience) ?? ""
        decisions = try c.decodeIfPresent([Decision].self, forKey: .decisions) ?? []
        mustHave = try c.decodeIfPresent([Feature].self, forKey: .mustHave) ?? []
        canHave = try c.decodeIfPresent([Feature].self, forKey: .canHave) ?? []
        notNow = try c.decodeIfPresent([String].self, forKey: .notNow) ?? []
        screens = try c.decodeIfPresent([PlannedScreen].self, forKey: .screens) ?? []
        openQuestions = try c.decodeIfPresent([String].self, forKey: .openQuestions) ?? []
        milestones = try c.decodeIfPresent([Milestone].self, forKey: .milestones) ?? []
    }
}

/// Which of a plan's milestones are built. Pure, so the sidebar and its rules are testable.
struct MilestoneProgress: Equatable, Sendable {
    enum State: Equatable, Sendable { case done, next, later }

    let plan: ProductPlan
    var done: Set<Int>

    /// The first milestone not built yet; nil when all are.
    var next: Int? { plan.milestones.indices.first { !done.contains($0) } }

    func state(of index: Int) -> State {
        if done.contains(index) { return .done }
        return index == next ? .next : .later
    }

    var isComplete: Bool { !plan.milestones.isEmpty && next == nil }

    /// "2 of 5 built", for the section header.
    var summary: String { "\(done.filter { plan.milestones.indices.contains($0) }.count) of \(plan.milestones.count) built" }
}

/// The plan as JSON next to the project's record, so the tracker survives a new chat. PLAN.md is for reading.
enum ProductPlanStore {
    static func url(forFolder folder: String) -> URL {
        ProjectStorage.directory("NewProject", for: folder).appendingPathComponent("plan.json")
    }

    static func load(forFolder folder: String) -> ProductPlan? {
        guard let data = try? Data(contentsOf: url(forFolder: folder)) else { return nil }
        return try? JSONDecoder().decode(ProductPlan.self, from: data)
    }

    static func save(_ plan: ProductPlan, forFolder folder: String) {
        let url = url(forFolder: folder)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(plan) { try? data.write(to: url, options: .atomic) }
    }

    static func delete(forFolder folder: String) {
        try? FileManager.default.removeItem(at: url(forFolder: folder))
    }
}

/// Turns a `ProductPlan` into PLAN.md. Sections with nothing in them are left out.
enum PlanRenderer {
    static func markdown(_ plan: ProductPlan, appName: String) -> String {
        var out = ["# \(line(appName)): product plan", "", line(plan.summary)]
        if !plan.audience.isEmpty { out += ["", "**For:** \(line(plan.audience))"] }

        section("Design decisions", plan.decisions.map { decision in
            var text = "- **\(line(decision.title)):** \(sentence(decision.choice)) \(sentence(decision.why))"
            if !decision.alternatives.isEmpty { text += " _Not chosen: \(decision.alternatives.map(line).joined(separator: "; "))._" }
            return text
        }, into: &out)
        section("Must have", plan.mustHave.map(feature), into: &out)
        section("Can have", plan.canHave.map(feature), into: &out)
        section("Not now", plan.notNow.map { "- \(line($0))" }, into: &out)
        section("Screens", plan.screens.map { screen in
            let leads = screen.leadsTo.isEmpty ? "" : " Leads to: \(screen.leadsTo.map(line).joined(separator: ", "))."
            return "- **\(line(screen.name)):** \(line(screen.purpose))\(leads)"
        }, into: &out)
        section("Open questions", plan.openQuestions.map { "- \(line($0))" }, into: &out)
        if !plan.milestones.isEmpty {
            out += ["", "## Build order"]
            for (index, milestone) in plan.milestones.enumerated() {
                out += ["", "### \(index + 1). \(line(milestone.title))"]
                if !milestone.features.isEmpty { out += [""] + milestone.features.map { "- \(line($0))" } }
                if !milestone.doneWhen.isEmpty { out += ["", "**Done when:** \(line(milestone.doneWhen))"] }
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// Writes PLAN.md at the project root.
    static func write(_ plan: ProductPlan, appName: String, to folder: String) throws {
        try markdown(plan, appName: appName)
            .write(to: URL(fileURLWithPath: folder).appendingPathComponent(ProductPlan.fileName), atomically: true, encoding: .utf8)
    }

    private static func feature(_ feature: ProductPlan.Feature) -> String {
        var text = "- **\(line(feature.title))**"
        if !feature.detail.isEmpty { text += ": \(line(feature.detail))" }
        if !feature.screens.isEmpty { text += " _(\(feature.screens.map(line).joined(separator: ", ")))_" }
        return text
    }

    private static func section(_ title: String, _ lines: [String], into out: inout [String]) {
        guard !lines.isEmpty else { return }
        out += ["", "## \(title)", ""] + lines
    }

    /// `line`, ending in a full stop so two can follow each other.
    private static func sentence(_ text: String) -> String {
        let escaped = line(text)
        return escaped.last.map { ".!?".contains($0) } == true ? escaped : escaped + "."
    }

    /// One line of text with Markdown's special characters escaped, so a title like `a *b* [c]` stays as typed.
    /// Underscores inside words (`water_tracker`) and `#` mid-line are left alone, so the file reads well raw.
    static func line(_ text: String) -> String {
        let characters = Array(text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces))
        var result = ""
        for (index, character) in characters.enumerated() {
            let inWord = { (offset: Int) -> Bool in characters.indices.contains(index + offset) && characters[index + offset].isLetterOrNumber }
            let escape = switch character {
            case "\\", "`", "*", "[", "]", "<", ">": true
            case "_": !(inWord(-1) && inWord(1))
            default: false
            }
            if escape { result.append("\\") }
            result.append(character)
        }
        return escapingBlockMarker(result)
    }

    /// A line that starts like a heading, list item, quote or rule would change meaning, so its first character is escaped.
    private static func escapingBlockMarker(_ text: String) -> String {
        guard let first = text.first else { return text }
        let startsList = text.firstMatch(of: /^\d+[.)]\s/) != nil
        let startsRule = text.firstMatch(of: /^(-{3,}|={3,}|_{3,})\s*$/) != nil
        if "#-+".contains(first) && (first == "#" || text.dropFirst().first == " " || startsRule) || startsList || startsRule {
            return "\\" + text
        }
        return text
    }
}

private extension Character {
    var isLetterOrNumber: Bool { isLetter || isNumber }
}
