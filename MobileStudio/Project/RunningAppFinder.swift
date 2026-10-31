import Foundation

/// A debug build of the project that is already running in a simulator, started by an earlier run of this app
/// or by a terminal. Found from the simulator itself, so it works even though nothing here owns it any more.
struct RunningApp: Equatable, Sendable {
    let bundleID: String
    let deviceID: String
    /// The app's VM service address, which `flutter attach` and the widget inspector connect to.
    let serviceURL: URL
}

enum RunningAppFinder {
    /// The iOS bundle identifier of the project's app, read from the Xcode project.
    static func bundleID(ofProjectAt folder: String) -> String? {
        let path = (folder as NSString).appendingPathComponent("ios/Runner.xcodeproj/project.pbxproj")
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var counts: [String: Int] = [:]
        for match in text.matches(of: /PRODUCT_BUNDLE_IDENTIFIER = ([^;]+);/) {
            let id = String(match.1).trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            // Test targets share the setting; build variables (flavors) can't be resolved without Xcode.
            guard !id.contains("Tests"), !id.contains("$(") else { continue }
            counts[id, default: 0] += 1
        }
        return counts.max { $0.value < $1.value }?.key
    }

    /// The project's app if it is running on that simulator and still has a debug session to attach to.
    static func find(folder: String, deviceID: String) async -> RunningApp? {
        guard let bundleID = bundleID(ofProjectAt: folder) else { return nil }
        let runner = ProcessRunner(timeout: 20)

        // Simulator apps are processes on this Mac. Ask the simulator which one is the project's app.
        guard let list = try? await runner.run("/usr/bin/xcrun", ["simctl", "spawn", deviceID, "launchctl", "list"]), list.status == 0,
              let pid = processID(of: bundleID, in: list.stdout) else { return nil }

        // At startup a debug Flutter app logs the address of its VM service. That log line is the only
        // trace of the address once the tool that started the app is gone.
        let predicate = "processIdentifier == \(pid) AND eventMessage CONTAINS \"Dart VM service\""
        guard let log = try? await runner.run("/usr/bin/xcrun", [
            "simctl", "spawn", deviceID, "log", "show", "--last", "2d", "--info", "--debug", "--style", "compact", "--predicate", predicate,
        ]), log.status == 0, let url = lastServiceURL(in: log.stdout) else { return nil }
        return RunningApp(bundleID: bundleID, deviceID: deviceID, serviceURL: url)
    }

    /// Brings the running app to the front. iOS suspends a backgrounded app, and its debug service lives inside
    /// that process, so nothing can connect until the app is active again. Launching an app that is already
    /// running only activates it; it is not restarted.
    static func foreground(bundleID: String, deviceID: String) async {
        _ = try? await ProcessRunner(timeout: 20).run("/usr/bin/xcrun", ["simctl", "launch", deviceID, bundleID])
    }

    /// Waits until the app's debug service answers, which it does not while the app is suspended.
    static func waitUntilResponsive(_ url: URL, timeout: TimeInterval) async -> Bool {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        let session = URLSession(configuration: configuration)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? await session.data(from: url)) != nil { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    /// Ends the app on the simulator. A tool still attached to it notices and exits by itself.
    static func terminate(_ app: RunningApp) async {
        _ = try? await ProcessRunner(timeout: 20).run("/usr/bin/xcrun", ["simctl", "terminate", app.deviceID, app.bundleID])
    }

    // MARK: Parsing

    /// `launchctl list` lines are "<pid or ->\t<status>\tUIKitApplication:<bundle id>[…]".
    static func processID(of bundleID: String, in listing: String) -> Int? {
        for line in listing.split(whereSeparator: \.isNewline) where line.contains("UIKitApplication:\(bundleID)[") {
            if let pid = Int(line.split(whereSeparator: { $0 == "\t" || $0 == " " }).first ?? "") { return pid }
        }
        return nil
    }

    static func lastServiceURL(in log: String) -> URL? {
        log.matches(of: /http:\/\/127\.0\.0\.1:\d+\/[^\s]*/).last.flatMap { URL(string: String($0.0)) }
    }
}
