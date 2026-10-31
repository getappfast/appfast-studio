# AGENTS.md

How to work in this repository. This is the canonical guide for any coding agent (Claude Code, Codex, Cursor, …);
`CLAUDE.md` imports it. Keep it accurate: when you change the architecture, a convention or a command, update
this file in the same change.

## What this is

Mobile Studio is a native macOS app (SwiftUI, Swift 6, macOS 14+) for building Flutter apps with a coding agent.
One window shows:

- **Project:** a Flutter folder, checked by Claude (read-only, Haiku), with its git branch and run flavors.
- **Simulator:** a live iOS Simulator screen drawn in-app from CoreSimulator's framebuffer, with click → tap
  and drag → swipe.
- **Run:** `flutter run` / `flutter attach` against the selected simulator, with Hot reload, and *Fix with
  Claude* when a run fails.
- **Chat:** Claude Code running in the project folder as the selected account. *Pick* lets the user tap a
  widget in the running app and attach its source location to the message.

The app shells out to the user's own `claude` CLI, `flutter`, `xcrun simctl` and `git`. It is **not sandboxed**,
on purpose: it has to launch those tools.

## Commands

The Xcode project is **generated** from `project.yml` by [XcodeGen](https://github.com/yonaskolb/XcodeGen).
Never edit `MobileStudio.xcodeproj` by hand. Change `project.yml`, then regenerate.

```bash
xcodegen generate                                   # after adding/removing/moving files or changing settings
xcodebuild -project MobileStudio.xcodeproj -scheme MobileStudio build
xcodebuild -project MobileStudio.xcodeproj -scheme MobileStudio test
```

New Swift files under `MobileStudio/` or `MobileStudioTests/` are picked up by `xcodegen generate`. The build
must have **zero warnings** and the tests must pass before a change is done.

The product is named `Mobile Studio` (with a space), so the Swift module is `Mobile_Studio`:
tests use `@testable import Mobile_Studio`.

## Architecture

Layered, with dependencies pointing down only:

```
App/          Composition root and window wiring       MobileStudioApp, AppDelegate, Workspace, ContentView, StudioModel
Views/        SwiftUI views, layout only               read models, call their methods, never coordinate two models
<Feature>/    @Observable models + services            Project/, Chat/, Simulator/, Inspector/, Accounts/, ClaudeCLI/, Dart/
Core/         Feature-agnostic helpers                 ProcessRunner, DiagnosticLog, ShellEnvironment, Extensions
```

### The pieces

| Kind | Shape | Examples |
|---|---|---|
| **Model** | `@MainActor @Observable final class`, `private(set)` state, intent methods | `FlutterRunModel`, `ChatModel`, `ProjectModel`, `SimulatorModel` |
| **Service** | `Sendable` struct or enum that does I/O and returns values; no UI state | `SimctlService`, `ClaudeCLIService`, `ProjectVerifier`, `RunningAppFinder` |
| **Process wrapper** | Owns one child `Process`, streams its output | `FlutterRunProcess`, `ClaudeStreamProcess`, `ClaudeLoginProcess` |
| **Value / parser** | Pure `Sendable` structs and enums: easy to test | `FlutterOutput`, `ClaudeEvents`, `ClaudeAgentCall`, `FileSnapshot`, `RunFailure` |
| **Coordinator** | Owns the per-window models and the rules between them | `Workspace` |

### Rules

- **`MobileStudioApp` is the composition root.** It creates `StudioModel` (CLI, accounts, models: app-wide,
  also used by Settings) and `Workspace` (everything in the main window) once, and passes them down. Views
  never create models; previews and tests construct them directly.
- **Cross-model rules live in `Workspace`.** "The folder changed, so stop the run, cancel Pick and load that
  folder's chat" is a `Workspace` method. `ContentView` only forwards `onChange` events to it. If you find
  yourself writing `modelA.x(); modelB.y()` in a view, move it to `Workspace`.
- **State is an enum, not a pile of booleans.** Each model exposes a phase (`RunPhase`, `FixPhase`,
  `VerificationState`, `SimulatorPhase`, `PickModel.Phase`, …) and views `switch` over it. Add a case rather
  than another flag.
- **Models own their tasks.** Long work runs in a `Task` stored on the model, so it can be cancelled. Results
  that arrive after the context changed (another folder, a newer request) are dropped: check
  `Task.isCancelled`, a generation counter, or that `path` is still the same before writing state.
- **Concurrency is Swift 6 strict.** Models are `@MainActor`. Services and values are `Sendable`. Blocking work
  (process I/O, hashing a project) runs off the main actor, e.g. `ProcessRunner`, `FileSnapshot.taken(of:)`.
  `@unchecked Sendable` is only for the process wrappers that guard their own state with a lock, and needs a
  comment saying why.
- **Everything that runs Claude starts from `StudioModel.claude`** (`ClaudeAccess?`: CLI path and the
  environment that selects the account). It is nil until the CLI is installed and the active account is
  signed in. Gate UI on it rather than re-deriving that.
- **The Objective-C bridge is isolated.** `Simulator/MSSimulatorDisplay.{h,m}` is the only code that touches
  private CoreSimulator/SimulatorKit API. It reports every failure as `NSError`, never crashes, and is reached
  only through `SimulatorModel`.

## Running Claude safely

Mobile Studio runs an agent with edit rights on the user's code, so these are hard rules:

- Build editing calls with **`ClaudeAgentCall`**. It always adds `--safe-mode` (no machine plugins, skills,
  MCP servers, hooks), `--permission-mode acceptEdits`, the tool list, and a budget. Don't hand-roll argument
  arrays for agent calls.
- Shell access is **allow-listed per command** (`allowedCommands`, e.g. `"flutter pub *"`). Add the narrowest
  pattern that works. Never allow `flutter run` (it doesn't exit and the app owns it), `rm`, or git commands
  that write.
- Every call has a **`maxBudgetUSD`** and a timeout. The read-only project check (`ProjectVerifier`) uses
  Haiku with Read/Glob/Grep only.
- "Files changed" comes from **`FileSnapshot`** (before/after hashes of the folder), never from Claude's own
  account of what it did.
- Launch agent processes with **`ClaudeAccess.agentProcess`**, which adds the user's terminal `PATH`. A
  Finder-launched app has a minimal one, so Claude's shell would not find flutter, dart or pod.

## Conventions

- **Comments say why, not what.** One line above the declaration (`///` for API), written as a plain
  sentence. Match the density of the surrounding code: most methods have none, non-obvious ones have one.
- **UI copy is plain English and says what to do next**: "Boot iPhone 16 first.", not "Device not ready".
  A disabled control gets a reason the user can read nearby (see `RunBar.blocker`).
- **Icon-only buttons** use `Label(title, systemImage:).labelStyle(.iconOnly)`, so VoiceOver reads the title,
  plus `.help(...)`.
- **Reuse the shared views** in `Views/Components.swift`: `SectionCard` (titled box), `StatusLine`, `Field`,
  `CommandHint`, and `FileSnapshot.Change.Kind.badge` / `.tint`.
- **Persistence:** small state goes in `UserDefaults` through `setEncoded(_:forKey:)` /
  `decoded(_:forKey:)`, with a versioned key (`run.failure.v1`). Change the shape, bump the version. Chat
  transcripts live in `~/Library/Application Support/Mobile Studio/Chats/`.
- **Diagnostics:** each feature appends to a `DiagnosticLog` (`~/Library/Logs/Mobile Studio/<name>.log`): the
  exact command, exit status and output. Expose it with `log.reveal()` ("Show log"). Log enough to debug a
  user's failure without a repro.
- **Errors:** services throw (`ClaudeCLIError`, `NSError` from the bridge). Models catch at the boundary and
  turn the error into a phase case with a message the user can read.
- Shared helpers such as `String.nonEmpty` live in `Core/Extensions.swift`. Don't redeclare private copies.

## Tests

- [Swift Testing](https://developer.apple.com/documentation/testing) (`import Testing`, `@Test`, `#expect`) in
  `MobileStudioTests/`.
- Test the pure layer: parsers, argument builders, snapshots, persistence helpers. When logic in a model gets
  interesting, pull it into a value type (as `FlutterOutput` was pulled out of `FlutterRunModel`) and test that.
- Tests must not need a simulator, network, Flutter or the claude CLI. Use temp directories and a throwaway
  `UserDefaults(suiteName:)`.

## Before you say it's done

1. `xcodegen generate` if files moved or were added.
2. Build with zero warnings, and `test` passes.
3. For UI changes, run the app and look at the screen you changed, in light and dark mode.
4. Update this file if you changed a rule, a layer or a command.
