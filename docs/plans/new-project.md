# Plan: New Project

Let someone who has never run `flutter create` start an app from AppFast Studio: name it, describe it, pick
where it lives and which platforms it targets, get a clean, well-structured starter that runs at once, and then
talk it through with Claude. The talk ends in a written product plan (design decisions, must have, can have,
open questions, build order) that later chat turns follow.

The flow has four stages, each its own phase so it can be cancelled, retried and tested apart:

```
1. Ask        sheet: name, description, app ID, folder, git, platforms        (no cost, no I/O)
2. Create     flutter create → apply app ID → starter architecture → git      (no Claude, deterministic)
3. Open       set as current project, Run on the simulator                     (existing code)
4. Brainstorm chat in "kickoff" mode → questions as choice cards → PLAN.md     (Claude, read-only + one file)
```

Stages 1–3 never need Claude, so New Project works before the user has signed in; only stage 4 does.

---

## 1. Ask: the New Project sheet

**Entry points** (all call `Workspace.newProject()`, gated by `canCreateProject` / `createProjectBlocker`):

- File ▸ **New Flutter Project…** ⌘N (⌘N is free; New Chat is ⇧⌘N).
- Sidebar Get Started checklist: the "Flutter project" step gets **New…** next to **Choose…**.
- The empty canvas state (no project): two buttons, *New Project* and *Open Project*.

**Blocker:** Flutter SDK not found (`DartSDKService` already locates it) → "Install Flutter first, then try
again." A run in progress is stopped by `Workspace`, the same way changing folders does today.

**One sheet, three short steps** (`NewProjectSheet` in `Views/`), with Back/Next and a summary on the last step:

| Step | Fields | Rules |
|---|---|---|
| **About the app** | *App name* ("Water Tracker"), *What does it do?* (multi-line, 1–3 sentences, optional but encouraged: it feeds the brainstorm), *App ID* (optional, e.g. `com.leo.watertracker`) | Package name is derived from the app name (`water_tracker`) and shown as secondary text with an *Edit* disclosure. App ID placeholder shows the default it will get. |
| **Where it lives** | *Folder* (parent folder picker; defaults to `~/Developer`, created if missing, then to the last parent used), shows the final path `…/water_tracker`. *Track changes with git* (on by default, local only). | The target folder must not exist, or be empty. Git off shows why it matters: "History and diffs need git." |
| **Platforms** | iPhone & iPad (on, locked: "The preview runs in the iOS Simulator"), Android (on by default), Web, macOS, Windows, Linux | Plain names, platform folder names in help text. |

