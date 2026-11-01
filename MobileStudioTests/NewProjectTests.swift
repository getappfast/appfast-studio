import Foundation
import Testing
@testable import Mobile_Studio

struct PackageNameTests {
    @Test func derivesFromPlainNames() {
        #expect(PackageName.derive(from: "Water Tracker") == "water_tracker")
        #expect(PackageName.derive(from: "  My   Cool-App!  ") == "my_cool_app")
        #expect(PackageName.derive(from: "Café Crème") == "cafe_creme")
    }

    @Test func movesLeadingDigitsToTheEnd() {
        #expect(PackageName.derive(from: "2048 Game") == "game_2048")
        #expect(PackageName.derive(from: "42") == "app_42")
    }

    @Test func fallsBackWhenNothingUsable() {
        #expect(PackageName.derive(from: "") == "my_app")
        #expect(PackageName.derive(from: "☕️🔥") == "my_app")
    }

    @Test func avoidsReservedAndClashingNames() {
        #expect(PackageName.derive(from: "Class") == "class_app")
        #expect(PackageName.derive(from: "Flutter") == "flutter_app")
        #expect(PackageName.derive(from: "Test") == "test_app")
    }

    @Test func derivedNamesAlwaysPassTheRules() {
        for name in ["Water Tracker", "2048", "Class", "☕️", String(repeating: "a", count: 90), "9 lives"] {
            #expect(PackageName.problem(with: PackageName.derive(from: name)) == nil, "\(name)")
        }
    }

    @Test func explainsInvalidNames() {
        #expect(PackageName.problem(with: "") != nil)
        #expect(PackageName.problem(with: "Water") != nil)
        #expect(PackageName.problem(with: "1water") != nil)
        #expect(PackageName.problem(with: "switch") != nil)
        #expect(PackageName.problem(with: "flutter") != nil)
        #expect(PackageName.problem(with: String(repeating: "a", count: 65)) != nil)
        #expect(PackageName.problem(with: "water_tracker") == nil)
    }
}

struct AppIDTests {
    @Test func acceptsReverseDNS() {
        #expect(AppID.issues(in: "com.leo.watertracker").isEmpty)
        #expect(AppID.issues(in: "dev.leo.water_tracker2").isEmpty)
    }

    @Test func rejectsMalformedIDs() {
        for id in ["watertracker", "com..app", "com.1app", "com.leo.water-tracker", ".com.app", "com.leo.", "com.new.app", "com.leo.Class"] {
            #expect(AppID.issues(in: id).first?.severity == .error, "\(id)")
        }
    }

    @Test func warnsAboutComExample() {
        let issues = AppID.issues(in: "com.example.water")
        #expect(issues.count == 1)
        #expect(issues.first?.severity == .warning)
    }

    @Test func standardIDMatchesWhatFlutterGenerates() {
        #expect(AppID.standard(forPackage: "water_tracker") == "com.example.water_tracker")
    }
}

