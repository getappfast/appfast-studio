import Foundation

/// A place in the user's source: the widget that was picked, or one of the widgets around it.
struct WidgetPlace: Equatable, Sendable {
    let type: String
    let file: String
    let line: Int
    let column: Int

    var location: String { "\(file):\(line):\(column)" }
}

/// A widget the user tapped in the running app, with what is needed to point Claude at its code.
struct PickedWidget: Equatable, Sendable, Identifiable {
    let id = UUID()
    var place: WidgetPlace
    /// Notable properties, e.g. a Text's string.
    var details: [String]
    /// "307×20", in points.
    var size: String?
    /// The user's own widgets around this one, nearest first.
    var ancestors: [WidgetPlace]

    var label: String { "\(place.type) · \(place.file):\(place.line)" }

    /// One line for the prompt.
    var promptLine: String {
        var line = "- \(place.type) at \(place.location)"
        if let size { line += " (\(size) pt)" }
        if !details.isEmpty { line += ", " + details.joined(separator: ", ") }
        if !ancestors.isEmpty {
            line += "; inside " + ancestors.prefix(4).map { "\($0.type) at \($0.location)" }.joined(separator: " > ")
        }
        return line
    }
}

/// Talks to a debug Flutter app's VM service (the address `flutter run` prints) to use the widget inspector:
/// turn on select mode, and read back which widget a tap in the app selected.
actor InspectorClient {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let task: URLSessionWebSocketTask
    private var nextID = 0
    private var waiters: [Int: CheckedContinuation<Data, Error>] = [:]
    private var isolateID: String?
    private var closed = false
    /// What the inspector selected before the user tapped, so a change means a tap happened.
    private var sentinel: String?

    private let group = "mobile-studio-pick"

    init(serviceURL: URL) {
        var parts = URLComponents(url: serviceURL, resolvingAgainstBaseURL: false)!
        parts.scheme = "ws"
        parts.path += parts.path.hasSuffix("/") ? "ws" : "/ws"
        task = URLSession.shared.webSocketTask(with: parts.url!)
        // The parent chain of a widget in a real app is several megabytes; the default limit is 1 MB.
        task.maximumMessageSize = 64 * 1024 * 1024
    }

    // MARK: Connection

    func connect() async throws {
        task.resume()
        Task { await receiveLoop() }
        let vm = try object(await rpc("getVM", [:]))
        let isolates = vm["isolates"] as? [[String: Any]] ?? []
        guard let isolate = isolates.first(where: { $0["name"] as? String == "main" }) ?? isolates.first,
              let id = isolate["id"] as? String else { throw Failure(message: "The app has no running isolate.") }
        isolateID = id
    }

    func close() {
        guard !closed else { return }
        closed = true
        task.cancel(with: .goingAway, reason: nil)
        fail(Failure(message: "Disconnected from the app."))
    }

    // MARK: Picking

    /// Turns on select mode in the app: taps now select widgets instead of pressing them.
    func beginPicking() async throws {
        // Select a widget no tap can reach (the app root), so any later selection is the user's.
        let tree = try object(await ext("getRootWidgetSummaryTree", ["objectGroup": group]))
        if let root = tree["result"] as? [String: Any],
           let first = (root["children"] as? [[String: Any]])?.first, let id = first["valueId"] as? String {
            _ = try await ext("setSelectionById", ["arg": id, "objectGroup": group])
            sentinel = signature(of: try await selectedNode())
        }
        _ = try await ext("show", ["enabled": "true"])
    }

    func endPicking() async {
        _ = try? await ext("show", ["enabled": "false"])
        _ = try? await ext("disposeGroup", ["objectGroup": group])
    }

    /// The widget the user tapped, once they have.
    func pickedWidget(projectFolder: String) async throws -> PickedWidget? {
        guard let node = try await selectedNode(), signature(of: node) != sentinel,
              let place = place(of: node, folder: projectFolder), let valueID = node["valueId"] as? String else { return nil }

        var details: [String] = []
        if let props = (try? object(await ext("getProperties", ["arg": valueID, "objectGroup": group])))?["result"] as? [[String: Any]] {
            for prop in props {
                guard let name = prop["name"] as? String, !["depth", "widget", "key", "dirty", "dependencies", "state", "renderObject"].contains(name),
                      let text = prop["description"] as? String, text != "null" else { continue }
                details.append("\(name)=\(text.count > 80 ? String(text.prefix(80)) + "…" : text)")
                if details.count == 3 { break }
            }
        }

        var size: String?
        if let layout = (try? object(await ext("getLayoutExplorerNode", ["id": valueID, "groupName": group, "subtreeDepth": "0"])))?["result"] as? [String: Any],
           let box = layout["size"] as? [String: Any],
           let width = Double(box["width"] as? String ?? ""), let height = Double(box["height"] as? String ?? "") {
            size = "\(Int(width.rounded()))×\(Int(height.rounded()))"
        }

        var ancestors: [WidgetPlace] = []
        if let chain = (try? object(await ext("getParentChain", ["arg": valueID, "objectGroup": group])))?["result"] as? [[String: Any]] {
            // The chain runs from the root down to the widget. Keep the user's own widgets, nearest first.
            for entry in chain.dropLast().reversed() {
                guard let parent = entry["node"] as? [String: Any], parent["createdByLocalProject"] as? Bool == true,
                      let parentPlace = self.place(of: parent, folder: projectFolder), parentPlace != place else { continue }
                ancestors.append(parentPlace)
                if ancestors.count == 8 { break }
            }
        }
        return PickedWidget(place: place, details: details, size: size, ancestors: ancestors)
    }

    // MARK: Inspector calls

    private func selectedNode() async throws -> [String: Any]? {
        let reply = try object(await ext("getSelectedSummaryWidget", ["objectGroup": group]))
        return reply["result"] as? [String: Any]
    }

    private func signature(of node: [String: Any]?) -> String? {
        guard let node, let location = node["creationLocation"] as? [String: Any] else { return nil }
        return "\(node["description"] as? String ?? "")|\(location["file"] as? String ?? "")|\(location["line"] ?? 0)|\(location["column"] ?? 0)"
    }

    private func place(of node: [String: Any], folder: String) -> WidgetPlace? {
        guard let location = node["creationLocation"] as? [String: Any], let file = location["file"] as? String,
              let line = location["line"] as? Int, let column = location["column"] as? Int else { return nil }
        let path = file.hasPrefix("file://") ? String(file.dropFirst("file://".count)).removingPercentEncoding ?? file : file
        let relative = path.hasPrefix(folder + "/") ? String(path.dropFirst(folder.count + 1)) : path
        return WidgetPlace(type: node["description"] as? String ?? "Widget", file: relative, line: line, column: column)
    }

    private func ext(_ name: String, _ arguments: [String: String]) async throws -> Data {
        guard let isolateID else { throw Failure(message: "Not connected to the app.") }
        return try await rpc("ext.flutter.inspector.\(name)", arguments.merging(["isolateId": isolateID]) { current, _ in current })
    }

    private func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(message: "The app sent an unexpected reply.")
        }
        return value
    }

    // MARK: JSON-RPC

    private func rpc(_ method: String, _ params: [String: String]) async throws -> Data {
        guard !closed else { throw Failure(message: "Disconnected from the app.") }
        nextID += 1
        let id = nextID
        let payload = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params] as [String: Any])
        return try await withCheckedThrowingContinuation { continuation in
            waiters[id] = continuation
            task.send(.string(String(decoding: payload, as: UTF8.self))) { [weak self] error in
                if let error { Task { await self?.fail(id: id, Failure(message: error.localizedDescription)) } }
            }
            Task {
                try? await Task.sleep(for: .seconds(15))
                self.fail(id: id, Failure(message: "The app did not answer in time."))
            }
        }
    }

    private func receiveLoop() async {
        while !closed {
            do {
                let message = try await task.receive()
                switch message {
                case .string(let text): handle(Data(text.utf8))
                case .data(let data): handle(data)
                @unknown default: break
                }
            } catch {
                if !closed { closed = true; fail(Failure(message: "Lost the connection to the app.")) }
                return
            }
        }
    }

    private func handle(_ data: Data) {
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = message["id"] as? Int,
              let waiter = waiters.removeValue(forKey: id) else { return }
        if let error = message["error"] as? [String: Any] {
            waiter.resume(throwing: Failure(message: error["message"] as? String ?? "The app returned an error."))
        } else if let result = message["result"], let encoded = try? JSONSerialization.data(withJSONObject: result) {
            waiter.resume(returning: encoded)
        } else {
            waiter.resume(returning: Data("{}".utf8))
        }
    }

    private func fail(id: Int, _ error: Failure) {
        waiters.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func fail(_ error: Failure) {
        let pending = waiters
        waiters = [:]
        pending.values.forEach { $0.resume(throwing: error) }
    }
}
