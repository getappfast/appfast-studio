import Foundation
import Testing
@testable import Mobile_Studio

private func tokens(_ style: String = "minimal") -> DesignTokens {
    DesignStyle.named(style)!.tokens
}

struct DesignTokensTests {
    @Test func everyBundledStyleIsValid() {
        #expect(DesignStyle.bundled.map(\.id) == DesignStyle.order)
        for style in DesignStyle.bundled {
            #expect(style.tokens.issues(catalog: GoogleFontsCatalog.bundled) == [], "\(style.id)")
            #expect(style.tokens.style == style.id)
        }
    }

    @Test func reportsBadColoursContrastAndFonts() {
        var bad = tokens()
        bad.light.primary = "teal"
        bad.light.onSurface = "#EEEEEE"
        bad.fonts = .init(display: "Not A Real Font", body: "Inter")
        bad.typeScale["titleLarge"] = .init(size: 200, weight: 450)
        let issues = bad.issues(catalog: GoogleFontsCatalog.bundled)
        #expect(issues.contains { $0.contains("light primary colour \"teal\"") })
        #expect(issues.contains { $0.contains("text on the background is hard to read") })
        #expect(issues.contains { $0.contains("Not A Real Font isn't a Google Fonts family") })
        #expect(issues.contains { $0.contains("titleLarge has size 200") })
    }

    @Test func reportsAWeightTheFontLacks() {
        var thin = tokens()
        thin.fonts = .init(display: "Fredoka", body: "Fredoka")
        thin.typeScale["displayLarge"] = .init(size: 57, weight: 900)
        #expect(thin.issues(catalog: GoogleFontsCatalog.bundled).contains { $0.contains("Fredoka has no weight 900") })
    }

    @Test func decodesLooselyButNeedsColours() throws {
        let scheme = try JSONEncoder().encode(tokens().light)
        let json = "{\"light\": \(String(decoding: scheme, as: UTF8.self)), \"dark\": \(String(decoding: scheme, as: UTF8.self))}"
        guard case .success(let loose) = DesignTokens.decode(Data(json.utf8)) else { Issue.record("didn't decode"); return }
        #expect(loose.typeScale == DesignTokens.materialTypeScale)
        #expect(loose.fonts.body == "system")
        guard case .failure(let error) = DesignTokens.decode(Data("{\"light\": {}}".utf8)) else { Issue.record("decoded"); return }
        #expect(error.message.contains("tokens.json couldn't be read"))
    }

    @Test func contrastMatchesWCAG() {
        #expect(abs(HexColor("#000000")!.contrast(with: HexColor("#FFFFFF")!) - 21) < 0.01)
        #expect(HexColor("#777777")!.contrast(with: HexColor("#FFFFFF")!) < 4.5)
        #expect(HexColor("#1F6F5C")!.dart == "0xFF1F6F5C")
        #expect(HexColor("1F6F5C") == nil && HexColor("#12345") == nil)
    }

