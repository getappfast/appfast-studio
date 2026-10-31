import Foundation
import Testing
@testable import Mobile_Studio

struct FriendlyNameTests {
    @Test(arguments: [
        ("lib/ui/home/home_page.dart", "Home screen"),
        ("lib/ui/water/water_intake_screen.dart", "Water intake screen"),
        ("lib/widgets/meal_card.dart", "Meal card"),
        ("lib/models/user.dart", "User data"),
        ("lib/services/auth_service.dart", "Auth logic"),
        ("lib/main.dart", "App start-up"),
        ("pubspec.yaml", "Packages"),
        ("ios/Runner/Info.plist", "iOS project settings"),
        ("assets/images/logo.png", "Image: logo.png"),
        ("test/home_page_test.dart", "Test: Home page"),
        ("README.md", "README.md"),
    ])
    func namesFilesInPlainWords(path: String, expected: String) {
        #expect(FriendlyName.of(path) == expected)
    }

    @Test func namesScreensFromClasses() {
        #expect(FriendlyName.screenName(fromClass: "HomePage") == "Home")
        #expect(FriendlyName.screenName(fromClass: "WaterIntakeScreen") == "Water intake")
        #expect(FriendlyName.screenName(fromClass: "AIInsightsView") == "AIInsights")
    }
}

struct ScreenFinderTests {
    @Test func findsWidgetClassesNamedLikeScreens() {
        let source = """
        class HomePage extends StatefulWidget {}
        class _HomePageState extends State<HomePage> {}
        class SettingsScreen extends StatelessWidget {}
        class ProfileView extends ConsumerWidget {}
        class MealCard extends StatelessWidget {}
        class PageController {}
        """
        #expect(ScreenFinder.screens(in: source, file: "lib/a.dart").map(\.name) == ["Home", "Settings", "Profile"])
    }

    @Test func scansTheLibFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let lib = root.appendingPathComponent("lib/ui")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        try Data("class WaterPage extends StatelessWidget {}".utf8).write(to: lib.appendingPathComponent("water_page.dart"))
        let screens = ScreenFinder.screens(in: root.path)
        #expect(screens.map(\.name) == ["Water"])
        #expect(screens.first?.file == "lib/ui/water_page.dart")
    }
}

struct AnswerPartsTests {
    @Test func splitsTheOutcomeFromTheTechnicalNotes() {
        let parts = AnswerParts.split("The buttons now share the row.\n\n---\nWrapped each in `Expanded` in water_page.dart.")
        #expect(parts.outcome == "The buttons now share the row.")
        #expect(parts.details == "Wrapped each in `Expanded` in water_page.dart.")
    }

    @Test func keepsAnAnswerWithoutARuleWhole() {
        #expect(AnswerParts.split("Nothing to change.").outcome == "Nothing to change.")
        #expect(AnswerParts.split("Nothing to change.").details == nil)
    }
}

struct CheckpointTests {
    private func project() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("lib"), withIntermediateDirectories: true)
        return root
    }

    private func write(_ text: String, _ path: String, in root: URL) throws {
        try Data(text.utf8).write(to: root.appendingPathComponent(path))
    }

    private func read(_ path: String, in root: URL) -> String? {
        (try? Data(contentsOf: root.appendingPathComponent(path))).map { String(decoding: $0, as: UTF8.self) }
    }

    @Test func undoPutsFilesBack() throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root); CheckpointStore.discardAll(folder: root.path) }
        try write("old", "lib/a.dart", in: root)
        try write("gone soon", "lib/b.dart", in: root)
        let before = FileSnapshot.take(of: root.path, keepingContents: true)

        try write("new", "lib/a.dart", in: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("lib/b.dart"))
        try write("added", "lib/c.dart", in: root)
        let after = FileSnapshot.take(of: root.path)
        let id = UUID()
        #expect(CheckpointStore.save(id: id, folder: root.path, changes: after.changes(since: before), before: before, after: after))

        let restored = try CheckpointStore.restore(id: id, folder: root.path)
        #expect(restored.count == 3)
        #expect(read("lib/a.dart", in: root) == "old")
        #expect(read("lib/b.dart", in: root) == "gone soon")
        #expect(read("lib/c.dart", in: root) == nil)
    }

    @Test func undoRefusesWhenAFileChangedSince() throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root); CheckpointStore.discardAll(folder: root.path) }
        try write("old", "lib/a.dart", in: root)
        let before = FileSnapshot.take(of: root.path, keepingContents: true)
        try write("claude", "lib/a.dart", in: root)
        let after = FileSnapshot.take(of: root.path)
        let id = UUID()
        CheckpointStore.save(id: id, folder: root.path, changes: after.changes(since: before), before: before, after: after)

        try write("the user's own edit", "lib/a.dart", in: root)
        #expect(throws: CheckpointStore.Failure.changedSince("lib/a.dart")) {
            try CheckpointStore.restore(id: id, folder: root.path)
        }
        #expect(read("lib/a.dart", in: root) == "the user's own edit")
    }
}

struct ChoiceSetTests {
    @Test func takesTheChoicesOutOfTheAnswer() throws {
        let text = """
        I found four things worth fixing.

        ---
        Details here.

        ```choices
        {"question": "What should I do first?", "multiple": true,
         "options": [{"label": "Fix the broken test", "detail": "test/widget_test.dart fails", "recommended": true},
                     {"label": "Run dart fix --apply"}]}
        ```
        """
        let (rest, choices) = ChoiceSet.extract(from: text)
        #expect(rest == "I found four things worth fixing.\n\n---\nDetails here.")
        let set = try #require(choices)
        #expect(set.question == "What should I do first?")
        #expect(set.allowsMultiple)
        #expect(set.options.map(\.label) == ["Fix the broken test", "Run dart fix --apply"])
        #expect(set.options.first?.recommended == true)
    }

    @Test func hidesABlockStillBeingWritten() {
        let (rest, choices) = ChoiceSet.extract(from: "Done.\n\n```choices\n{\"options\": [{\"lab")
        #expect(rest == "Done.")
        #expect(choices == nil)
    }

    @Test func dropsABlockThatIsntValid() {
        let (rest, choices) = ChoiceSet.extract(from: "Done.\n```choices\nnot json\n```")
        #expect(rest == "Done.")
        #expect(choices == nil)
        #expect(ChoiceSet.extract(from: "No choices here.").text == "No choices here.")
    }

    @Test func repliesWithWhatWasPicked() {
        #expect(ChoiceSet.reply(choosing: ["Fix the test"]) == "Go ahead: Fix the test.")
        #expect(ChoiceSet.reply(choosing: ["A", "B"]) == "Go ahead with these, in this order:\n- A\n- B")
    }
}
