# AGENTS.md

How to work in this repository. This is the canonical guide for any coding agent (Claude Code, Codex, Cursor, …);
`CLAUDE.md` imports it. Keep it accurate: when you change the architecture, a convention or a command, update
this file in the same change.

## What this is

Mobile Studio is a native macOS app (SwiftUI, Swift 6, macOS 14+) for building Flutter apps with a coding agent.
One window shows:

- **Toolbar** (like Xcode's): Run/Stop, the destination simulator menu, an activity line, **Point at…**
  (Pick), a Device / App Flow switch for the canvas, and toggles for the build log and the chat. Every action is
  also in the Product/View menus with a shortcut (⌘R, ⌘., ⇧⌘R hot reload, ⌥⇧⌘R hot restart, ⇧⌘E, ⌘1/⌘2, ⇧⌘Y, ⌥⌘0).
- **Sidebar:** a setup checklist until everything is ready, then the project (a health badge opens a popover
  with issues, the run flavor and Claude's project check), **Screens** (found in the source; clicking one starts
  a chat message about it) and **History** (every change Claude made, undoable, each file opening a git diff).
- **Canvas:** a live iOS Simulator screen drawn in-app from CoreSimulator's framebuffer (click → tap,
  drag → swipe). One banner above it for what matters now (run failed → *Fix with Claude*, an app already
  running → Reconnect, a fix in progress), and a build log drawer under it. **App Flow** swaps the device for a
  map of the screens (`FlowCanvas`): `FlowFinder` reads the Dart source for navigation (Navigator, named routes,
  go_router, auto_route, tabs) into an `AppFlow`, drawn left to right from the start screen. A map that would be taller than wide has
  its long columns wrapped into lanes side by side until it is about 4:3 (`FlowGeometry`), so fitting it isn't a thin
  strip. It stays fresh like the Screens list. The map is a pan/zoom viewport, not a scroll view: `FlowMapModel`
  (owned by `Workspace.flowMap`) holds a `FlowViewport` (scale 10-300 %, and where the map's corner is; all the maths,
  clamping and fitting is pure and tested). Two-finger scroll, the wheel and dragging empty canvas pan; a pinch,
  ⌘/⌥-scroll or a two-finger double tap zoom around the pointer (`FlowInput` takes those from a local `NSEvent`
  monitor, because SwiftUI can't see scroll or pinch position on macOS 14); the zoom pill (`FlowZoomControls`) and
  View ▸ Zoom In/Out/Actual Size/Zoom to Fit (⌘+ ⌘- ⌘0 ⌘9, plus ⌘=) do the same. A map that fits at 50 % or more
  opens fitted and follows the window until the user zooms or pans; a bigger one opens at 50 % on its start screen.
  The model only changes when asked, and views read `viewport` only in `FlowSurface`, `FlowGrid` and the controls, so
  a pan doesn't rebuild the cards. The device view stays underneath, hidden, because removing it stops the display stream.
  The device sits in its real hardware frame (`DeviceChrome`), read at runtime from the files Xcode installs
  in `/Library/Developer/DeviceKit/Chrome`; nothing of Apple's is bundled. Devices without a composite
  frame (iPads) or machines without Xcode's files show the bare screen. View ▸ Hide Device Frame turns it off.
- **Chat inspector:** Claude Code running in the project folder as the selected account. Answers lead with
  the outcome in plain words; technical notes and steps sit behind a disclosure. Each answer that changed
  files has **Undo**. *Fix with Claude* runs appear here as messages too. *Point at…* attaches a widget
  tapped in the running app, with a picture of it.
- **Design** (⌥⌘D, or the sidebar's Design tab, `DesignView`): mockups of the app's screens on the canvas, made by a
  design chat in the sidebar that can only write `design/`. A look step (style → colour themes → Google Fonts) for new
  apps, versions to compare for every screen, and *Redesign…* for screens that already exist. See **Design** below.
- **The loop it's built around:** ask → see → undo. After Claude edits, the running app reloads on its own
  (`Workspace.applyEdits`: hot reload, a hot restart for start-up code and the theme files, whose `static final`
  themes a hot reload keeps, or a "Run Again" toast for packages
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
<Feature>/    @Observable models + services            Project/, Chat/, Simulator/, Inspector/, Accounts/, ClaudeCLI/, Dart/, Design/
Core/         Feature-agnostic helpers                 ProcessRunner, DiagnosticLog, ShellEnvironment, Extensions
```

### The pieces

| Kind | Shape | Examples |
|---|---|---|
| **Model** | `@MainActor @Observable final class`, `private(set)` state, intent methods | `FlutterRunModel`, `ChatModel`, `ProjectModel`, `SimulatorModel` |
| **Service** | `Sendable` struct or enum that does I/O and returns values; no UI state | `SimctlService`, `ClaudeCLIService`, `ProjectVerifier`, `RunningAppFinder` |
| **Process wrapper** | Owns one child `Process`, streams its output | `FlutterRunProcess`, `ClaudeStreamProcess`, `ClaudeLoginProcess` |
| **Value / parser** | Pure `Sendable` structs and enums: easy to test | `FlutterOutput`, `ClaudeEvents`, `ClaudeAgentCall`, `FileSnapshot`, `RunFailure`, `AppFlow` |
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

## New Project

Creating a project never needs Claude. `NewProjectModel` (`Project/`) runs `CreateStep`s in order through
`NewProjectService`: `flutter create` → app-ID rewrite (`AppIDWriter`, only when the ID doesn't end in the package
name) → starter files → `flutter pub add go_router flutter_riverpod` → local `git init` + first commit (skipped
with a note when git has no name). All rules about names, IDs and folders live in `NewProjectRequest.validate()`,
and the `flutter create` arguments in `FlutterCreateCommand`; the sheet only displays them. A failure keeps the
folder and `retry()` resumes at the failed step. The starter is `Resources/Templates/starter/**/*.tmpl`
(a folder reference in `project.yml`, filled by `TemplateRenderer`: `{{x}}`, or `{{x|dart}}` inside a Dart string).
Every placeholder must have a value in `StarterTemplate.values`; a test renders the whole starter. The full
plan is `docs/plans/new-project.md`. To check the starter really builds (needs Flutter and network), run a Debug
build with `MOBILE_STUDIO_SNAPSHOT_NEW_PROJECT=/tmp/x`: it creates a project, runs `flutter analyze` and `flutter
test`, and logs to `snapshot.log`.

The sheet (`Views/NewProjectSheet.swift`) is opened by `Workspace.newProject()` (File ▸ New Flutter Project… ⌘N, the
checklist's **New…**, or the empty canvas) and gated by `createProjectBlocker` (Flutter must be found; `Workspace.dart`
owns the Dart SDK model). When the create finishes, `finishNewProject(path:)` saves a `NewProjectRecord` (the request
and the kickoff state, per project folder), opens the folder and runs it once the open project has settled
(`runAfterOpen`, consumed in `projectStateChanged`).

The sheet's last step shows `ToolchainCheck` warnings (Xcode not selected, CocoaPods missing); they never block Create.
An answer may carry several `choices` blocks (`ChoiceSet.extractAll`): the card shows every question and sends them back
together (`ChoiceSet.reply(answering:)`), which is how the kickoff asks up to three per turn.

Rules worth knowing: `flutter create` runs with `--no-pub`, so only the packages step needs the network. App IDs can't
contain underscores (Apple). A create that fails or is stopped keeps its request, so reopening the sheet offers Retry or
Start Over (`NewProjectModel.isResumable`). Auto-run after a create goes through `startPendingRun()`, which waits for the
previous folder's run to stop and for `projectPathChanged` to have run, because SwiftUI doesn't order the two `onChange`
events. `ProcessRunner` stops a cancelled child's whole process tree. The commit is unsigned and skips hooks; with no
git name set it is skipped and the note is kept in the record and shown as a project issue.

**Milestone tracker.** The plan is also saved as JSON (`ProductPlanStore`) so it outlives a new chat; the sidebar's
**Plan** section (`PlanSection`) shows its milestones through `MilestoneProgress` (done / next / later). **Build** sends
a build-mode turn tagged with the milestone (`ChatMessage.milestone`); when that answer changes files without an error
the milestone is recorded as built in `NewProjectRecord.doneMilestones`, and undoing the answer unmarks it. Right-click
a row to mark one built or not built by hand.

**Kickoff.** A project with a record shows a card in the chat (`Workspace.isKickoffOffered`); nothing is spent until
**Start Planning**. `ChatMode.kickoff` swaps `ChatModel`'s call for `kickoffCall`: Sonnet, $1, tools Read/Glob/Grep
and no Bash (`ClaudeAgentCall.tools`; Bash is only offered when `allowedCommands` is non-empty), one question per
turn as a `choices` block. The prompt and `Workspace.choose` share the labels in `ProductPlan` (`writeLabel`,
`buildLabel`, …): picking *Write the plan* sends a plan turn (`ChatModel.Turn.plan`: Opus, $3, `--json-schema`
from `ProductPlan.schema`), and the app, never Claude, writes `PLAN.md` with `PlanRenderer` before the after-snapshot,
so it is an undoable change. *Build milestone 1* switches back to `.build`. `AppFlow.adding(_:)` draws the plan's
unbuilt screens as dashed cards. To check the kickoff without spending anything, run a Debug build with a stand-in
`MOBILE_STUDIO_CLAUDE_CLI` and `MOBILE_STUDIO_SNAPSHOT_KICKOFF=1` against a project made by
`MOBILE_STUDIO_SNAPSHOT_NEW_PROJECT` (`MOBILE_STUDIO_SNAPSHOT_SHEET=0|1|2` snapshots the sheet).

## Design

Design is a tab in the sidebar (`ProjectSidebar`, `Workspace.sidebarTab`) and a canvas mode (`Workspace.Canvas.design`,
shown by `DesignView` in the main window, not a separate window). Both follow `Workspace.canvas`, and `openDesign()` sets
it. The sidebar's Design tab holds the design chat (`DesignChatPanel`); the canvas shows the mockups. The design view
shows every screen as a mockup and lets Claude change them without touching the app. The full plan is `docs/plans/design.md`.

- **Files.** Everything is in the project's `design/` folder, in git. The app writes `README.md` and `kit.css` (from
  `Resources/Design/`, a folder reference in `project.yml`), `tokens.css` (from `tokens.json`, `TokensCSS`) and each
  screen's `screens/<id>/screen.json` (`DesignVersions`); Claude writes the mockups (`current.html`, `v1.html`, …),
  `tokens.json` and `look/palettes.json` / `look/fonts.json`. Screen folders are named by `DesignPaths.screenID`
  (`HabitFormScreen` → `habit_form`) and matched to the code's and the plan's screens with `AppFlow.screenKey`.
- **The vocabulary.** A mockup is HTML of a 393 × 852 pt phone screen made only of the kit's classes, each one a Flutter
  widget (the table is in `Resources/Design/README.md`). `DesignLint` checks every mockup (no grid, no literal colours,
  no scripts, Flutter icon names only…) and its issues go into the next turn's prompt. `DesignLint.kitClasses` must match
  `kit.css`; a test checks both ways. Icons are Flutter's Material Icons font, bundled with its licence, and
  `icon-codepoints.txt` comes from the SDK's `icons.dart` (`scripts/update-design-icons.sh`; Flutter's own `codepoints`
  file is older). The scheme handler swaps icon names for code points as it serves HTML.
- **Staying fast.** `DesignModel.refresh()` returns early when `DesignStore.fingerprint()` of `design/` is unchanged, because bumping `revision` reloads every artboard. All artboards share one `WKWebsiteDataStore` (one per view starts a web process each), the canvas is lazy, and the kit files (the 1.6 MB icon font) are read once. Keep file reads out of view bodies (`ThumbnailCache`).
- **Web views.** Mockups load through `ms-design://` (`DesignSchemeHandler`, rules in the pure `DesignURL`): `project/`
  is the project's `design/`, `kit/` the bundled kit, `style/<id>/` a style's sample, `fonts/` the downloaded font cache.
  Nothing else, no `..`, no network, no page JavaScript. Pages are laid out at full size and the SwiftUI view is scaled
  (`ArtboardView`): zooming the page itself hits WebKit's minimum font size. `DesignRenderer` makes PNG previews off screen
  (on a hidden window: a web view outside one doesn't draw) into Application Support; App Flow's cards, the version strip
  and the build turn use them.
- **Turns.** `ChatMode.design` runs on a second `ChatModel` (`Workspace.designChat`, stored as `Chats/<hash>-design.json`,
  its own Undo). The app plans each turn as a `DesignTurn` (look, suggestions, current, versions, freeform) and names
  the files Claude must write (`DesignVersions.nextIDs`, numbers never reused); `DesignPrompts` builds the instructions.
  `ChatModel.send(finishing:)` lets `DesignModel.record` write `screen.json` before the after-snapshot, so Undo removes
  the record with the files. Only one chat runs at a time per project (`chatBlocker` / `designBlocker`), because both
  snapshot the whole folder. A request about several selected screens is one turn, four screens at most
  (`DesignPrompts.batches`; the rest queue in `drawQueue`).
- **Reference pictures.** The composer takes screenshots (the paperclip, drag and drop). `DesignReferences` copies each
  one as PNG into `DesignStore.referencesFolder` (outside the project, under the design storage that is already a
  readable folder), so Claude's Read tool opens it whatever it was saved as. The paths travel on `DesignTurn.references`,
  which `DesignPrompts` lists in the turn's instructions, and on the user's `ChatMessage.attachments` for the transcript.
  Pictures staged in the composer are `Workspace.designAttachments`, cleared when the message is sent.
- **Look step.** Six styles are data (`Resources/Design/styles/<id>.json` + `sample.html`, `DesignStyle`), so their cards
  cost nothing. Picking one runs the Opus look turn: the start screen plus four colour themes and three font pairings.
  Trying a theme or pairing only swaps the CSS the handler serves (`tokensOverride`). Themes failing contrast are dropped
  (`LookSuggestions`). Fonts are checked against the bundled Google Fonts catalog (`google-fonts.json`,
  `scripts/update-google-fonts.sh`) and downloaded by `GoogleFontsService` **without a browser user agent**, which makes
  the CSS API answer with one TTF per weight (an old Chrome agent gets split WOFF files, which Flutter can't use).
- **Redesign.** *Redesign…* (Screens list, App Flow, or right-click the device to take its picture first) runs a Current
  turn: Claude redraws the screen from its code as `current.html` (and writes `tokens.json` from the app's theme if there
  is none). Versions start from what each screen shows. *Apply to the App* sends a build turn tagged `designApply` asking
  to change only what differs between the screen as it is and the chosen version (`DesignHandoff.applyMessage`); when it
  changes `lib/`, the version is marked in the app, and undoing it unmarks it. `sourceHash` notices the code changing.
- **Use this design** (`Workspace.approveDesign`) writes `lib/app/design_theme.dart` (`ThemeRenderer`), points the
  starter's `AppTheme._build` at it (`ThemeWiring`, keeping everything else in the file; an unfamiliar theme is handed to
  the main chat), and bundles the fonts with their licences (`assets/google_fonts/`, `PubspecAssets`, `flutter pub add
  google_fonts`; `design_theme.dart` registers the licences with `LicenseRegistry`), as one checkpoint recorded in the
  design chat. Text styles go through `GoogleFonts.getFont` one at a time: google_fonts 9's `getTextTheme` returns
  `material_ui`'s `TextTheme`, which `ThemeData` rejects. Check a change here with `flutter analyze` on a copy of a project. Build milestone adds the milestone's chosen mockups to its message.
- **Snapshots.** `MOBILE_STUDIO_SNAPSHOT_DESIGN="open,look,shot"` drives the window (steps are listed in `Snapshot`) and
  writes `-design-N.png`, pasting each web view's own snapshot in. `render` writes full-size style samples. Steps that
  call Claude (`style:`, `capture:`, `redesign:`, `ask:`, `apply`) spend real money: run them on a copy of a project.
  Nobody can click an approval card in a snapshot, so `MOBILE_STUDIO_SNAPSHOT_APPROVE=allow` answers them (default:
  decline) and logs what was asked. The run quits when its steps are done. `run` presses Run Again and waits for the app,
  and `sim:/screenshot`, `sim:/tap?x=&y=`, `sim:/type?text=` drive the device like `ms-sim` (writing `-device-N.png`), to
  check an applied design on the device. Do it all in one run: the debug app quits with the snapshot instance.

## Running Claude safely

Mobile Studio runs an agent with edit rights on the user's code, so these are hard rules:

- Build editing calls with **`ClaudeAgentCall`**. It always adds `--safe-mode` (no machine plugins, skills,
  MCP servers, hooks), `--permission-mode acceptEdits`, the tool list, and a budget. Don't hand-roll argument
  arrays for agent calls. A call with `editablePattern` (the design chat: `design/**`) runs `--permission-mode default`
  with `Edit(<pattern>)` in `--allowedTools` instead: the CLI accepts only those edits itself and holds every other one
  as a `can_use_tool` request, which `AgentPermissionPolicy.designRefusal` refuses without asking (checked against
  claude 2.1.301).
- Shell access is **allow-listed per command** (`allowedCommands`, e.g. `"flutter pub *"`). Add the narrowest
  pattern that works. Never allow `flutter run` (it doesn't exit and the app owns it), `rm`, or git commands
  that write.
- Every call has a **`maxBudgetUSD`** and a timeout. The read-only project check (`ProjectVerifier`) uses
  Haiku with Read/Glob/Grep only.
- "Files changed" comes from **`FileSnapshot`** (before/after hashes of the folder), never from Claude's own
  account of what it did.
- **Approval gate.** A command outside `allowedCommands` is not silently refused: the build chat and Fix set
  `ClaudeAgentCall.asksForApproval`, which runs the CLI with `--input-format stream-json --permission-prompt-tool stdio`.
  The prompt then goes in on stdin, and the CLI holds each such tool call as a `can_use_tool` control request on stdout until
  `ClaudeStreamProcess` writes a `control_response` (`AgentPermissionRequest.parse` / `.response`). The process also closes
  stdin once the `result` arrives, or the CLI never exits. `Workspace.approvalHandler(folder:)` is what chat and Fix pass in:
  `AgentPermissionPolicy` decides first (the hard rules above are **refused without asking**: `rm`, `sudo`, nested shells,
  `flutter run`, git writes, edits outside the project, credentials), then `ApprovalModel` queues a question that
  `ApprovalCard` shows at the end of the chat (Allow Once / Always Allow / Don't Allow; the window comes forward and the
  toolbar says "Waiting for your OK"). "Always Allow" is offered only for one plain command and remembers that exact text,
  per project (`ApprovedCommandStore`, `agent.approvedCommands.v1`), listed and revocable in the project's health popover.
  Stopping the run answers an open question with a decline (task cancellation). Kickoff and the project check have no
  Bash, so they keep the old behaviour. To see the card, run a snapshot with `MOBILE_STUDIO_SNAPSHOT_APPROVAL="message"` and a
  stand-in `MOBILE_STUDIO_CLAUDE_CLI` that prints a `can_use_tool` request and waits for a line on stdin.
- Launch agent processes with **`ClaudeAccess.agentProcess`**, which adds the user's terminal `PATH`. A
  Finder-launched app has a minimal one, so Claude's shell would not find flutter, dart or pod.

## Vision: Claude sees and drives the simulator

The chat's agent can check its own work in the running app. `AgentBridge` (`Simulator/`) listens on the loopback
interface only (random port and token per launch, in a 0600 file) and installs `ms-sim` into
`~/Library/Application Support/Mobile Studio/Agent/bin`; `ClaudeAccess.agentProcess` puts that folder on the agent's
PATH. The agent runs `ms-sim screenshot | tap X Y | swipe X1 Y1 X2 Y2 | home` (allow-listed as `ms-sim *` in the build
call). Screenshots are PNGs of at most 1000 px, saved in `Agent/Screenshots`, which the call exposes with
`ClaudeAgentCall.readableFolders` (`--add-dir`) so the agent reads them with its Read tool. Coordinates are pixels of the
latest screenshot (`SimulatorCommand.normalized`). `Workspace` connects the bridge to `SimulatorModel.perform`, which
answers in words ("Take a screenshot first…", "isn't showing a running app"). The chat shows these as "Looking at the
app" / "Tapping the app" (`SimulatorCommand.activity`). Scrolling is a swipe. `ms-sim type TEXT` and `ms-sim key return|delete|tab|escape` send hardware key presses through
SimulatorKit's `IndigoHIDMessageForKeyboardArbitrary` (`KeyboardMap` maps US-layout characters to HID usages; others are
reported as skipped). Each key is held 50 ms: iOS drops a key that goes down and up in the same instant. If typing seems to do nothing, `ms-sim paste TEXT` (device pasteboard via `simctl pbcopy`), `ms-sim hold X Y` and tapping Paste is the fallback that needs no keyboard. The canvas forwards the Mac keyboard too
(`ScreenView` becomes first responder on click and passes `keyDown`/`keyUp`/`flagsChanged` to `MSSimulatorDisplay.sendKeyEvent:`). **Keyboard transport.** On CoreSimulator 1155.4 (Xcode 27) and later, legacy Indigo keyboard events are not delivered, though touch still is. `MSSimulatorDisplay` therefore sends keys to the simulator's `dtuhidd` daemon, the way Xcode's own tooling does: `[SimDevice lookup:error:]` on `com.apple.coredevice.feature.remote.universalhidservice`, then `xpc_endpoint_create_mach_port_4sim` + `xpc_connection_create_from_endpoint` + `xpc_connection_enable_sim2host_4sim`. A key change is `{"payload": {"send": {"_0": <report data>, "_1": <keyboard service ID, uint64>}}}` (plain `xpc_connection_send_message`; asking for a reply only produces "Connection interrupted"). The report is ID `1` followed by a 30-byte bitmap, one bit per HID usage 0...239 (modifiers are usages `0xE0`...`0xE7`), so the display keeps the key state and resends it on each change. `{"payload": {"connectedServices": {}}}` lists the services (the keyboard is `0x200`). The daemon resets its services when the peer disconnects and drops one that sends something it can't decode (`Peer sent unknown message` / `Failed to decode report for gesture` in `xcrun simctl spawn <udid> log show --predicate 'process == "dtuhidd"'`, which is the way to debug this). The old Indigo path stays as a fallback when the runtime doesn't vend the service. All of this is private and was found by probing, so expect it to need rework when Xcode changes. When testing, run `xcodebuild` with a separate `-derivedDataPath` while the app is running from the default one, or CodeSign fails on a stale test bundle. Only the build chat gets this; Fix and kickoff calls don't.

## Conventions

- **Comments say why, not what.** One line above the declaration (`///` for API), written as a plain
  sentence. Match the density of the surrounding code: most methods have none, non-obvious ones have one.
- **UI copy is plain English and says what to do next**: "Boot iPhone 16 first.", not "Device not ready".
  A disabled control gets a reason the user can read nearby (see `RunBar.blocker`).
- **Icon-only buttons** use `Label(title, systemImage:).labelStyle(.iconOnly)`, so VoiceOver reads the title,
  plus `.help(...)`.
- **Write for people who don't read code.** Name files with `FriendlyName` ("Home screen · edited"), keep
  paths as secondary text or help, and keep the chat system prompt's two-part answer rule (outcome, `---`,
  technical notes; split by `AnswerParts`). When Claude offers options, the prompt asks for a fenced ```choices
  JSON block at the end; `ChoiceSet` takes it out of the text and the chat shows a card to pick from
  (`Workspace.choose` sends the pick). Keep that format in sync between the prompt and `ChoiceSet`.
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

- The detail column also runs under the floating sidebar *without* reporting it as a safe area (a
  `GeometryReader` there sees the full window width and a zero leading inset). Centred content is fine; anything
  that scrolls or starts at the leading edge must keep clear itself. `ContentView` measures the overlap and passes
  it to `FlowCanvas` as `leadingInset`.

- Swift `Regex` uses Unicode word boundaries by default, where `Navigator.push` is one word, so `\bpush` never
  matches. Parsers of Dart source use `.wordBoundaryKind(.simple)`.

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
`MOBILE_STUDIO_SNAPSHOT_TIMES=20,120` captures at each of those seconds, to follow a build through. `MOBILE_STUDIO_SNAPSHOT_MAP=actual,in,pan:-200:-150` zooms and pans the app flow map after 4 s (with
`-window.canvas.v1 flow`); `MOBILE_STUDIO_SNAPSHOT_KEYS` presses menu shortcuts, but the menu bar of a snapshot run never
refreshes after launch, so items that start disabled stay disabled there (Product ▸ Run too). Point it at a
throwaway project with `-project.path.v1 /path/to/app`, never at the user's own. To check Fix with Claude without
spending anything, add `MOBILE_STUDIO_SNAPSHOT_FIX=1` (or `MOBILE_STUDIO_SNAPSHOT_CHAT="…"` with `MOBILE_STUDIO_SNAPSHOT_UNDO_AFTER=20`
for the ask → reload → undo loop) and point `MOBILE_STUDIO_CLAUDE_CLI` at a stand-in script that
answers `--version` and `auth status`, prints stream-json, and makes the fix. Launch arguments override saved settings for that run only, e.g.
`-window.chatVisible.v1 '<false/>'`, or `-window.canvas.v1 flow` for the app flow map. Glass toolbar platters and AppKit-hosted list rows don't draw in these
captures (scroll views are pasted in separately, like the panels); everything else does. Don't click in a snapshot
window: it's a real window, and a click acts and can save settings. See `Snapshot` in `App/AppDelegate.swift`.

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
