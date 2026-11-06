import CoreImage
import Foundation
import Network

/// Lets the in-app agent see and touch the running simulator. The agent runs with no MCP servers, so the app
/// listens on the loopback interface and installs a tiny `ms-sim` script that talks to it with curl; the agent
/// runs the script like any allow-listed command and reads the screenshots it saves with its Read tool.
/// Only this Mac can connect, and only with the token written next to the script.
@MainActor
final class AgentBridge {
    /// Does one command and answers in plain text for the agent. Set by `Workspace`, which owns the simulator.
    var handler: (@MainActor (SimulatorCommand) async -> String)?

    nonisolated static let log = DiagnosticLog(name: "agent-bridge")

    /// Holds `ms-sim`; added to the agent's PATH.
    nonisolated static var binDirectory: URL { ProjectStorage.root.appendingPathComponent("Agent/bin") }
    /// Where screenshots are saved. The agent is allowed to read here and nowhere else outside the project.
    nonisolated static var screenshotDirectory: URL { ProjectStorage.root.appendingPathComponent("Agent/Screenshots") }
    private nonisolated static var connectionFile: URL { ProjectStorage.root.appendingPathComponent("Agent/connection") }

    private var listener: NWListener?
    private let token = UUID().uuidString

    func start() {
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .loopback
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] state in
                guard case .ready = state, let port = listener.port?.rawValue else { return }
                Task { @MainActor in self?.install(port: port) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .global())
                Self.receive(on: connection, buffer: Data()) { path, sent in
                    Task { @MainActor in
                        let body = await self?.answer(path: path, sentToken: sent) ?? "The app is closing."
                        Self.reply(body, on: connection)
                    }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            Self.log.append("Could not listen: \(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        try? FileManager.default.removeItem(at: Self.connectionFile)
    }

    private func answer(path: String, sentToken: String?) async -> String {
        guard sentToken == token else { return "Not allowed." }
        guard let command = SimulatorCommand(path: path) else { return "Unknown command. Try: ms-sim help" }
        let result = await handler?(command) ?? "The simulator isn't available."
        Self.log.append("\(path)\n→ \(result)")
        return result
    }

    // MARK: Installing the script

    private func install(port: UInt16) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: Self.binDirectory, withIntermediateDirectories: true)
            try fm.createDirectory(at: Self.screenshotDirectory, withIntermediateDirectories: true)
            // Screenshots of the user's app don't pile up across launches.
            for old in (try? fm.contentsOfDirectory(at: Self.screenshotDirectory, includingPropertiesForKeys: nil)) ?? [] {
                try? fm.removeItem(at: old)
            }
            try "\(port)\n\(token)\n".write(to: Self.connectionFile, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.connectionFile.path)
            let script = Self.binDirectory.appendingPathComponent("ms-sim")
            try Self.script(connectionFile: Self.connectionFile.path).write(to: script, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        } catch {
            Self.log.append("Could not install ms-sim: \(error.localizedDescription)")
        }
    }

    nonisolated static func script(connectionFile: String) -> String {
        """
        #!/bin/sh
        # Installed by AppFast Studio. Sees and touches the simulator it is showing.
        conn='\(connectionFile)'
        [ -r "$conn" ] || { echo "AppFast Studio isn't running."; exit 1; }
        port=$(sed -n 1p "$conn"); token=$(sed -n 2p "$conn")
        ask() { curl -s --max-time 30 -H "X-Token: $token" "http://127.0.0.1:$port$1"; echo; }
        ask_text() { curl -s --max-time 60 -G -H "X-Token: $token" --data-urlencode "$2" "http://127.0.0.1:$port$1"; echo; }
        case "$1" in
          screenshot) ask /screenshot ;;
          tap) ask "/tap?x=$2&y=$3" ;;
          swipe) ask "/swipe?x1=$2&y1=$3&x2=$4&y2=$5" ;;
          home) ask /home ;;
          type) shift; ask_text "/type" "text=$*" ;;
          key) ask "/key?name=$2" ;;
          hold) ask "/hold?x=$2&y=$3" ;;
          paste) shift; ask_text "/paste" "text=$*" ;;
          *) cat <<'EOF'
        ms-sim screenshot            save the screen as a PNG and print its path (read it to see the app)
        ms-sim tap X Y               tap at pixel X,Y of the latest screenshot
        ms-sim swipe X1 Y1 X2 Y2     drag from one point to another (scrolling, going back)
        ms-sim type TEXT             type into the focused text field (tap the field first)
        ms-sim key NAME              press return, delete, tab or escape
        ms-sim hold X Y              press and hold at pixel X,Y (opens the Paste menu on a text field)
        ms-sim paste TEXT            put TEXT on the clipboard; then hold the field and tap Paste
        ms-sim home                  press the Home button
        EOF
          ;;
        esac
        """
    }

    // MARK: Minimal HTTP

    /// Reads until the request headers are complete, then reports the path and a check for the token.
    private nonisolated static func receive(on connection: NWConnection, buffer: Data, done: @escaping @Sendable (String, String?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            let text = String(decoding: buffer, as: UTF8.self)
            if text.contains("\r\n\r\n") {
                let lines = text.components(separatedBy: "\r\n")
                let path = lines[0].split(separator: " ").dropFirst().first.map(String.init) ?? ""
                let sent = lines.first { $0.lowercased().hasPrefix("x-token:") }?
                    .dropFirst("x-token:".count).trimmingCharacters(in: .whitespaces)
                done(path, sent)
            } else if isComplete || error != nil || buffer.count > 16_000 {
                connection.cancel()
            } else {
                receive(on: connection, buffer: buffer, done: done)
            }
        }
    }

    private nonisolated static func reply(_ body: String, on connection: NWConnection) {
        let payload = Data(body.utf8)
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in connection.cancel() })
    }
}