    @Test func cssHasEveryRoleBothSchemesAndFonts() {
        let css = TokensCSS.css(tokens("editorial"), fonts: [.init(family: "Fraunces", weight: 600, italic: false, path: "fonts/Fraunces-SemiBold.ttf")])
        for role in tokens().light.roles { #expect(css.contains("--\(TokensCSS.kebab(role.name)):")) }
        #expect(css.contains("--on-primary-container:"))
        #expect(css.contains("@media (prefers-color-scheme: dark)"))
        #expect(css.contains("font-family: 'Fraunces'; font-style: normal; font-weight: 600; src: url('fonts/Fraunces-SemiBold.ttf')"))
        #expect(css.contains("--font-display: 'Fraunces', -apple-system"))
        #expect(css.contains("--display-large-size: 57px; --display-large-weight: 600;"))
        #expect(css.contains("--card-border: 1px solid var(--outline);"))
        #expect(TokensCSS.css(tokens("classic")).contains("--font-body: -apple-system, sans-serif;"))
    }

    @Test func dartThemeUsesGoogleFontsOnlyWhenNeeded() {
        let dart = ThemeRenderer.dart(tokens("editorial"))
        #expect(dart.contains("import 'package:google_fonts/google_fonts.dart';"))
        #expect(!dart.contains("getTextTheme"))
        #expect(dart.contains("TextStyle? body(TextStyle? style) => GoogleFonts.getFont('Inter', textStyle: style);"))
        #expect(dart.contains("GoogleFonts.getFont('Fraunces', textStyle: style)"))
        #expect(dart.contains("bodyLarge: body(text.bodyLarge?.copyWith(fontSize: 16, fontWeight: FontWeight.w400)),"))
        #expect(dart.contains("primary: Color(0xFF8C2F1B),"))
        #expect(dart.contains("displayLarge: display(text.displayLarge?.copyWith(fontSize: 57, fontWeight: FontWeight.w600)),"))
        #expect(dart.contains("side: BorderSide(color: scheme.outline)"))
        #expect(dart == ThemeRenderer.dart(tokens("editorial")))
        let classic = ThemeRenderer.dart(tokens("classic"))
        #expect(!classic.contains("google_fonts"))
        #expect(ThemeRenderer.needsGoogleFonts(tokens("classic")) == false)
        #expect(ThemeRenderer.dartString("it's $5") == "'it\\'s \\$5'")
    }
}

struct ThemeWiringTests {
    private let starter = """
        import 'package:flutter/material.dart';

        /// Colours come from here and nowhere else.
        class AppTheme {
          const AppTheme._();

          static const seed = Color(0xFF2E7D6B);

          static const habitColors = [Color(0xFF2E7D6B)];

          static final light = _build(Brightness.light);
          static final dark = _build(Brightness.dark);

          static ThemeData _build(Brightness brightness) {
            return ThemeData(
              useMaterial3: true,
              colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: brightness),
            );
          }
        }
        """

    @Test func replacesOnlyTheBuilderAndKeepsTheRest() {
        guard case .wired(let text) = ThemeWiring.wire(starter, package: "habit_kit") else { Issue.record("not wired"); return }
        #expect(text.contains("import 'package:flutter/material.dart';\nimport 'package:habit_kit/app/design_theme.dart';\n"))
        #expect(text.contains("static const habitColors = [Color(0xFF2E7D6B)];"))
        #expect(text.contains("brightness == Brightness.dark ? DesignTheme.dark : DesignTheme.light;"))
        #expect(!text.contains("ColorScheme.fromSeed"))
        #expect(text.hasSuffix("}"))
        #expect(ThemeWiring.wire(text, package: "habit_kit") == .alreadyWired)
    }

    @Test func leavesAnUnfamiliarThemeToClaude() {
        #expect(ThemeWiring.wire("final theme = ThemeData();", package: "x") == .notRecognized)
    }
}

struct DesignLintTests {
    private let clean = """
        <!doctype html><html><head><meta charset="utf-8"><meta name="ms-screen" content="Today">
        <link rel="stylesheet" href="../../tokens.css"><link rel="stylesheet" href="../../kit.css"></head>
        <body><div class="screen"><div class="row gap-2" style="width: 120px; --value: 40%">
        <span class="icon small">water_drop</span><span class="button filled">Add</span></div></div></body></html>
        """

    @Test func aCleanScreenHasNoIssues() {
        #expect(DesignLint.issues(in: clean, file: "v1.html", icons: IconCatalog.bundled) == [])
        #expect(DesignLint.issues(in: DesignStyle.sampleHTML, file: "sample.html", icons: IconCatalog.bundled) == [])
    }