The summary step lists what will happen in plain words ("Create *Water Tracker* in ~/Developer/water_tracker
for iPhone and Android, with git") and a **Create** button.

**Value type:** `NewProjectRequest` (pure, `Sendable`, `Codable`): `displayName`, `packageName`, `description`,
`appID?`, `parentFolder`, `platforms: Set<Platform>`, `usesGit: Bool`. Its `validate() -> [Issue]` holds every rule, so the sheet only shows them and tests cover them:

- **Package name:** lowercase `[a-z][a-z0-9_]*`, not a Dart reserved word (`class`, `switch`, …), not a package
  that would clash (`flutter`, `test`, …), ≤ 64 chars. `PackageName.derive(from:)` handles spaces, accents,
  leading digits ("2048 Game" → `game_2048`), emoji.
- **App ID:** reverse-DNS, ≥ 2 segments, each `[a-zA-Z][a-zA-Z0-9_]*`; no Java keywords as segments (Android
  rejects `com.new.app`); warn, don't block, on `com.example.*` ("Stores reject com.example IDs. Fine for now.").
- **Folder:** parent exists and is writable; target missing or empty; not inside another Flutter project
  (look up the tree for `pubspec.yaml`); not inside iCloud Drive's "Optimize storage" folders (warn).

The parent folder last used is saved as `newProject.lastParent.v1`. With nothing saved, the default is
`~/Developer`, created when the user presses Create (not when the sheet opens).

## 2. Create: deterministic scaffold

`NewProjectModel` (`Project/`, `@MainActor @Observable`) owns one `Task` and a phase:

```swift
enum CreatePhase: Equatable {
    case idle
    case working(CreateStep)          // shown as a checklist with the current step spinning
    case done(path: String)
    case failed(step: CreateStep, message: String)
}
enum CreateStep: CaseIterable { case flutterCreate, appID, architecture, packages, git }
```

Each step is a small `Sendable` service so it is testable without the app:

1. **`FlutterCreateService`** — runs, through the login shell like `FlutterRunProcess` does, in the parent folder:
   `flutter create --project-name <pkg> --org <org> --platforms ios,android,… --description "<desc>" --empty <pkg>`.
   `--empty` gives a bare `main.dart` that our template replaces. Logs to `DiagnosticLog(name: "new-project")`.
   The argument list is built by a pure `FlutterCreateCommand` (tested; the description is passed as one argv
   element, never interpolated into a shell string).
2. **`AppIDWriter`** — `flutter create` makes the ID `<org>.<pkg>`. When the user's ID is exactly that, pass
   `--org` and skip this. Otherwise rewrite `PRODUCT_BUNDLE_IDENTIFIER` in `ios/Runner.xcodeproj/project.pbxproj`
   (Runner and RunnerTests), `applicationId` in `android/app/build.gradle(.kts)`, and the macOS equivalents.
   Pure string transforms on file text, tested against fixture copies of what Flutter generates. The Kotlin
   package / `namespace` stays as generated (renaming it means moving files; not worth the risk).
3. **`StarterTemplate`** — writes the starter architecture (below) from templates bundled in the app
   (`Resources/Templates/starter/…`, `{{app_name}}`-style placeholders filled by a pure `TemplateRenderer`).
   No Claude: it's free, instant, the same every time, and always builds.
4. **Packages** — `flutter pub add go_router flutter_riverpod` (and dev deps), then `flutter pub get`. Versions
   resolved by pub, not pinned in the template, so the starter doesn't rot. Offline → step fails with "Couldn't
   download packages. Check your connection and try again." and a Retry that resumes from this step.
5. **Git** (when on) — `git init -b main`, write `.gitignore` additions, `git add -A`,
   `git commit -m "Create <App name> with AppFast Studio"`. Local only: no remote is added and nothing is pushed.
   No identity configured → still init and stage, skip the commit, and say: "Set your name in git to save the
   first version: `git config --global user.name …`" with a `CommandHint`. This is the app's own write, not the
   agent's; the agent's no-git-writes rule is unchanged.

**Failure and cleanup:** a failure at any step keeps the folder (never delete the user's disk on our own) and
shows *Retry from here* / *Show log* / *Reveal in Finder*. *Cancel* during `flutter create` terminates it.
`Retry` only works from the step that failed; steps are idempotent where cheap (pub get, app ID rewrite).

**Then** `Workspace.finishNewProject(path:)`: `project.set(path:)` (make it `internal`, or add
`project.open(path:)`), load the empty chat for the folder, refresh flow, and — when a simulator is available —
Run, so the user sees their app within a minute. Then start stage 4.

### The starter architecture

Feature-first, three layers inside each feature, one app shell. It is small (≈ 12 files) and every file has a
purpose a newcomer can read:

```
lib/
  main.dart                      runApp(ProviderScope(child: App()))
  app/
    app.dart                     MaterialApp.router, theme, title from the request
    router.dart                  go_router: '/' → HomeScreen  (AppFlow already reads GoRoute)
    theme.dart                   one seed colour, light + dark ColorScheme, text theme
  core/
    widgets/                     shared widgets (empty, with a README line in ARCHITECTURE.md)
    utils/
  features/
    home/
      presentation/home_screen.dart    shows the app name and the description: a real first screen
      application/                     controllers / notifiers (Riverpod)
      data/                            repositories, models
test/
  widget_test.dart               pumps App, finds the title: green from the start
analysis_options.yaml            flutter_lints + a few stricter rules
ARCHITECTURE.md                  the rules below, in plain words, for people and for Claude
AGENTS.md + CLAUDE.md            "Follow ARCHITECTURE.md and PLAN.md", short; for agents the user runs
                                 outside the app (Claude Code, Cursor, …)
```

`ARCHITECTURE.md` rules: one folder per feature; screens in `presentation/`, state in `application/`, I/O in
`data/`; dependencies point down; routes only in `app/router.dart`; colours only from `theme.dart`;
every new screen gets a route and a widget test.

`--safe-mode` skips CLAUDE.md (checked against `claude --help`, v2.1.301), so the in-app agent never sees the
project's CLAUDE.md. `ChatModel.systemPrompt` therefore gains one line, which the in-app agent depends on:
"If ARCHITECTURE.md or PLAN.md exist, read them before changing code and follow them."

## 3. Open

Existing code. Two small changes: the project header shows "New project" until the first chat change lands,
and the History section's first row is the initial commit ("Created the app"), when git is on.

## 4. Brainstorm: kickoff chat → PLAN.md

Right after a **new** project opens, the chat shows a **Kickoff card** (not an automatic paid call): "Plan
*Water Tracker* with Claude: a few questions, then a written plan. About $1–3." with **Start planning** / *Skip*.
It is only offered for projects made with New Project (the request is kept with the chat, so the card knows).

**Models and budget:** question turns use **Sonnet** (`maxBudgetUSD: 1`); the final plan turn uses **Opus**
(`maxBudgetUSD: 3`). `ClaudeAgentCall.model` already exists, so this is a per-turn choice in `ChatModel`.
Skip leaves a "Plan this app" item in the empty chat so it can be started later.

**How it runs.** It's a normal chat session (`ChatModel`, same transcript, same Undo), with a different
`ChatMode`:

```swift
enum ChatMode: Codable, Equatable { case build, kickoff }
```

`ChatModel.call(for:session:)` picks the system prompt, tools and budget per mode. `ClaudeAgentCall` gains a
`tools` property (default: today's list) so kickoff can be **read-only: Read, Glob, Grep, no Bash**. The
system prompt asks Claude to:

1. Read the description, `pubspec.yaml`, `ARCHITECTURE.md`.
2. Reply with a short take on the app (one paragraph, plain words), then **ask at most 3 questions per turn**,
   each as a ```choices block (already supported). Single-choice for forks ("Does it need accounts?":
   *No, it stays on the phone* / *Sign in with Apple and Google* / *Email and password*), multiple for lists of
   features. The user can always type instead.
3. Cover, over 2–4 turns: who it's for and the one job it does; screens and the main flow; data (on device /
   cloud, offline); accounts; notifications; look and feel (colour, tone, light/dark); monetisation; platforms
   confirmed; accessibility and languages.
4. Stop asking when it has enough, and say so: "I have what I need. Write the plan?" as a choices block
   (*Write the plan* / *A few more questions*).

**Writing the plan.** The last turn uses `--json-schema` with a `ProductPlan` schema, and the **app** writes
`PLAN.md` from it (pure `PlanRenderer`, tested). Claude never gets Write in kickoff mode, the file is exactly
the shape we expect, and it's saved as a checkpoint so it can be undone like any change.

```swift
struct ProductPlan: Codable, Sendable {
    let summary: String                     // two sentences
    let audience: String
    let decisions: [Decision]               // title, choice, why, alternatives
    let mustHave: [Feature]                 // title, detail, screens
    let canHave: [Feature]
    let notNow: [String]                    // explicitly out of scope
    let screens: [PlannedScreen]            // name, purpose, leads to
    let openQuestions: [String]
    let milestones: [Milestone]             // title, features, "done when"
}
```

The chat then shows the plan as a card (summary, must-have count, *Open PLAN.md*) and ends with a choices
block: **Build milestone 1** (recommended) / *Change the plan* / *Not now*. Picking *Build milestone 1* switches
the chat to `.build` mode and sends "Build milestone 1 from PLAN.md." — the normal ask → see → undo loop.

The planned screens can also be drawn in the App Flow canvas as dashed "planned" nodes next to the real ones
(can have, see below).

---

## Files

| New | Layer | What |
|---|---|---|
| `Project/NewProjectRequest.swift` | value | request, `PackageName`, `AppID`, `validate()` |
| `Project/FlutterCreateCommand.swift` | value | argv for `flutter create` |
| `Project/AppIDWriter.swift` | value | pbxproj / gradle rewrites |
| `Project/StarterTemplate.swift` | value + I/O | `TemplateRenderer` (pure) + file writer |
| `Project/NewProjectService.swift` | service | runs create, pub add, git steps |
| `Project/NewProjectModel.swift` | model | `CreatePhase`, task, retry-from-step |
| `Chat/ProductPlan.swift` | value | schema, `PlanRenderer` |
| `Views/NewProjectSheet.swift` | view | three steps + progress |
| `Resources/Templates/starter/**` | resource | template files (add to `project.yml` resources) |

| Changed | What |
|---|---|
| `App/Workspace.swift` | `newProject()`, `canCreateProject`, `createProjectBlocker`, `finishNewProject(path:)`, `startKickoff()`; sheet visibility (`isNewProjectSheetVisible`) |
| `App/StudioCommands.swift` | File ▸ New Flutter Project… ⌘N |
| `Project/ProjectModel.swift` | `open(path:)` for a folder chosen by code, not the panel |
| `ClaudeCLI/ClaudeAccess.swift` | `ClaudeAgentCall.tools` (default unchanged) |
| `Chat/ChatModel.swift` | `ChatMode`, kickoff prompt, JSON-schema plan turn, architecture line in build prompt |
| `Views/ProjectView.swift`, `Views/SimulatorView.swift`, `Views/ChatView.swift` | New… button, empty canvas, kickoff and plan cards |
| `AGENTS.md` | New Project section, kickoff mode rules, template location |

## Tests (pure layer)

- `PackageName.derive`: spaces, caps, accents, emoji, leading digits, reserved words, empty.
- `AppID` validation, default ID, `com.example` warning.
- `NewProjectRequest.validate`: each issue, and a valid request has none.
- `FlutterCreateCommand.arguments`: platforms order, description with quotes/newlines stays one element,
  `--org` vs rewrite decision.
- `AppIDWriter` on fixture pbxproj and both gradle dialects; leaves unrelated IDs alone; idempotent.
- `TemplateRenderer`: placeholders filled, unknown placeholder fails loudly, Dart string escaping of the app
  name and description (`'`, `$`, `\`).
- `PlanRenderer`: full plan, empty sections omitted, Markdown special characters escaped.
- `ClaudeAgentCall` with custom tools: `--tools` and `--allowedTools` match, no Bash in kickoff.
- A template smoke test is *not* a unit test (needs Flutter); add it as a snapshot-run check instead:
  `MOBILE_STUDIO_SNAPSHOT_NEW_PROJECT=/tmp/x` creates a project there and runs `flutter analyze` + `flutter test`.

## Phases

1. **Values + tests:** request, names, IDs, command, AppID writer, renderer. (No UI.)
2. **Create pipeline:** service, model, template files, git, logs. Snapshot env var to create headlessly.
3. **Sheet + entry points:** menu, checklist, empty canvas; light/dark snapshots; open + auto-run.
4. **Kickoff mode:** `ChatMode`, read-only tools, prompt, kickoff card. Tested with the stand-in CLI script.
5. **Plan:** JSON-schema turn, `PlanRenderer`, PLAN.md checkpoint, plan card, "Build milestone 1".
6. **Polish (can have):** planned screens in App Flow, GitHub repo creation, more templates.

Each phase ends with zero warnings, tests green, and AGENTS.md updated.

---

## Decisions (proposed)

| Decision | Choice | Why | Alternative |
|---|---|---|---|
| Who writes the starter | Bundled template, no Claude | Free, instant, identical every time, always builds; Claude's first edit starts from known ground | Claude generates it from the description (costly, can fail to build before the user has seen anything) |
| State management | Riverpod, no code generation | Testable, scales, no `build_runner` step for people who don't read code | Bloc (more ceremony), Provider (dated), setState only (doesn't scale) |
| Routing | go_router | Official, deep links, and `AppFlow` already reads `GoRoute` | Navigator 1.0 named routes |
| Structure | Feature-first, 3 layers | Claude can add a feature without touching others; easy to explain | Layer-first (`screens/`, `models/`) |
| iOS | Always on | The canvas only runs the iOS Simulator | Allow off, but then Run is blocked |
| Git remote | None: local git only | Nothing outward-facing during creation; the sheet stays short | Remote URL field, or `gh repo create` (can have) |
| Planning models | Sonnet asks, Opus writes the plan | Cheap question turns; the best reasoning goes into the one document that steers the build | Sonnet throughout (cheaper), Opus throughout (dearer) |
| Brainstorm start | Card, user clicks | No surprise spend; works when not signed in yet | Start automatically |
| Brainstorm tools | Read-only; app writes PLAN.md from JSON | Planning can't touch code; plan shape is guaranteed | Let Claude Write PLAN.md |
| Plan location | `PLAN.md` at project root, in git | Visible, diffable, read by later turns | App Support (hidden from the user's repo) |
| Folder on failure | Keep it, offer Retry | Never delete user disk on our own | Roll back by deleting |

## Must have / can have (for this feature)

**Must have:** name → package name with validation; optional app ID applied on iOS and Android; folder picker
with empty-folder check; platforms; `flutter create`; starter architecture that analyzes clean and passes its
test; git init + first commit; opens and runs; kickoff chat with choice questions; PLAN.md with decisions,
must have, can have, open questions, milestones; Build milestone 1; logs and retry for every step.

**Can have:** a remote repository (URL field, or `gh repo create` when `gh` is signed in) and a *Push*
button; "Plan the next version" for existing projects (its prompt reads the code first); planned
screens drawn in App Flow; more starters (tabs app, list/detail, sign-in); pick a seed colour and app icon in the
sheet; localisation scaffold (`flutter gen-l10n`); Firebase/Supabase setup as a plan milestone; recent projects
list on the empty canvas; re-run the brainstorm later ("Update the plan") with a diff of PLAN.md.

**Not now:** Android emulator preview; signing and store setup; importing a design from Figma.

## Answered (2026-11-01)

1. **State management:** Riverpod, no code generation.
2. **Templates:** one opinionated starter; more starters are can have.
3. **Remote repo:** local git only. No remote field in the sheet.
4. **Planning cost:** Sonnet for question turns ($1 cap each), Opus for the final plan turn ($3 cap).
5. **`--safe-mode` and CLAUDE.md:** safe mode skips CLAUDE.md (per `claude --help`, v2.1.301). The
   system-prompt line is how the in-app agent learns the rules; the project's AGENTS.md/CLAUDE.md are for
   agents run outside the app.
6. **Default folder:** `~/Developer`, created if missing, then the last parent used.
7. **Existing projects:** new projects only for now; "Plan the next version" is can have.
