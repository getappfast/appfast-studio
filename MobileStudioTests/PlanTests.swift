import Foundation
import Testing
@testable import Mobile_Studio

struct ProductPlanTests {
    static let plan = ProductPlan(
        summary: "Tracks water. Reminds you to drink.", audience: "People who forget to drink",
        decisions: [.init(title: "Storage", choice: "On the phone", why: "No accounts needed", alternatives: ["Cloud sync", "Files"])],
        mustHave: [.init(title: "Log a glass", detail: "One tap adds 250 ml", screens: ["Home"])],
        canHave: [], notNow: ["Sharing"],
        screens: [.init(name: "Home", purpose: "Today's total", leadsTo: ["History"]), .init(name: "History", purpose: "Past days", leadsTo: [])],
        openQuestions: [],
        milestones: [.init(title: "Log water", features: ["Log a glass"], doneWhen: "Tapping + raises the total")])

    @Test func schemaIsValidJSONWithEveryFieldRequired() throws {
        let object = try #require(try JSONSerialization.jsonObject(with: Data(ProductPlan.schema.utf8)) as? [String: Any])
        let required = try #require(object["required"] as? [String])
        #expect(Set(required) == ["summary", "audience", "decisions", "mustHave", "canHave", "notNow", "screens", "openQuestions", "milestones"])
        #expect(object["additionalProperties"] as? Bool == false)
    }

    @Test func planRoundTripsThroughJSON() throws {
        let data = try JSONEncoder().encode(Self.plan)
        #expect(try JSONDecoder().decode(ProductPlan.self, from: data) == Self.plan)
    }

    @Test func rendersSectionsAndOmitsEmptyOnes() {
        let text = PlanRenderer.markdown(Self.plan, appName: "Water Tracker")
        #expect(text.hasPrefix("# Water Tracker: product plan"))
        for heading in ["## Design decisions", "## Must have", "## Not now", "## Screens", "## Build order", "### 1. Log water"] {
            #expect(text.contains(heading), "\(heading)")
        }
        #expect(!text.contains("## Can have"))
        #expect(!text.contains("## Open questions"))
        #expect(text.contains("Leads to: History."))
        #expect(text.contains("**Done when:** Tapping + raises the total"))
    }

    @Test func escapesMarkdownCharactersAndFlattensLines() {
        #expect(PlanRenderer.line("a_b *c* `d` [e]") == "a_b \\*c\\* \\`d\\` \\[e\\]")
        #expect(PlanRenderer.line("water_tracker, _x_ and #1") == "water_tracker, \\_x\\_ and #1")
        #expect(PlanRenderer.line("one\ntwo\n\nthree") == "one two three")
    }

    @Test func escapesWhatWouldStartABlock() {
        #expect(PlanRenderer.line("1. Log water") == "\\1. Log water")
        #expect(PlanRenderer.line("- not a list") == "\\- not a list")
        #expect(PlanRenderer.line("# not a heading") == "\\# not a heading")
        #expect(PlanRenderer.line("---") == "\\---")
        #expect(PlanRenderer.line("2026 is fine") == "2026 is fine")
        #expect(PlanRenderer.line("well-known") == "well-known")
    }

    @Test func writesPlanFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try PlanRenderer.write(Self.plan, appName: "Water", to: folder.path)
        let text = try String(contentsOf: folder.appendingPathComponent("PLAN.md"), encoding: .utf8)
        #expect(text.contains("Log a glass"))
    }

    @Test func nextStepsOfferBuildFirstAndSurviveExtraction() throws {
        let json = String(decoding: try JSONEncoder().encode(ProductPlan.nextSteps), as: UTF8.self)
        let extracted = ChoiceSet.extract(from: "Plan written.\n\n```choices\n\(json)\n```")
        #expect(extracted.text == "Plan written.")
        #expect(extracted.choices?.options.map(\.label) == [ProductPlan.buildLabel, ProductPlan.changeLabel, ProductPlan.notNowLabel])
        #expect(extracted.choices?.options.first?.recommended == true)
    }
}