    @Test func findsEachBrokenRule() {
        let broken = """
            <div class="screen"><script>x()</script><img src="a.png"><div style="display: grid; color: #ff0000; position: absolute">
            <span class="icon">not_an_icon</span><span class="fancy">x</span></div>
            <link href="https://fonts.googleapis.com/css"></div>
            """
        let messages = DesignLint.issues(in: broken, file: "v2.html", icons: IconCatalog.bundled).map(\.message)
        for fragment in ["JavaScript", "internet", "<img>", "ms-screen", "grid", "absolute", "literal colour (#ff0000)", "fancy", "not_an_icon"] {
            #expect(messages.contains { $0.contains(fragment) }, "\(fragment)")
        }
    }

    @Test func kitClassesMatchKitCSS() throws {
        let css = try #require(DesignResources.text("kit.css"))
            .replacing(/(?s)\/\*.*?\*\//, with: "").replacing(/url\([^)]*\)/, with: "")
        let defined = Set(css.matches(of: /\.([a-z][a-z0-9-]*)/).map { String($0.1) })
        #expect(defined.subtracting(DesignLint.kitClasses) == [], "in kit.css but not the list")
        #expect(DesignLint.kitClasses.subtracting(defined) == [], "in the list but not kit.css")
    }

    @Test func iconsBecomeCodePoints() throws {
        let icons = try #require(IconCatalog.bundled)
        #expect(icons.count > 8000)
        let point = try #require(icons.codepoint(of: "water_drop"))
        let html = IconSubstitution.apply("<span class=\"icon large\">water_drop</span> <span class=\"icon\">nope</span>", icons: icons)
        #expect(html.contains("<span class=\"icon large\" title=\"water_drop\">&#x\(String(point, radix: 16));</span>"))
        #expect(html.contains("<span class=\"icon icon-unknown\" title=\"nope\"></span>"))
        #expect(IconSubstitution.apply("<span class=\"iconic\">x</span>", icons: icons) == "<span class=\"iconic\">x</span>")
    }
}

struct DesignVersionsTests {
    @Test func idsAreNeverReused() {
        var versions = DesignVersions(name: "Today")
        #expect(versions.nextIDs(count: 2) == ["v1", "v2"])
        versions.add(ids: ["v1", "v2"], parent: "current", request: "Show me two", messageID: nil)
        #expect(versions.chosen == "v2")
        #expect(versions.rounds.map { $0.map(\.id) } == [["v1", "v2"]])
        versions.add(ids: ["v3"], parent: "v1", request: "Bigger", messageID: nil)
        #expect(versions.rounds.count == 2 && versions.chosen == "v3")
        // An undo removed v3's file; its number still isn't handed out again while the file of v5 exists.
        versions.prune(existingFiles: ["current.html", "v1.html", "v2.html", "v5.html"])
        #expect(versions.versions.map(\.id) == ["v1", "v2"])
        #expect(versions.chosen == "v2")
        #expect(versions.nextIDs(count: 1, existingFiles: ["v5.html"]) == ["v6"])
        #expect(versions.defaultParent(hasCurrent: true) == "v2")
        #expect(DesignVersions(name: "x").defaultParent(hasCurrent: true) == "current")
    }

    @Test func decodesAnOlderFile() throws {
        let versions = try JSONDecoder().decode(DesignVersions.self, from: Data(#"{"name":"Home","versions":[{"id":"v1"}]}"#.utf8))
        #expect(versions.versions.first?.round == 0)
        #expect(versions.chosen == nil)
    }
}

struct DesignLibraryTests {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("design-\(UUID().uuidString)")
        let today = root.appendingPathComponent("design/screens/today")
        try FileManager.default.createDirectory(at: today, withIntermediateDirectories: true)
        try Data("<meta name=\"ms-screen\" content=\"Today\">".utf8).write(to: today.appendingPathComponent("current.html"))
        try Data().write(to: today.appendingPathComponent("v1.html"))
        var versions = DesignVersions(name: "Today", file: "lib/today_screen.dart")
        versions.add(ids: ["v1", "v2"], parent: "current", request: "two", messageID: nil)
        try versions.encoded().write(to: today.appendingPathComponent("screen.json"))
        let history = root.appendingPathComponent("design/screens/history")
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        try Data("<meta name='ms-screen' content='History'>".utf8).write(to: history.appendingPathComponent("v1.html"))
        return root
    }

    @Test func readsScreensAndDropsMissingVersions() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = DesignLibrary.load(folder: root.path)
        #expect(library.screens.map(\.id) == ["history", "today"])
        let today = try #require(library.screen(named: "TodayScreen"))
        #expect(today.versions.versions.map(\.id) == ["v1"])
        #expect(today.versions.chosen == "v1")
        #expect(today.hasCurrent && !today.hasCapture)
        #expect(library.screen("history")?.name == "History")
    }