struct NewProjectRequestTests {
    private func request(
        name: String = "Water Tracker", appID: String? = nil, parent: String,
        platforms: Set<ProjectPlatform> = [.ios, .android]
    ) -> NewProjectRequest {
        NewProjectRequest(
            displayName: name, packageName: PackageName.derive(from: name), description: "", appID: appID,
            parentFolder: parent, platforms: platforms, usesGit: true)
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aValidRequestHasNoIssues() throws {
        let parent = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: parent) }
        #expect(request(appID: "com.leo.water", parent: parent.path).validate().isEmpty)
        #expect(request(parent: parent.path).path == parent.appendingPathComponent("water_tracker").path)
    }

    @Test func eachRuleReportsItsField() throws {
        let parent = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: parent) }

        #expect(request(name: " ", parent: parent.path).validate().contains { $0.field == .name })
        #expect(request(appID: "nope", parent: parent.path).validate().contains { $0.field == .appID })
        #expect(request(parent: parent.path, platforms: [.android]).validate().contains { $0.field == .platforms })
        #expect(request(parent: parent.appendingPathComponent("missing").path).validate().contains { $0.field == .folder })
    }

    @Test func targetMustBeMissingOrEmpty() throws {
        let parent = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: parent) }
        let target = parent.appendingPathComponent("water_tracker")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data().write(to: target.appendingPathComponent(".DS_Store"))
        #expect(request(parent: parent.path).validate().isEmpty)

        try Data("x".utf8).write(to: target.appendingPathComponent("notes.txt"))
        #expect(request(parent: parent.path).validate().contains { $0.field == .folder && $0.severity == .error })
    }

    @Test func refusesToNestInsideAFlutterProject() throws {
        let outer = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: outer) }
        try Data("name: outer".utf8).write(to: outer.appendingPathComponent("pubspec.yaml"))
        let inner = outer.appendingPathComponent("apps")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        #expect(request(parent: inner.path).validate().contains { $0.field == .folder && $0.severity == .error })
    }

    @Test func warningsComeAfterErrorsAndDoNotMakeTheRequestInvalid() throws {
        let parent = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: parent) }
        let issues = request(name: " ", appID: "com.example.app", parent: parent.path).validate()
        #expect(issues.first?.severity == .error)
        #expect(issues.last?.severity == .warning)
        #expect(request(appID: "com.example.app", parent: parent.path).validate().allSatisfy { $0.severity == .warning })
    }
}

struct FlutterCreateCommandTests {
    private func request(appID: String? = nil, description: String = "", platforms: Set<ProjectPlatform> = [.ios, .android]) -> NewProjectRequest {
        NewProjectRequest(
            displayName: "Water Tracker", packageName: "water_tracker", description: description, appID: appID,
            parentFolder: "/tmp", platforms: platforms, usesGit: false)
    }

    @Test func buildsTheArguments() {
        #expect(FlutterCreateCommand.arguments(for: request()) == [
            "create", "--project-name", "water_tracker", "--org", "com.example", "--platforms", "ios,android",
            "--empty", "water_tracker",
        ])
    }

    @Test func platformsComeInAStableOrder() {
        let args = FlutterCreateCommand.arguments(for: request(platforms: [.linux, .web, .ios, .macos, .android, .windows]))
        #expect(args[6] == "ios,android,web,macos,windows,linux")
    }

    @Test func descriptionStaysOneArgument() {
        let text = "Tracks \"water\" & $HOME's\nglasses; `rm -rf`"
        let args = FlutterCreateCommand.arguments(for: request(description: "  \(text)  "))
        let index = args.firstIndex(of: "--description")
        #expect(index != nil)
        #expect(args[index! + 1] == text)
    }

    @Test func idEndingInThePackageNameUsesOrg() {
        let req = request(appID: "com.leo.water_tracker")
        #expect(FlutterCreateCommand.appIDPlan(for: req) == .org("com.leo"))
        #expect(FlutterCreateCommand.arguments(for: req)[4] == "com.leo")
    }

    @Test func otherIDsAreRewrittenAfterwards() {
        let req = request(appID: "com.leo.watertracker")
        #expect(FlutterCreateCommand.appIDPlan(for: req) == .rewrite(to: "com.leo.watertracker"))
        #expect(FlutterCreateCommand.arguments(for: req)[4] == "com.example")
        #expect(FlutterCreateCommand.appIDPlan(for: request()) == .org("com.example"))
    }
}

struct AppIDWriterTests {
    private let pbxproj = """
    \t\t\tbuildSettings = {
    \t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.example.waterTracker;
    \t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
    \t\t\t};
    \t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.example.waterTracker.RunnerTests;
    \t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = "$(PRODUCT_BUNDLE_IDENTIFIER)";
    """

    @Test func rewritesRunnerAndTestsInXcodeProjects() {
        let out = AppIDWriter.rewriteXcode(pbxproj, to: "com.leo.water")
        #expect(out.contains("PRODUCT_BUNDLE_IDENTIFIER = com.leo.water;"))
        #expect(out.contains("PRODUCT_BUNDLE_IDENTIFIER = com.leo.water.RunnerTests;"))
        #expect(out.contains("PRODUCT_BUNDLE_IDENTIFIER = \"$(PRODUCT_BUNDLE_IDENTIFIER)\";"))
        #expect(!out.contains("com.example"))
        #expect(out.contains("PRODUCT_NAME"))
    }

