import Foundation
import Testing
@testable import Mobile_Studio

struct FlutterOutputTests {
    @Test func splitsChunksIntoLinesAndKeepsThePartialOne() {
        var output = FlutterOutput()
        output.append("Launching lib/main.dart\nRunning Xcode bu")
        output.append("ild...\n")
        #expect(output.lines == ["Launching lib/main.dart", "Running Xcode build..."])
        #expect(output.partial.isEmpty)

        output.append("Xcode build done.")
        #expect(output.partial == "Xcode build done.")
        #expect(output.tail(2) == ["Running Xcode build...", "Xcode build done."])
    }

    @Test func keepsWhatAProgressLineEndsUpShowing() {
        var output = FlutterOutput()
        output.append("Building  10%\rBuilding  60%\rBuilding 100%\n")
        #expect(output.lines == ["Building 100%"])
    }

    @Test func stripsTerminalColours() {
        var output = FlutterOutput()
        output.append("\u{1B}[1m\u{1B}[31mError:\u{1B}[0m boom\n")
        #expect(output.lines == ["Error: boom"])
    }

    @Test func findsTheServiceURLAndLaunch() {
        var output = FlutterOutput()
        output.append("Syncing files to device iPhone 16...\n")
        #expect(output.isLaunched)
        #expect(output.serviceURL == nil)

        output.append("A Dart VM Service on iPhone 16 is available at: http://127.0.0.1:50123/abcd=/\n")
        #expect(output.serviceURL == URL(string: "http://127.0.0.1:50123/abcd=/"))
    }

    @Test func capsTheLinesItKeeps() {
        var output = FlutterOutput()
        output.maxLines = 3
        output.append("1\n2\n3\n4\n5\n")
        #expect(output.lines == ["3", "4", "5"])
    }

    @Test func closeFinishesThePartialLine() {
        var output = FlutterOutput()
        output.append("last words")
        output.close()
        #expect(output.lines == ["last words"])
        #expect(output.partial.isEmpty)
    }

    @Test func failureReasonPrefersTheBuildCause() {
        var output = FlutterOutput()
        output.append("Failed to build iOS app\nlib/main.dart:3:1: Error: Expected ';'\nError launching application\n")
        #expect(output.failureReason(status: 1) == "Failed to build iOS app: lib/main.dart:3:1: Error: Expected ';'")
    }

    @Test func failureReasonFindsTheDartErrorBelowXcodesHeadings() {
        var output = FlutterOutput()
        output.append("""
        Failed to build iOS app
        Error output from Xcode build:
        ↳
        ** BUILD FAILED **
        Xcode's output:
        lib/main.dart:124:30: Error: A value of type 'String' can't be assigned to a variable of type 'int'.
        Error launching application on iPhone 17 Pro.

        """)
        #expect(output.failureReason(status: 1)
                == "Failed to build iOS app: lib/main.dart:124:30: Error: A value of type 'String' can't be assigned to a variable of type 'int'.")
    }

    @Test func failureReasonSkipsHeadingsAfterTheBuildFailure() {
        var output = FlutterOutput()
        output.append("Failed to build iOS app\nError output from Xcode build:\n↳\nSigning for \"Runner\" requires a team.\n")
        #expect(output.failureReason(status: 1) == "Failed to build iOS app: Signing for \"Runner\" requires a team.")
    }

    @Test func failureReasonFallsBackToTheLastErrorLikeLine() {
        var output = FlutterOutput()
        output.append("Resolving dependencies...\nNo devices found\nBye\n")
        #expect(output.failureReason(status: 1) == "No devices found")
        #expect(FlutterOutput().failureReason(status: 7) == "flutter run exited with status 7.")
    }
}