    @Test func screenIDs() {
        #expect(DesignPaths.screenID(for: "HabitFormScreen") == "habit_form")
        #expect(DesignPaths.screenID(for: "Habit form") == "habit_form")
        #expect(DesignPaths.screenID(for: "Today") == "today")
        #expect(DesignPaths.screenID(for: "Screen") == "screen")
        #expect(DesignPaths.screenID(for: "!!") == "screen")
    }

    @Test func handoffListsAMilestonesChosenVersions() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = DesignLibrary.load(folder: root.path)
        let plan = ProductPlan(summary: "", audience: "", decisions: [],
                               mustHave: [.init(title: "Daily list", detail: "", screens: ["Today", "Settings"]),
                                          .init(title: "History", detail: "", screens: ["History"])],
                               canHave: [], notNow: [], screens: [], openQuestions: [],
                               milestones: [.init(title: "Track", features: ["Daily list"], doneWhen: "")])
        let references = DesignHandoff.references(for: 0, plan: plan, library: library) { screen, version in "/p/\(screen.id)-\(version).png" }
        #expect(references == [.init(screen: "Today", html: "design/screens/today/v1.html", preview: "/p/today-v1.png")])
        #expect(DesignHandoff.milestoneNote(references)?.contains("- Today: design/screens/today/v1.html (picture: /p/today-v1.png)") == true)
        #expect(DesignHandoff.references(for: 3, plan: plan, library: library).isEmpty)
    }

    @Test func applyMessageAsksForOnlyTheDifference() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let today = try #require(DesignLibrary.load(folder: root.path).screen("today"))
        let message = DesignHandoff.applyMessage(screen: today, version: "v1", preview: "/p/v1.png", currentPreview: nil)
        #expect(message.contains("Update the Today screen (lib/today_screen.dart) to match the design design/screens/today/v1.html."))
        #expect(message.contains("change only what differs between design/screens/today/current.html and design/screens/today/v1.html"))
        #expect(message.contains("the design: /p/v1.png"))
    }
}

struct LookTests {
    @Test func suggestionsKeepReadableThemesAndRealFonts() {
        let good = tokens("soft")
        var unreadable = good.light
        unreadable.onPrimary = unreadable.primary
        let palettes = LookSuggestions.encode(palettes: [
            .init(name: "Lavender", mood: "Soft", why: "Calm", light: good.light, dark: good.dark),
            .init(name: "Mud", mood: "Bad", why: "No", light: unreadable, dark: good.dark),
        ])
        let pairings = LookSuggestions.encode(pairings: [
            .init(display: "Fraunces", body: "Inter", why: "Classic"), .init(display: "Comic Sans Pro", body: "Inter", why: "No"),
        ])
        let found = LookSuggestions.read(palettes: palettes, pairings: pairings, catalog: GoogleFontsCatalog.bundled)
        #expect(found.palettes.map(\.name) == ["Lavender"])
        #expect(found.pairings.map(\.title) == ["Fraunces and Inter"])
        #expect(found.dropped.count == 2)
        #expect(LookSuggestions.read(palettes: Data("{".utf8), pairings: nil, catalog: nil).dropped.first?.contains("palettes.json") == true)
    }