    @Test func rewritesXcconfigLinesWithoutSemicolon() {
        let out = AppIDWriter.rewriteXcode("PRODUCT_NAME = water\nPRODUCT_BUNDLE_IDENTIFIER = com.example.water\n", to: "com.leo.water")
        #expect(out == "PRODUCT_NAME = water\nPRODUCT_BUNDLE_IDENTIFIER = com.leo.water\n")
    }

    @Test func rewritesBothGradleDialectsButNotTheNamespace() {
        let kts = "android {\n    namespace = \"com.example.water\"\n    defaultConfig {\n        applicationId = \"com.example.water\"\n    }\n}\n"
        let groovy = "android {\n    namespace 'com.example.water'\n    defaultConfig {\n        applicationId 'com.example.water'\n    }\n}\n"
        let outKts = AppIDWriter.rewriteGradle(kts, to: "com.leo.water")
        let outGroovy = AppIDWriter.rewriteGradle(groovy, to: "com.leo.water")
        #expect(outKts.contains("applicationId = \"com.leo.water\""))
        #expect(outKts.contains("namespace = \"com.example.water\""))
        #expect(outGroovy.contains("applicationId 'com.leo.water'"))
        #expect(outGroovy.contains("namespace 'com.example.water'"))
    }

    @Test func isIdempotent() {
        let once = AppIDWriter.rewriteXcode(pbxproj, to: "com.leo.water")
        #expect(AppIDWriter.rewriteXcode(once, to: "com.leo.water") == once)
        let gradle = "applicationId = \"com.example.water\""
        let gradleOnce = AppIDWriter.rewriteGradle(gradle, to: "com.leo.water")
        #expect(AppIDWriter.rewriteGradle(gradleOnce, to: "com.leo.water") == gradleOnce)
    }

    @Test func appliesToFilesOnDiskAndSkipsMissingOnes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gradle = root.appendingPathComponent("android/app/build.gradle.kts")
        try FileManager.default.createDirectory(at: gradle.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("applicationId = \"com.example.water\"".utf8).write(to: gradle)

        let changed = try AppIDWriter.apply("com.leo.water", inProjectAt: root.path)
        #expect(changed == ["android/app/build.gradle.kts"])
        #expect(try String(contentsOf: gradle, encoding: .utf8) == "applicationId = \"com.leo.water\"")
        #expect(try AppIDWriter.apply("com.leo.water", inProjectAt: root.path).isEmpty)
    }
}

struct TemplateRendererTests {
    @Test func fillsPlaceholders() throws {
        let out = try TemplateRenderer.render("title: {{ app_name }} / {{package}}", values: ["app_name": "Water", "package": "water"])
        #expect(out == "title: Water / water")
    }

    @Test func unknownPlaceholderFailsLoudly() {
        #expect(throws: TemplateRenderer.RenderError.unknownPlaceholder("nope")) {
            try TemplateRenderer.render("{{app_name}} {{nope}}", values: ["app_name": "x"])
        }
    }

    @Test func escapesForDartStrings() throws {
        let out = try TemplateRenderer.render("const t = '{{t|dart}}';", values: ["t": "Bob's $5 \\ app\nline"])
        #expect(out == "const t = 'Bob\\'s \\$5 \\\\ app\\nline';")
    }

    @Test func rawInsertionIsNotEscaped() throws {
        #expect(try TemplateRenderer.render("{{t}}", values: ["t": "it's $x"]) == "it's $x")
    }
}

struct StarterTemplateTests {
    private func request(description: String = "It's a $5 app") -> NewProjectRequest {
        NewProjectRequest(
            displayName: "Water's Tracker", packageName: "water_tracker", description: description, appID: nil,
            parentFolder: "/tmp", platforms: [.ios], usesGit: false)
    }

