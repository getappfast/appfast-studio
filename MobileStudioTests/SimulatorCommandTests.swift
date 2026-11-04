import Foundation
import Testing
@testable import Mobile_Studio

struct SimulatorCommandTests {
    @Test func parsesCommands() {
        #expect(SimulatorCommand(path: "/screenshot") == .screenshot)
        #expect(SimulatorCommand(path: "/home") == .home)
        #expect(SimulatorCommand(path: "/tap?x=12.5&y=300") == .tap(x: 12.5, y: 300))
        #expect(SimulatorCommand(path: "/swipe?x1=1&y1=2&x2=3&y2=4") == .swipe(fromX: 1, fromY: 2, toX: 3, toY: 4))
    }

    @Test func rejectsBadInput() {
        #expect(SimulatorCommand(path: "/tap?x=1") == nil)
        #expect(SimulatorCommand(path: "/tap?x=abc&y=2") == nil)
        #expect(SimulatorCommand(path: "/tap?x=nan&y=2") == nil)
        #expect(SimulatorCommand(path: "/shell") == nil)
    }

    @Test func normalizesAndClamps() {
        let size = CGSize(width: 400, height: 800)
        #expect(SimulatorCommand.normalized(x: 200, y: 200, in: size) == CGPoint(x: 0.5, y: 0.25))
        #expect(SimulatorCommand.normalized(x: -5, y: 900, in: size) == CGPoint(x: 0, y: 1))
        #expect(SimulatorCommand.normalized(x: 1, y: 1, in: .zero) == nil)
    }

    @Test func describesShellCommands() {
        #expect(SimulatorCommand.activity(forShell: "ms-sim screenshot") == "Looking at the app")
        #expect(SimulatorCommand.activity(forShell: "ms-sim tap 10 20") == "Tapping the app")
        #expect(SimulatorCommand.activity(forShell: "flutter analyze") == nil)
    }

    @Test func agentCallAllowsSimulatorFolder() {
        let call = ClaudeAgentCall(prompt: "hi", maxBudgetUSD: 1, allowedCommands: ["ms-sim *"], readableFolders: ["/tmp/shots"])
        let args = call.arguments
        #expect(args.contains("Bash(ms-sim *)"))
        let add = args.firstIndex(of: "--add-dir")
        #expect(add != nil && args[add! + 1] == "/tmp/shots")
        #expect(args.last == "Bash(ms-sim *)")
    }

    @Test func scriptNamesItsConnectionFile() {
        let script = AgentBridge.script(connectionFile: "/x/connection")
        #expect(script.hasPrefix("#!/bin/sh"))
        #expect(script.contains("conn='/x/connection'"))
    }
}

struct KeyboardMapTests {
    @Test func mapsLettersDigitsAndShift() {
        #expect(KeyboardMap.key(for: "a") == .init(usage: 0x04))
        #expect(KeyboardMap.key(for: "Z") == .init(usage: 0x1D, shift: true))
        #expect(KeyboardMap.key(for: "1") == .init(usage: 0x1E))
        #expect(KeyboardMap.key(for: "0") == .init(usage: 0x27))
        #expect(KeyboardMap.key(for: "@") == .init(usage: 0x1F, shift: true))
        #expect(KeyboardMap.key(for: ".") == .init(usage: 0x37))
        #expect(KeyboardMap.key(for: "?") == .init(usage: 0x38, shift: true))
        #expect(KeyboardMap.key(for: "\n") == KeyboardMap.returnKey)
    }

    @Test func reportsUntypeableCharacters() {
        let result = KeyboardMap.keys(for: "hi é")
        #expect(result.keys.count == 3)
        #expect(result.skipped == ["é"])
    }

    @Test func parsesTypeAndKeyRequests() {
        #expect(SimulatorCommand(path: "/type?text=hello%20world") == .type("hello world"))
        #expect(SimulatorCommand(path: "/type?text=") == nil)
        #expect(SimulatorCommand(path: "/key?name=return") == .key("return"))
        #expect(SimulatorCommand(path: "/key?name=power") == nil)
    }
}

struct PasteCommandTests {
    @Test func parsesHoldAndPaste() {
        #expect(SimulatorCommand(path: "/hold?x=10&y=20") == .hold(x: 10, y: 20))
        #expect(SimulatorCommand(path: "/hold?x=10") == nil)
        #expect(SimulatorCommand(path: "/paste?text=Drink%20water") == .paste("Drink water"))
        #expect(SimulatorCommand(path: "/paste?text=") == nil)
        #expect(SimulatorCommand.activity(forShell: "ms-sim hold 1 2") == "Pressing and holding in the app")
    }
}