    @Test func combiningMovesWeightsToOnesTheFontHas() throws {
        let style = tokens("bold")
        let pairing = LookSuggestions.Pairing(display: "Fredoka", body: "Fredoka", why: "")
        let combined = try #require(LookSuggestions.tokens(style: style, palette: nil, pairing: pairing, catalog: GoogleFontsCatalog.bundled))
        #expect(combined.fonts.display == "Fredoka")
        #expect(combined.typeScale["displayLarge"]?.weight == 700)
        #expect(combined.issues(catalog: GoogleFontsCatalog.bundled) == [])
    }

    @Test func recommendsTheStyleThePlanNames() {
        let plan = ProductPlan(summary: "", audience: "", decisions: [.init(title: "Look and feel", choice: "Calm and minimal", why: "Focus", alternatives: [])],
                               mustHave: [], canHave: [], notNow: [], screens: [], openQuestions: [], milestones: [])
        #expect(DesignStyle.recommended(for: plan) == "minimal")
        #expect(DesignStyle.recommended(for: nil) == nil)
    }
}

struct GoogleFontsTests {
    @Test func catalogLooksUpFamiliesAndWeights() throws {
        let catalog = try #require(GoogleFontsCatalog.bundled)
        let inter = try #require(catalog.family(named: "inter"))
        #expect(inter.family == "Inter" && inter.has(weight: 600))
        #expect(catalog.family(named: "Source Sans 3") != nil)
        #expect(catalog.family(named: "Fredoka")?.nearest(to: 900) == 700)
    }

    @Test func fileNamesMatchTheGoogleFontsPackage() {
        #expect(GoogleFontFile.name(family: "Inter", weight: 400) == "Inter-Regular.ttf")
        #expect(GoogleFontFile.name(family: "Plus Jakarta Sans", weight: 600, italic: true) == "PlusJakartaSans-SemiBoldItalic.ttf")
        #expect(GoogleFontFile.name(family: "Inter", weight: 400, italic: true) == "Inter-Italic.ttf")
        #expect(GoogleFontFile.cssURL(family: "Fraunces", weights: [700, 400, 400])?.absoluteString
                == "https://fonts.googleapis.com/css2?family=Fraunces:wght@400;700")
    }

    @Test func takesOneTTFPerWeightAndRefusesWOFF() {
        let ttf = """
            @font-face { font-family: 'Inter'; font-style: normal; font-weight: 400; src: url(https://fonts.gstatic.com/s/inter/a.ttf) format('truetype'); }
            @font-face { font-family: 'Inter'; font-style: normal; font-weight: 700; src: url(https://fonts.gstatic.com/s/inter/b.ttf) format('truetype'); }
            """
        guard case .success(let faces) = GoogleFontFile.faces(inCSS: ttf) else { Issue.record("no faces"); return }
        #expect(faces.map(\.weight) == [400, 700])
        let woff = "/* latin */ @font-face { font-weight: 400; src: url(https://fonts.gstatic.com/s/x/a.woff2) format('woff2'); }"
        #expect(GoogleFontFile.faces(inCSS: woff) == .failure(.wrongFormat("woff2")))
        #expect(GoogleFontFile.faces(inCSS: "") == .failure(.noFaces))
    }

    @Test func pubspecGetsTheFontsFolderOnce() {
        let pubspec = "name: app\n\ndependencies:\n  flutter:\n    sdk: flutter\n  flutter_lints: ^6.0.0\n\nflutter:\n  uses-material-design: true\n"
        let added = PubspecAssets.adding(to: pubspec)
        #expect(added.contains("flutter:\n  uses-material-design: true\n  assets:\n    - assets/google_fonts/\n"))
        #expect(PubspecAssets.adding(to: added) == added)
        let withAssets = "flutter:\n  assets:\n    - assets/images/\n  # comment\n"
        #expect(PubspecAssets.adding(to: withAssets) == "flutter:\n  assets:\n    - assets/images/\n    - assets/google_fonts/\n  # comment\n")
        #expect(PubspecAssets.adding(to: "name: app\n").hasSuffix("\nflutter:\n  assets:\n    - assets/google_fonts/\n"))
    }
}