    @Test func bundledStarterRendersWithoutUnknownPlaceholders() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let written = try StarterTemplate.write(values: StarterTemplate.values(for: request()), to: folder.path)

        for file in ["lib/main.dart", "lib/app/router.dart", "lib/app/theme.dart", "lib/features/home/presentation/home_screen.dart",
                     "test/widget_test.dart", "analysis_options.yaml", "ARCHITECTURE.md", "AGENTS.md", "CLAUDE.md"] {
            #expect(written.contains(file), "\(file)")
        }
        let main = try String(contentsOf: folder.appendingPathComponent("lib/main.dart"), encoding: .utf8)
        #expect(main.contains("package:water_tracker/app/app.dart"))
        let home = try String(contentsOf: folder.appendingPathComponent("lib/features/home/presentation/home_screen.dart"), encoding: .utf8)
        #expect(home.contains("Water\\'s Tracker"))
        #expect(home.contains("It\\'s a \\$5 app"))
        #expect(!written.contains { $0.hasSuffix(".tmpl") })
        #expect(!written.joined().contains("{{"))
    }

    @Test func writingTwiceReplacesFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try StarterTemplate.write(values: StarterTemplate.values(for: request()), to: folder.path)
        let second = try StarterTemplate.write(values: StarterTemplate.values(for: request()), to: folder.path)
        #expect(first == second)
    }

    @Test func missingTemplatesFail() {
        #expect(throws: StarterTemplate.WriteError.self) {
            try StarterTemplate.write(values: [:], to: "/tmp", templates: URL(fileURLWithPath: "/nonexistent"))
        }
    }
}

struct CreateStepTests {
    private func request(appID: String?, git: Bool) -> NewProjectRequest {
        NewProjectRequest(
            displayName: "Water", packageName: "water", description: "", appID: appID,
            parentFolder: "/tmp", platforms: [.ios], usesGit: git)
    }

    @Test func skipsStepsTheRequestDoesNotNeed() {
        #expect(CreateStep.steps(for: request(appID: nil, git: false)) == [.flutterCreate, .architecture, .packages])
        #expect(CreateStep.steps(for: request(appID: "com.leo.water", git: true)) == [.flutterCreate, .architecture, .packages, .git])
        #expect(CreateStep.steps(for: request(appID: "com.leo.app", git: true)) == CreateStep.allCases)
    }

    @Test func recognisesOfflineFailures() {
        #expect(NewProjectError.looksOffline("Failed host lookup: 'pub.dev'"))
        #expect(!NewProjectError.looksOffline("version solving failed"))
    }
}

struct NewProjectServiceTests {
    private func gitRepoRequest(parent: URL) -> NewProjectRequest {
        NewProjectRequest(
            displayName: "Water", packageName: "water", description: "", appID: nil,
            parentFolder: parent.path, platforms: [.ios], usesGit: true)
    }

    @Test func tailKeepsTheLastLinesOfOutput() {
        let output = ProcessOutput(status: 1, stdout: "", stderr: (1...10).map { "line \($0)" }.joined(separator: "\n"))
        #expect(NewProjectService.tail(output) == (5...10).map { "line \($0)" }.joined(separator: "\n"))
    }

    @Test func gitStepInitialisesAndStagesInTemporaryFolder() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let request = gitRepoRequest(parent: parent)
        try FileManager.default.createDirectory(atPath: request.path, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: URL(fileURLWithPath: request.path).appendingPathComponent("a.txt"))
        defer { try? FileManager.default.removeItem(at: parent) }

        let service = NewProjectService(log: DiagnosticLog(name: "new-project-tests"))
        let result = try await service.git(request)

        #expect(FileManager.default.fileExists(atPath: request.path + "/.git"))
        let ignore = try String(contentsOfFile: request.path + "/.gitignore", encoding: .utf8)
        #expect(ignore.contains(".DS_Store"))
        // Whether the commit happened depends on the machine's git identity; either way the result says why.
        #expect(result.committed || result.note != nil)
    }
}
