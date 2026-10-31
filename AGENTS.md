# AGENTS.md

How to work in this repository. This is the canonical guide for any coding agent (Claude Code, Codex, Cursor, …);
`CLAUDE.md` imports it. Keep it accurate: when you change the architecture, a convention or a command, update
this file in the same change.

## What this is

Mobile Studio is a native macOS app (SwiftUI, Swift 6, macOS 14+) for building Flutter apps with a coding agent.
One window shows:

- **Toolbar** (like Xcode's): Run/Stop, the destination simulator menu, an activity line, **Point at…**
  (Pick), and toggles for the build log and the chat. Every action is also in the Product/View menus with a
  shortcut (⌘R, ⌘., ⇧⌘R hot reload, ⇧⌘E, ⇧⌘Y, ⌥⌘0).
- **Sidebar:** a setup checklist until everything is ready, then the project (a health badge opens a popover
  with issues, the run flavor and Claude's project check), **Screens** (found in the source; clicking one starts
  a chat message about it) and **History** (every change Claude made, undoable, each file opening a git diff).
- **Canvas:** a live iOS Simulator screen drawn in-app from CoreSimulator's framebuffer (click → tap,
  drag → swipe). One banner above it for what matters now (run failed → *Fix with Claude*, an app already
  running → Reconnect, a fix in progress), and a build log drawer under it.
- **Chat inspector:** Claude Code running in the project folder as the selected account. Answers lead with
  the outcome in plain words; technical notes and steps sit behind a disclosure. Each answer that changed
  files has **Undo**. *Fix with Claude* runs appear here as messages too. *Point at…* attaches a widget
  tapped in the running app, with a picture of it.
- **The loop it's built around:** ask → see → undo. After Claude edits, the running app reloads on its own
  (`Workspace.applyEdits`: hot reload, a hot restart for start-up code, or a "Run Again" toast for packages
  and native settings), and every turn saves a checkpoint (`CheckpointStore`) so it can be undone.

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
- **Actions and their availability live in `Workspace` too:** `runApp()`, `stopApp()`, `fixFailure()`, … with
  `canRun`, `runBlocker`, `chatBlocker`, `activity`. The toolbar, the menu commands (`StudioCommands`) and
  the banners all call these, so they can't disagree. A new action gets a method and a `can…`/`…Blocker`
  there first, then UI.
- **Window state** that commands need (chat and log visibility, the diff sheet) is on `Workspace`, not in
  `@State`.
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
- **Write for people who don't read code.** Name files with `FriendlyName` ("Home screen · edited"), keep
  paths as secondary text or help, and keep the chat system prompt's two-part answer rule (outcome, `---`,
  technical notes; split by `AnswerParts`).
- **Undo must never lose the user's work.** `CheckpointStore.restore` checks every file first and changes
  nothing if one was edited since. Anything else that edits the project should save a checkpoint too.
- **Status never relies on colour alone:** use `StatusBadge` / `StatusTone` (a symbol and a colour), not dots.
- **Reuse the shared views** in `Views/Components.swift`: `StatusBadge`, `Banner`, `CommandHint`,
  `FileChangeRow`; in Settings, `SettingsHeader` and `MonospacedValue`. Settings is `Form` +
  `.formStyle(.grouped)` with `LabeledContent`; empty and error states use `ContentUnavailableView`.
- **Respect Reduce Motion** for any animation (`@Environment(\.accessibilityReduceMotion)`).
- **Persistence:** small state goes in `UserDefaults` through `setEncoded(_:forKey:)` /
  `decoded(_:forKey:)`, with a versioned key (`run.failure.v1`). Change the shape, bump the version. Chat
  transcripts live in `~/Library/Application Support/Mobile Studio/Chats/`.
- **Diagnostics:** each feature appends to a `DiagnosticLog` (`~/Library/Logs/Mobile Studio/<name>.log`): the
  exact command, exit status and output. Expose it with `log.reveal()` ("Show log"). Log enough to debug a
  user's failure without a repro.
- **Errors:** services throw (`ClaudeCLIError`, `NSError` from the bridge). Models catch at the boundary and
  turn the error into a phase case with a message the user can read.
- Shared helpers such as `String.nonEmpty` live in `Core/Extensions.swift`. Don't redeclare private copies.

## Layout pitfalls (macOS 26)

- The toolbar overflows into a `>>` menu when its items get too wide. Only Point at… has a text label; keep
  new items icon-only, and check the toolbar in a snapshot after adding one.

- The sidebar floats over the detail column, and the detail column reserves the sidebar's width as an inset.
  A minimum width on detail content is therefore paid twice, and with the chat inspector open it pushed the
  whole split view wider than the window (the sidebar started off-screen). This includes rows whose content
  can't shrink, like the device footer: it uses `ViewThatFits` to drop to icons. Don't give detail content a
  minimum width; check `-main.txt` from a `MOBILE_STUDIO_SNAPSHOT_TREE=1` run after layout changes.

## Seeing the UI

Debug builds can save PNGs of their own windows. This needs no screen-recording permission, and the run
skips Claude's automatic project check, so it costs nothing:

```bash
MOBILE_STUDIO_SNAPSHOT=/tmp/shot MOBILE_STUDIO_APPEARANCE=dark MOBILE_STUDIO_SNAPSHOT_SETTINGS=1 \
  "<DerivedData>/Build/Products/Debug/Mobile Studio.app/Contents/MacOS/Mobile Studio"
```

It writes `/tmp/shot-main.png` (and `-settings.png`), then quits. `MOBILE_STUDIO_SNAPSHOT_LOG=1` opens the build
log and `MOBILE_STUDIO_SNAPSHOT_TREE=1` also writes the view hierarchy with frames, which is how the layout bug
above was found. `MOBILE_STUDIO_SNAPSHOT_RUN=1` presses Run (a real `flutter run`) and
`MOBILE_STUDIO_SNAPSHOT_TIMES=20,120` captures at each of those seconds, to follow a build through. Point it at a
throwaway project with `-project.path.v1 /path/to/app`, never at the user's own. To check Fix with Claude without
spending anything, add `MOBILE_STUDIO_SNAPSHOT_FIX=1` (or `MOBILE_STUDIO_SNAPSHOT_CHAT="…"` with `MOBILE_STUDIO_SNAPSHOT_UNDO_AFTER=20`
for the ask → reload → undo loop) and point `MOBILE_STUDIO_CLAUDE_CLI` at a stand-in script that
answers `--version` and `auth status`, prints stream-json, and makes the fix. Launch arguments override saved settings for that run only, e.g.
`-window.chatVisible.v1 '<false/>'`. Glass toolbar platters and AppKit-hosted list rows don't draw in these
captures; everything else does. See `Snapshot` in `App/AppDelegate.swift`.

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
3. For UI changes, look at the screen you changed in light and dark mode (snapshot it, see above).
4. Update this file if you changed a rule, a layer or a command.