struct DesignCallTests {
    @Test func limitsEditsToThePattern() {
        let call = ClaudeAgentCall(prompt: "x", maxBudgetUSD: 2, allowedCommands: [], asksForApproval: true, editablePattern: "design/**")
        let arguments = call.arguments
        #expect(arguments.contains("default") && !arguments.contains("acceptEdits"))
        let allowed = Array(arguments.drop { $0 != "--allowedTools" }.dropFirst())
        #expect(allowed == ["Read", "Glob", "Grep", "Edit(design/**)"])
        #expect(arguments.contains("Read,Glob,Grep,Edit,Write"))
        let plain = ClaudeAgentCall(prompt: "x", maxBudgetUSD: 2, allowedCommands: [])
        #expect(plain.arguments.contains("acceptEdits"))
        #expect(Array(plain.arguments.drop { $0 != "--allowedTools" }.dropFirst()) == ClaudeAgentCall.tools)
    }

    @Test func designModeRefusesOtherEditsAndCommands() {
        let edit = AgentPermissionRequest(id: "1", action: .editFile("/p/lib/main.dart"), reason: nil, input: Data())
        let read = AgentPermissionRequest(id: "2", action: .readFile("/Users/x/notes.txt"), reason: nil, input: Data())
        #expect(AgentPermissionPolicy.designRefusal(for: edit)?.contains("only changes files in design/") == true)
        #expect(AgentPermissionPolicy.designRefusal(for: read) == nil)
    }

    @Test func turnsNameTheirFilesAndCost() {
        let target = DesignTurn.Target(screenID: "today", name: "Today", parent: "v2", ids: ["v3", "v4"], about: nil)
        let versions = DesignTurn(kind: .versions([target]), request: "Show me two")
        #expect(versions.expectedFiles == ["design/screens/today/v3.html", "design/screens/today/v4.html"])
        #expect(versions.model == "sonnet" && versions.maxBudgetUSD == 2 && versions.editablePattern == "design/**")
        let text = DesignPrompts.instructions(for: versions, style: nil, tokens: nil, issues: ["v2.html: Uses CSS grid."])
        #expect(text.contains("Today: write design/screens/today/v3.html and design/screens/today/v4.html, starting from design/screens/today/v2.html."))
        #expect(text.contains("Fix these first:\n- v2.html: Uses CSS grid."))
        let look = DesignTurn(kind: .look(style: "soft", start: .init(screenID: "today", name: "Today", parent: nil, ids: ["v1"], about: nil)), request: "Soft")
        #expect(look.model == "opus" && look.maxBudgetUSD == 3)
        #expect(look.expectedFiles == ["design/screens/today/v1.html", "design/look/palettes.json", "design/look/fonts.json"])
        let suggestions = DesignTurn(kind: .suggestions(.palettes, hint: "warmer"), request: "More")
        #expect(suggestions.editablePattern == "design/look/**" && suggestions.maxBudgetUSD == 0.5)
        #expect(DesignPrompts.instructions(for: suggestions, style: nil, tokens: nil, issues: []).contains("The user wants: warmer."))
        let current = DesignTurn(kind: .current(screen: "today", name: "Today", file: "lib/t.dart", hasCapture: true), request: "Redesign")
        let currentText = DesignPrompts.instructions(for: current, style: nil, tokens: nil, issues: [])
        #expect(currentText.contains("design/screens/today/current.png is a picture"))
        #expect(currentText.contains("There is no design/tokens.json yet"))
    }
}