struct LenientDecodingTests {
    @Test func aPlanMissingFieldsStillDecodes() throws {
        let plan = try JSONDecoder().decode(ProductPlan.self, from: Data(#"{"summary":"Only this"}"#.utf8))
        #expect(plan.summary == "Only this")
        #expect(plan.milestones.isEmpty)
    }

    @Test func anUnknownChatModeReadsAsBuild() throws {
        #expect(try JSONDecoder().decode(ChatMode.self, from: Data(#""someday""#.utf8)) == .build)
        #expect(try JSONDecoder().decode(ChatMode.self, from: Data(#""kickoff""#.utf8)) == .kickoff)
    }
}

struct KickoffCallTests {
    @Test func readOnlyCallHasNoShellAndNoEditingTools() {
        let call = ClaudeAgentCall(prompt: "hi", tools: ["Read", "Glob", "Grep"], maxBudgetUSD: 1, allowedCommands: [])
        let arguments = call.arguments
        #expect(arguments.firstIndex(of: "--tools").map { arguments[$0 + 1] } == "Read,Glob,Grep")
        let allowed = arguments.firstIndex(of: "--allowedTools").map { Array(arguments[($0 + 1)...]) }
        #expect(allowed == ["Read", "Glob", "Grep"])
        #expect(!arguments.contains { $0.hasPrefix("Bash") || $0 == "Edit" || $0 == "Write" })
    }

    @Test func defaultCallKeepsEditingAndGrantedCommands() {
        let call = ClaudeAgentCall(prompt: "hi", maxBudgetUSD: 1, allowedCommands: ["flutter pub *"])
        #expect(call.arguments.firstIndex(of: "--tools").map { call.arguments[$0 + 1] } == "Read,Glob,Grep,Edit,Write,Bash")
    }
}

struct NewProjectRecordTests {
    @Test func savesAndLoadsPerFolder() throws {
        let folder = "/tmp/record-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: NewProjectRecord.url(forFolder: folder).deletingLastPathComponent()) }
        let request = NewProjectRequest(
            displayName: "Water", packageName: "water", description: "d", appID: nil,
            parentFolder: "/tmp", platforms: [.ios], usesGit: true)
        #expect(NewProjectRecord.load(forFolder: folder) == nil)

        var record = NewProjectRecord(request: request)
        record.save(forFolder: folder)
        record.kickoff = .skipped
        record.save(forFolder: folder)
        #expect(NewProjectRecord.load(forFolder: folder)?.kickoff == .skipped)
        #expect(NewProjectRecord.load(forFolder: folder)?.request == request)
    }

    @Test func initialParentPrefersAnExistingLastParent() throws {
        let defaults = try #require(UserDefaults(suiteName: "NewProjectDefaultsTests-\(UUID().uuidString)"))
        #expect(NewProjectDefaults.initialParent(defaults: defaults) == NewProjectRequest.defaultParent)
        defaults.set("/nonexistent/folder", forKey: NewProjectDefaults.lastParentKey)
        #expect(NewProjectDefaults.initialParent(defaults: defaults) == NewProjectRequest.defaultParent)
        defaults.set(NSTemporaryDirectory(), forKey: NewProjectDefaults.lastParentKey)
        #expect(NewProjectDefaults.initialParent(defaults: defaults) == NSTemporaryDirectory())
    }
}

struct PlannedFlowTests {
    private func screen(_ name: String) -> AppScreen { AppScreen(name: name, className: name + "Screen", file: "lib/\(name).dart") }

    @Test func plannedScreensJoinTheFlowAndMatchBuiltOnesByName() {
        let flow = AppFlow(folder: "/p", screens: [screen("Home")], links: [], start: "HomeScreen")
        let result = flow.adding(ProductPlanTests.plan)

        #expect(result.screens.map(\.name) == ["Home", "History"])
        #expect(result.screens.last?.isPlanned == true)
        #expect(result.screens.first?.isPlanned == false)
        #expect(result.links == [.init(from: "HomeScreen", to: "planned:history", kind: .opens)])
        #expect(result.start == "HomeScreen")
    }

    @Test func planNamesIgnoreScreenSuffixes() {
        let flow = AppFlow(folder: "/p", screens: [screen("Home")], links: [], start: nil)
        let plan = ProductPlan(summary: "s", audience: "", decisions: [], mustHave: [], canHave: [], notNow: [],
                               screens: [.init(name: "Home screen", purpose: "Today", leadsTo: [])], openQuestions: [], milestones: [])
        #expect(flow.adding(plan).screens.count == 1)
    }

    @Test func buildingAPlannedScreenReplacesItsCard() {
        let flow = AppFlow(folder: "/p", screens: [screen("Home"), screen("History")], links: [], start: nil)
        let result = flow.adding(ProductPlanTests.plan)
        #expect(result.screens.allSatisfy { !$0.isPlanned })
        #expect(result.links.isEmpty)
    }
}

struct MultipleChoiceBlocksTests {
    private let block = { (question: String) in
        "```choices\n{\"question\": \"\(question)\", \"options\": [{\"label\": \"A\"}, {\"label\": \"B\"}]}\n```"
    }

    @Test func findsEveryBlockAndKeepsTheText() {
        let text = "Nice idea.\n\n\(block("One?"))\n\nAnd also:\n\n\(block("Two?"))"
        let (rest, found) = ChoiceSet.extractAll(from: text)
        #expect(found.map(\.question) == ["One?", "Two?"])
        #expect(rest == "Nice idea.\n\nAnd also:")
    }

    @Test func dropsAnUnfinishedOrBrokenBlock() {
        let (rest, found) = ChoiceSet.extractAll(from: "Hi.\n\(block("One?"))\n```choices\n{\"options\": [{\"lab")
        #expect(found.count == 1)
        #expect(rest == "Hi.")
        #expect(ChoiceSet.extractAll(from: "Hi.\n```choices\nnot json\n```").choices.isEmpty)
        #expect(ChoiceSet.extractAll(from: "Plain.").text == "Plain.")
    }

    @Test func repliesWithEachQuestionsAnswer() {
        let reply = ChoiceSet.reply(answering: [("Accounts?", ["No"]), ("Features?", ["A", "B"]), ("Money?", [])])
        #expect(reply == "Here are my answers:\n- Accounts?: No\n- Features?: A, B\n- Money?: none of these")
    }
}

struct MilestoneProgressTests {
    private func plan(_ count: Int) -> ProductPlan {
        ProductPlan(summary: "s", audience: "", decisions: [], mustHave: [], canHave: [], notNow: [], screens: [], openQuestions: [],
                    milestones: (1...count).map { .init(title: "M\($0)", features: [], doneWhen: "") })
    }

    @Test func nextIsTheFirstUnbuiltMilestone() {
        let progress = MilestoneProgress(plan: plan(3), done: [0, 2])
        #expect(progress.next == 1)
        #expect(progress.state(of: 0) == .done)
        #expect(progress.state(of: 1) == .next)
        #expect(progress.state(of: 2) == .done)
        #expect(progress.summary == "2 of 3 built")
        #expect(!progress.isComplete)
    }

    @Test func allBuiltMeansComplete() {
        let progress = MilestoneProgress(plan: plan(2), done: [0, 1])
        #expect(progress.next == nil)
        #expect(progress.isComplete)
        #expect(MilestoneProgress(plan: plan(2), done: []).state(of: 1) == .later)
    }

    @Test func indexesOutsideThePlanAreIgnoredInTheSummary() {
        #expect(MilestoneProgress(plan: plan(2), done: [0, 9]).summary == "1 of 2 built")
    }

    @Test func planStoreRoundTripsAndDeletes() {
        let folder = "/tmp/plan-store-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: ProductPlanStore.url(forFolder: folder).deletingLastPathComponent()) }
        #expect(ProductPlanStore.load(forFolder: folder) == nil)
        ProductPlanStore.save(plan(2), forFolder: folder)
        #expect(ProductPlanStore.load(forFolder: folder) == plan(2))
        ProductPlanStore.delete(forFolder: folder)
        #expect(ProductPlanStore.load(forFolder: folder) == nil)
    }

    @Test func olderRecordsWithoutMilestonesStillLoad() throws {
        let request = NewProjectRequest(displayName: "W", packageName: "w", description: "", appID: nil,
                                        parentFolder: "/tmp", platforms: [.ios], usesGit: false)
        var record = NewProjectRecord(request: request)
        record.doneMilestones = [0]
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        object["doneMilestones"] = nil
        let decoded = try JSONDecoder().decode(NewProjectRecord.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.doneMilestones == nil)
    }
}