struct DesignHelperTests {
    @Test func mockupsReachOnlyDesignFilesKitStylesAndFonts() {
        #expect(DesignURL.resolve(URL(string: "ms-design://project/screens/today/v1.html")!) == .project("screens/today/v1.html"))
        #expect(DesignURL.resolve(URL(string: "ms-design://kit/kit.css")!) == .kit("kit.css"))
        #expect(DesignURL.resolve(URL(string: "ms-design://style/soft/tokens.css")!) == .style(id: "soft", file: "tokens.css"))
        #expect(DesignURL.resolve(URL(string: "ms-design://fonts/Inter/Inter-Regular.ttf")!) == .font("Inter/Inter-Regular.ttf"))
        for refused in ["ms-design://project/../lib/main.dart", "ms-design://project/screens/%2E%2E/x", "ms-design://kit/a/b",
                        "ms-design://elsewhere/x", "file:///etc/passwd", "ms-design://project/", "ms-design://fonts/../../x"] {
            #expect(DesignURL.resolve(URL(string: refused)!) == nil, "\(refused)")
        }
        #expect(DesignURL.mimeType(for: "a/b.html") == "text/html")
    }

    @Test func readsVersionSummariesFromTheAnswer() {
        let text = "Two takes on the list.\n\n- **v3**: the total moves to the top.\nv4 — cards instead of rows.\n---\nNotes"
        #expect(DesignModel.summaries(in: text) == ["v3": "the total moves to the top.", "v4": "cards instead of rows."])
    }

    @Test func countsTheVersionsARequestAsksFor() {
        #expect(DesignPrompts.versionCount(in: "Make the header calmer") == 1)
        #expect(DesignPrompts.versionCount(in: "Show me three ways to fit the total") == 3)
        #expect(DesignPrompts.versionCount(in: "give me 2 options for the list") == 2)
        #expect(DesignPrompts.versionCount(in: "a few versions of the empty state") == 3)
    }

    @Test func batchesScreensFourAtATime() {
        let targets = (1...9).map { DesignTurn.Target(screenID: "s\($0)", name: "S\($0)", parent: nil, ids: ["v1"], about: nil) }
        #expect(DesignPrompts.batches(targets).map(\.count) == [4, 4, 1])
        #expect(DesignPrompts.batches([]).isEmpty)
    }

    @Test func nearestStyleToADescription() {
        #expect(DesignStyle.nearest(to: "Something elegant with serif type") == "editorial")
        #expect(DesignStyle.nearest(to: "whatever you think") == "classic")
    }
}

struct FontLicenceTests {
    @Test func licencesAreLookedUpWhereGoogleKeepsThem() {
        #expect(GoogleFontFile.licenceName(family: "Source Sans 3") == "SourceSans3-LICENSE.txt")
        #expect(GoogleFontFile.licenceURLs(family: "Source Sans 3").map(\.absoluteString) == [
            "https://raw.githubusercontent.com/google/fonts/main/ofl/sourcesans3/OFL.txt",
            "https://raw.githubusercontent.com/google/fonts/main/apache/sourcesans3/LICENSE.txt",
            "https://raw.githubusercontent.com/google/fonts/main/ufl/sourcesans3/UFL.txt",
        ])
    }

    @Test func themeRegistersBundledLicencesOnce() {
        let dart = ThemeRenderer.dart(DesignStyle.named("editorial")!.tokens, licences: ["assets/google_fonts/Inter-LICENSE.txt"])
        #expect(dart.hasPrefix("import 'package:flutter/foundation.dart';\nimport 'package:flutter/material.dart';\nimport 'package:flutter/services.dart';"))
        #expect(dart.contains("for (final file in const ['assets/google_fonts/Inter-LICENSE.txt']) {"))
        #expect(dart.contains("  static ThemeData _build(ColorScheme scheme) {\n    _addFontLicences();"))
        #expect(!ThemeRenderer.dart(DesignStyle.named("editorial")!.tokens).contains("LicenseRegistry"))
    }
}
