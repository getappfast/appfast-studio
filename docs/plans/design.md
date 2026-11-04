# Plan: Design

Let someone who can't draw or code see their app before it's built. After the plan is written, a **Design** window
opens: the user picks a style (Minimal, Soft, Bold, …), then one of Claude's suggested colour themes and a pair of
Google Fonts, and Claude mocks up every planned screen in that look. The user changes them
by talking ("make the header calmer", "put the total at the top"), and the approved designs become the reference that
**Build milestone** works from.

It slots between the two stages New Project already has:

```
Plan     kickoff chat → PLAN.md                                          (exists)
Design   style → colours → fonts → mock up each screen → Use this design  (this plan)
Build    Build milestone N, with the milestone's designs as reference    (exists, gains references)
```

The same window **redesigns screens that already exist**, in any project, with or without a plan: select a screen,
see it as it is now, ask for changes, and compare the versions that come back before applying one (section 6).

The design is a **reference, not code**. Changes go one way, design → app, and only when the user presses a button.

---

## 1. What a design is made of

Plain files in `design/` at the project root, in git, readable by people and by agents outside the app:

```
design/
  README.md              what this folder is, for people and agents (written by the app)
  kit.css                the component kit (written by the app, never by Claude)
  tokens.json            colours, type, shape, spacing: light and dark (written by Claude, checked by the app)
  tokens.css             tokens.json as CSS variables (written by the app from tokens.json)
  screens/
    home/                one folder per screen, named after the plan's (or the code's) screen
      current.html       the screen as it is built now, redrawn as a mockup (redesigns only)
      current.png        the running app's picture of it, when one was captured (redesigns only)
      v1.html  v2.html   versions, never edited once written
      screen.json        versions, which one is chosen, what was asked for each (written by the app)
    add_drink/
  look/
    palettes.json        Claude's colour theme suggestions (section 3)
    fonts.json           Claude's font pairing suggestions
  fonts/                 the Google Fonts files the mockups use, with their licences (downloaded by the app)
```

Every request makes **new version files** instead of editing the last one, so nothing the user liked is lost and any
two can be compared (section 5). The **chosen** version of each screen is its reference for the build.

**Why HTML.** Claude writes HTML better than anything else, and a `WKWebView` shows a change at once: no compile, no
simulator, no `flutter run`. Quick back-and-forth is the whole point of a design step. Mocking up in Dart would mean
nothing gets lost in translation, but every change would wait on a Flutter build.

**Keeping it buildable.** HTML can do things Flutter can't do easily, so the design vocabulary is restricted. This
is what keeps the build close to the mockup:

- **Layout:** flexbox only (`.row`, `.column`, `.gap-*`, `.pad-*`, `.grow` from `kit.css`). No CSS grid, no floats,
  no `position: absolute` except for the kit's overlays (FAB, sheet, dialog).
- **Components:** only the kit's classes, each mapping to one Material widget: `.app-bar` → `AppBar`, `.card` →
  `Card`, `.list-tile` → `ListTile`, `.button.filled|tonal|outlined|text` → `FilledButton`…, `.text-field` →
  `TextField`, `.nav-bar` → `NavigationBar`, `.fab`, `.chip`, `.switch`, `.checkbox`, `.slider`, `.progress`,
  `.sheet`, `.dialog`, `.snackbar`, `.divider`, `.avatar`, `.badge`. The table lives in `design/README.md`, so the
  build agent reads the same mapping.
- **Style:** colours, radii, shadows, borders, spacing and type only through `tokens.css` variables
  (`var(--primary)`, `var(--card-shadow)`), never literal values. A style is tokens, not different HTML.
- **Text:** two Google Fonts from the tokens, a display font and a body font, through the type-scale classes
  (`.display-large` … `.label-small`) only. Flutter draws the same families through the `google_fonts` package.
- **Icons:** `<span class="icon">water_drop</span>`, from the **Material Icons** font, the same font Flutter draws
  `Icons.*` with (copied from the Flutter SDK with its CC BY 4.0 licence), bundled in full with the app and served to the mockups by the app. The name maps 1:1 to
  `Icons.water_drop`. The app also bundles the list of `Icons` names, and `DesignLint` flags any other name, so an icon
  that would show as raw text in the mockup, or not exist in Flutter, is caught and fixed by Claude.
- **Images:** `.image` placeholders with an aspect ratio and a caption. No downloads.
- **No JavaScript, no external URLs.** The web view enforces both (below).

A pure **`DesignLint`** checks every screen after each turn (`<script>`, `display: grid`, absolute positioning outside
the kit, literal colours, unknown kit classes, `http(s)://`) and returns issues. They show on the artboard ("Uses
something Flutter can't build directly") and go into the next turn's prompt, so Claude fixes them itself.

**Tokens** (`DesignTokens`, `Codable`, validated):

```swift
struct DesignTokens: Codable, Equatable, Sendable {
    struct Scheme: Codable, Equatable, Sendable {      // Material 3 roles, hex strings
        let primary, onPrimary, primaryContainer, onPrimaryContainer: String
        let secondary, onSecondary, secondaryContainer, onSecondaryContainer: String
        let surface, onSurface, surfaceContainer, onSurfaceVariant, outline: String
        let error, onError: String
    }
    struct Fonts: Codable, Equatable, Sendable {
        let display: String          // a Google Fonts family: "Fraunces", or "system"
        let body: String             // "Inter", or "system"
    }
    let style: String                // a `DesignStyle` id: "minimal"
    let name: String                 // the colour theme's name: "Calm water"
    let mood: String                 // one sentence, shown on the colour card
    let light: Scheme
    let dark: Scheme
    let fonts: Fonts
    let radius: Radius               // small, medium, large (pt)
    let elevation: Elevation         // flat, subtle, raised
    let borders: Borders             // none, hairline, bold
    let density: Density             // compact, comfortable, airy (the spacing unit follows)
    let typeScale: TypeScale         // display/headline/title/body/label × large/medium/small: size, weight
}
```

The app turns tokens into **two files from one source**: `tokens.css` for the mockups (`TokensCSS`, pure, with
`@font-face` rules for the two fonts) and, when the user approves, `lib/app/design_theme.dart` (`ThemeRenderer`, pure: an
explicit `ColorScheme` per brightness; `GoogleFonts.getTextTheme(body)` with the display and headline styles from
`GoogleFonts.getFont(display)`; card, button and input shapes from the radii, elevation and borders;
`VisualDensity` from the density). The project's own `theme.dart` is pointed at it rather than replaced
(`ThemeWiring` swaps the starter's `AppTheme._build` for a call to `DesignTheme`), because projects keep more there:
habit_kit's has its habit colours. A theme file the app doesn't recognise is handed to the main chat to wire. Invalid tokens (bad hex, missing role, low contrast between a role and its `on`
colour, a font that isn't in the Google Fonts catalog or lacks a weight the type scale uses) are reported to Claude
like lint issues; the last valid tokens stay in use.

## 2. The flow

**Entry points** (all call `Workspace.openDesign()`, gated by `designBlocker`):

- After the plan is written, `ProductPlan.nextSteps` gains **Design the screens** (recommended) ahead of
  **Build milestone 1**, which stays available for people who want to skip design.
- Window ▸ **Design** ⌥⌘D, and a **Design** button in the sidebar's Plan section.
- A planned card in App Flow: *Design this screen*.

**Step 1: The look.** Pick a style, then a colour theme, then fonts, each from a row of cards (section 3). The
result is `design/tokens.json` and a first drawing of the start screen.

**Step 2: Screens.** One turn per few screens, in plan order, starting with the milestone 1 screens, so the user can
look at the first ones while the rest are drawn. Each turn's prompt names the screens to do and lists the plan's
features on them. Copy is real, from the plan ("8 of 10 glasses today"), never lorem ipsum.

**Step 3: Iterate.** The user selects an artboard (or several) and types. The message is scoped to the selection
("On the Home screen: …"), the same way clicking a screen in the sidebar starts a message today. Each request makes a
new version of that screen, or several when asked ("show me three"), and the newest becomes chosen until the user
picks another (section 5). A request about several screens ("make every list screen denser") is **one turn for all
of them**, so they come out consistent, up to four screens; with more selected, the app runs it four screens at a
time, in order. All versions from one turn share its round and `messageID`, so one Undo removes the whole batch.

**Step 4: Use this design.** A button in the window's toolbar. In one checkpoint, the app:
1. runs `flutter pub add google_fonts` (its own command, as New Project's packages step does), when it isn't there yet;
2. copies the two fonts' files from `design/fonts/` to `assets/google_fonts/` and adds that folder to `pubspec.yaml`'s
   assets (`PubspecAssets`, a pure text transform), so the app works offline and in store builds;
3. writes `lib/app/design_theme.dart` from the tokens and points `lib/app/theme.dart` at it (`ThemeWiring`).

Each family's licence is downloaded from the google/fonts repository (`ofl/`, `apache/` or `ufl/`), bundled next to
its files as `<Family>-LICENSE.txt`, and registered with `LicenseRegistry` by `design_theme.dart` the first time a
theme is built, so `main.dart` stays untouched. Text styles go through `GoogleFonts.getFont` one by one:
google_fonts 9's `getTextTheme` returns `material_ui`'s `TextTheme`, which Flutter's `ThemeData` rejects (found
testing on habit_kit).

`applyEdits` then hot-reloads, or shows "Run Again" the first time, since a new package needs a fresh build. The
design is marked approved. Nothing else in `lib/` changes: screens get built by Build milestone.

**Later changes.** When a built screen's chosen version isn't the one in the app, its artboard shows **Apply to the
app**. It sends a build turn: "Update the Home screen to match design/screens/home/v3.html." That is the only path
from design to code, so the two never drift silently.

## 3. The look: style, colours and fonts

Three quick choices, each a row of cards in the window and a `choices` block in the chat, so the user can click or
type ("like Soft, but less pink"). Only one of them costs a Claude turn.

**1. Style (free, instant).** The app bundles six styles. Each is a `DesignStyle` (`Resources/Templates/design/styles/
<id>/style.json`): default shape, elevation, borders, density and type scale, a font shortlist and colour guidance
for the prompt, plus a sample screen drawn with its default tokens. The cards are those samples, rendered locally,
so the user sees every style before anything is spent.

| Style | Feel | Shape and depth | Fonts it suggests from |
|---|---|---|---|
| **Minimal** | Calm, lots of white space, one accent colour | Small radius, flat, hairline borders, airy | Inter, DM Sans, Manrope |
| **Soft** | Friendly, gentle, pastel containers | Large radius, subtle shadows, no borders | Nunito, Plus Jakarta Sans, Quicksand |
| **Bold** | Confident, high contrast, big type | Medium radius, flat, bold borders, compact | Space Grotesk, Archivo, Outfit |
| **Editorial** | Refined, magazine-like, serif headlines | Small radius, flat, hairline rules, airy | Fraunces or Playfair Display with Inter or Source Sans 3 |
| **Playful** | Bright, chunky, energetic | Extra-large radius, raised, no borders | Fredoka, Baloo 2, Poppins |
| **Classic** | Familiar Material 3, nothing surprising | Material defaults | Roboto |

**Describe your own** sends the user's words to Claude, which picks the nearest style and adjusts its tokens. Adding
a style later is one folder of data and a sample, not code. A recommended badge goes on the style that matches the
plan's look-and-feel decision, when it names one.

**2. Colours (Claude suggests).** Picking a style starts the **look turn** (Opus, $3). It reads `PLAN.md` and writes
three things to `design/`:
- the start screen as `screens/<start>/v1.html`, in the chosen style;
- `look/palettes.json`: **four colour themes** for this app and this style, each with a name, a mood line, why it
  suits the app, and full light and dark schemes;
- `look/fonts.json`: **three font pairings** (display + body), from the style's shortlist or the wider catalog, each
  with why.

The window shows the start screen with each colour theme applied, side by side, in light or dark. Switching theme
or font only swaps `tokens.css` under the same HTML, so trying every combination is instant and free. The app
checks every theme for contrast (4.5:1 for text roles against their surfaces) and hides one that fails, with a
note to Claude. Under the cards:
- **More like this** / **Something different**: a small Sonnet turn ($0.50) that rewrites `palettes.json`, told which
  themes were already shown.
- **Use my colour…**: a colour picker; Claude builds the four themes around that colour instead.
- Typing works too ("warmer", "our brand is #E4572E").

**3. Fonts (pick a pairing).** Cards show each pairing as a specimen (headline, body, a button) and on the start
screen. **More fonts** asks again, like colours. The catalog is a snapshot of Google Fonts' metadata bundled with the
app (`Resources/google-fonts.json`: family, category, weights), refreshed by a script, so suggestions are checked
offline and Claude can't name a font that doesn't exist.

**Use this look** writes `design/tokens.json` (style defaults + the chosen theme + the chosen fonts, an app write in a
checkpoint) and moves on to the other screens. The look can be changed at any time from the toolbar; already drawn
screens follow, because they only use tokens.

**Fonts in the mockups.** The web view has no network. When a font is chosen, the app downloads its files once
(`GoogleFontsService`, cached in Application Support, logged) and copies them into `design/fonts/` with the licence.
`tokens.css` points `@font-face` at them. Offline, or on a failed download, the mockup falls back to the system font
and the card says "Couldn't download Fraunces. Showing the system font."

**Where the files come from.** `GoogleFontsService` asks `fonts.googleapis.com/css2?family=Fraunces:wght@400;600;700`
**without a browser's user agent**, which makes the API answer with static `.ttf` files, one per weight. Tested on
2026-11-02: an old Chrome agent gets WOFF files split by script, which Flutter can't use. The same TTFs work in the web
view and in Flutter. The CSS gives opaque `fonts.gstatic.com` URLs, so the app saves each
file as `Family-Weight.ttf` (`Fraunces-SemiBold.ttf`), the name the `google_fonts` package looks for in its assets
(`GoogleFontFile.name(family:weight:italic:)`, pure and tested). This depends on how the API treats user agents, which
isn't documented, so the service checks it got TTF and otherwise reports the font as not downloaded (the mockups
show the system font). Falling back to the `google/fonts` repository is can have.

## 4. The design call

`ChatMode.design` (a new case; unknown values already decode as `.build`). `ChatModel.designCall`:

| | Look turn | More colours / fonts | Screen turns (new or versions) | Current turn (redesign) |
|---|---|---|---|---|
| Model | Opus (taste matters most here) | Sonnet | Sonnet | Sonnet |
| Budget | $3 | $0.50 | $2 | $2 |
| Tools | Read, Glob, Grep, Edit, Write. **No Bash.** | same | same | same |
| Edits | only `design/**` | only `design/look/**` | only `design/**` | only `design/**` |
| Reads also | `AgentBridge.screenshotDirectory`, the rendered previews | same | same | same, plus the captured `current.png` |

**The app names the files.** Each turn's prompt says exactly which files to write ("Write
design/screens/home/v4.html and v5.html, starting from v2.html"). `DesignVersions` picks the numbers, so Claude never
overwrites a version, and the after-turn `FileSnapshot` check flags any change to an existing `v*.html`.

**Edits limited to `design/`.** Today every call runs with `--permission-mode acceptEdits`, which accepts any edit
inside the project before `AgentPermissionPolicy` sees it. The design call instead uses `--permission-mode default`
with `--allowedTools Read Glob Grep "Edit(design/**)"`, and `asksForApproval`. An edit under `design/` is accepted by
the CLI; any other edit arrives as a `can_use_tool` request, and the policy refuses it without asking: "In design
mode Claude only changes files in design/." `ClaudeAgentCall` gains `editablePattern: String?` (nil keeps today's
arguments exactly); a test pins both argument lists. As a backstop, after each design turn `FileSnapshot` is
checked: a change outside `design/` is logged and shown as a warning with Undo.

**System prompt** (the design prompt keeps the two-part answer rule and `choices` blocks):

1. Read `PLAN.md`, `design/README.md`, `design/tokens.json`, the chosen style's guidance, and the screens already
   drawn. Fit the style: a Minimal screen has fewer elements, not just other colours.
2. Use only the kit and the tokens (the vocabulary above). Real copy from the plan or the app. Write only the files
   the prompt names, each with `<meta name="ms-screen" content="Home">`, and say in one line what each version tries.
3. Each screen is a phone screen at a fixed 393 × 852 pt (iPhone 15 and 16 Pro), whatever simulator is selected:
   status bar space at the top, home indicator space at the bottom (the kit's `.screen` gives both). A `current.png`
   from a different simulator is scaled to that width for comparison, and its size noted, not used as the canvas.
4. Fix the lint and token issues listed in the prompt first.
5. End with what changed, in plain words, and at most one `choices` block.

**One agent at a time per project.** The build chat and the design chat both snapshot the whole folder, so two turns
at once would each claim the other's changes. `chatBlocker` gains "Claude is designing. Wait for it to finish." and
`designBlocker` the opposite. Both chats stay usable for reading.

## 5. Versions

Each screen keeps its versions in `screen.json`, which the app writes and Claude never touches (`DesignVersions`,
pure, `Codable`):

```swift
struct DesignVersions: Codable, Equatable, Sendable {
    struct Version: Codable, Equatable, Sendable {
        let id: String           // "v3"
        let parent: String?      // "v1", or "current"; nil for a screen's first drawing
        let request: String      // the user's words: "Make the total bigger"
        let summary: String      // Claude's one line on what this version tries
        let round: Int           // versions from one request share a round ("show me three")
        let messageID: UUID      // the chat answer that made it, for Undo
    }
    var versions: [Version]
    var chosen: String?          // the reference for the build
    var inApp: String?           // the version last applied to the app, or "current"
    var sourceHash: String?      // the screen's Dart file when current.html was drawn (redesigns)
}
```

- **Next ids:** `nextIDs(count:)` gives the file names the prompt asks for. A request starts from the version on
  screen when it was typed (its `parent`), not always the newest.
- **Chosen:** the newest version of a round becomes chosen until the user picks another with **Choose**.
- **Undo:** the app writes `screen.json` before the after-snapshot (as it does `PLAN.md`), so undoing an answer
  removes its versions and their entries together. A `screen.json` that names a missing file reads as without it.
- **What the user sees:** selecting an artboard opens its **version strip** under the canvas: *Current* (for
  redesigns), then v1, v2, … as thumbnails with the request under each, grouped by round, with Chosen and In the app
  marked by `StatusBadge`. Click one to show it on the artboard; **Compare** puts two side by side, at the same zoom.

## 6. Redesigning an existing screen

**Entry points** (all call `Workspace.redesign(screen:)`, gated by `designBlocker`; the screen is an `AppScreen`
from `FlowFinder`, so this works in any project App Flow can read):

- The Screens list's context menu (`ScreenMenu`) and a real screen's card in App Flow: **Redesign…**
- The device canvas: **Redesign This Screen** (canvas context menu and Product menu). It captures the simulator's
  current frame first, the same way `ms-sim screenshot` does, and asks which screen it is from the App Flow list.
- The Design window itself: in a project without a plan, the canvas lays out App Flow's screens, and an artboard
  with nothing drawn yet offers **Redesign**.

**1. Capture.** With a picture from the device, it's saved as `current.png`. Coming from the Screens list or App
Flow, the window says "Show this screen in the app and press Capture for a truer starting point." Capture is
optional: without it, Current is drawn from the code alone.

**2. Draw Current.** One Sonnet turn reads the screen's Dart file (`AppScreen.file`), the widgets it uses and the
app's theme, and redraws it as `current.html` in the kit. It records the file's hash in `sourceHash`.
- A project without `design/tokens.json` gets one in the same turn, taken from its `ThemeData`, with the nearest
  style. Where colours are hard-coded across files, Claude uses the most-used values and says so. An app that uses the
  platform font gets `"system"` as its font (`ThemeRenderer` then sets no family); one with its own bundled font
  keeps it in the mockups only if the app can read the file, else the system font with a note.
- Anything the kit can't show (custom painters, charts, maps, real images) becomes a labelled placeholder: "Chart of
  the week's drinks".
- The window shows the mockup next to `current.png`, labelled *Mockup* and *In the app*, so a mismatch is visible
  before anything is built on it. "The list is missing" is a request like any other, but it redraws `current.html`
  instead of making a version.

**3. Ask for changes.** Requests make versions with `current` as their first parent. Versions can't change the
tokens. A request for another style, other colours or other fonts is app-wide, so Claude says so and offers
**Restyle the whole app**: the look step of section 3, with **Current** (the app's own colours and fonts) as the
first card of the colour and font rows, picked by default.

**4. Apply to the app.** **Choose** a version, then **Apply to the app** sends a build turn with three references:
`current.html`, the chosen version and `current.png`. The prompt asks Claude to **change only what differs between
current.html and v3.html**, in `AppScreen.file`. Both mockups use the same vocabulary, so their difference is a
precise change list, and the rest of the screen is left alone. When that answer changes files without an error, the
version is marked `inApp`; undoing the answer unmarks it, as milestones do.

**5. Staying true to the code.** When the screen's Dart file no longer matches `sourceHash` (the user or Claude
changed it since), Current shows "The app changed since this was drawn" and **Redraw from the app**. After an apply,
the next request starts from the applied version, so a second round doesn't need a redraw.

## 7. The Design window

A second `Window` scene (`id: "design"`) next to `"main"`, always for the open project, opened through `openWindow` from
`StudioCommands` and the buttons. Layout, like Claude Design:

```
┌ toolbar: look/screens · light|dark · zoom · Use this design ───────────────┐
│ chat (design mode)  │  canvas: artboards in plan order, pan/zoom          │
│                     │  ┌─────┐ ┌─────┐ ┌─────┐                           │
│                     │  │Home │ │Add  │ │Stats│   each: name, status badge │
│                     │  └─────┘ └─────┘ └─────┘   (Drawn / Built / Issues) │
│                     ├─────────────────────────────────────────────────────┤
│                     │  Home: Current · v1 · v2 · v3 ✓   Compare  Choose   │
│                     │        version strip of the selected screen         │
└─────────────────────┴─────────────────────────────────────────────────────┘
```

- **Chat:** a second `ChatModel` owned by `Workspace` (`designChat`), with its own transcript in `Chats/` and its own
  Undo. The transcript rows are shared: `MessageRow` takes a `ChatRowActions` (the model, undo, choose, diff) instead
  of reading `workspace.chat`.
- **Canvas:** the screens side by side in a scroll view, with zoom in the toolbar. Reusing App Flow's `FlowViewport`
  pan and pinch is can have.
- **Look rows:** during the look step the canvas shows the style, colour and font rows above the start screen, each
  card an artboard of its own. Switching a card only swaps the tokens the artboards load.
- **Artboards** (`ArtboardView`, `NSViewRepresentable` around `WKWebView`): pages load through a
  `WKURLSchemeHandler` (`ms-design://`, `DesignSchemeHandler`) that serves only files inside `design/` and the app's
  bundled kit fonts, and refuses `..` and everything else, so nothing reaches the network or the rest of the disk.
  `allowsContentJavaScript = false`. The app's own scripts still run
  (in `WKContentWorld.defaultClient`), which is what selection and Point at use. The light/dark toggle sets the view's
  `appearance`, and `tokens.css` switches on `prefers-color-scheme`. Files are watched, so an artboard reloads as
  Claude writes it.
- **Previews:** `DesignRenderer` snapshots each artboard after a turn (`takeSnapshot`, 2×, light and dark) into
  `ProjectStorage.directory("Design", for: folder)`, outside the repo. Those PNGs feed the App Flow cards, the build
  handoff, and Claude's own next turn.

## 8. Handing off to the build

- **References per milestone:** a pure `DesignHandoff.references(for: milestone, plan:, library:)` goes from milestone
  → features → screens → each screen's chosen version. `Workspace.buildMilestone` adds them to the prompt: "Designs for this
  milestone: design/screens/home/v2.html (preview: …/home-v2-light.png)." The preview folder is added to
  `readableFolders`. A redesign's apply turn uses `DesignHandoff.redesign(screen:version:)` instead (section 6).
- **Build prompt, one line:** "If a screen has a design in design/screens, it is the reference: match its layout,
  spacing, copy and components using design/README.md's mapping and Theme.of(context), never literal values. After
  building it, take an ms-sim screenshot and compare it with the preview."
- **App Flow:** planned cards show the design's preview instead of the placeholder symbol
  (`ScreenCard`), so the map becomes the design overview.
- **Status:** an artboard is *Built* when `AppFlow` finds a real screen with its name (the same match
  `AppFlow.adding(_:)` uses).

## Files

| New | Layer | What |
|---|---|---|
| `Design/DesignTokens.swift` | value | tokens, validation, contrast check, `TokensCSS`, `ThemeRenderer` |
| `Design/DesignLint.swift` | value | vocabulary check of one screen's HTML |
| `Design/DesignLibrary.swift` | value + I/O | scans `design/`, maps folders to plan and App Flow screens; `DesignHandoff` |
| `Design/DesignVersions.swift` | value + I/O | `screen.json`: versions, rounds, chosen, in app, next ids, source hash |
| `Design/DesignStyle.swift` | value | the bundled styles, their default tokens and prompt guidance |
| `Design/LookSuggestions.swift` | value | `palettes.json` and `fonts.json`: decode, contrast filter, combining into tokens |
| `Design/GoogleFonts.swift` | value + service | the bundled catalog and its checks; `GoogleFontsService` downloads and caches font files |
| `Design/PubspecAssets.swift` | value | adds the fonts folder to `pubspec.yaml`'s assets, idempotent |
| `Design/DesignSchemeHandler.swift` | service | `ms-design://`: serves `design/` and the kit fonts only |
| `Design/DesignModel.swift` | model | phase (`DesignPhase`: empty, look(step), screens, approved), selection, shown and compared versions, previews |
| `Design/DesignRenderer.swift` | service | offscreen `WKWebView` snapshots |
| `Views/DesignWindow.swift` | view | window layout, toolbar |
| `Views/DesignCanvas.swift`, `Views/ArtboardView.swift` | view | artboards on the shared viewport |
| `Views/VersionStrip.swift` | view | the selected screen's versions, Compare, Choose, Apply to the app |
| `Resources/Templates/design/**` | resource | `kit.css`, `README.md`, the Material Icons font and its list of names, `styles/<id>/` (style + sample) |
| `Resources/google-fonts.json`, `scripts/update-google-fonts.sh` | resource | the Google Fonts catalog snapshot and the script that refreshes it |

| Changed | What |
|---|---|
| `App/Workspace.swift` | `designChat`, `openDesign()`, `redesign(screen:)`, `captureCurrent(for:)`, `designBlocker`, `chooseStyle`, `choosePalette`, `chooseFonts`, `moreSuggestions`, `useLook()`, `approveDesign()`, `applyDesign(to:)`; one-agent-at-a-time in `chatBlocker`; handoff in `buildMilestone` |
| `Views/Components.swift`, `Views/SimulatorView.swift` | Redesign… in `ScreenMenu`; Redesign This Screen on the device canvas |
| `App/MobileStudioApp.swift`, `App/StudioCommands.swift` | the Design window scene; Window ▸ Design ⌥⌘D |
| `ClaudeCLI/ClaudeAccess.swift` | `ClaudeAgentCall.editablePattern` → `--permission-mode default` and `Edit(<pattern>)` |
| `ClaudeCLI/AgentPermission.swift` | refusal message for edits outside the design folder |
| `Chat/ChatModel.swift` | `ChatMode.design`, `designCall`, design prompt, build prompt line |
| `Chat/ProductPlan.swift` | `designLabel` in `nextSteps` |
| `Views/ChatView.swift` | `MessageRow` takes `ChatRowActions` instead of reading `workspace.chat` |
| `Views/FlowView.swift` | previews on cards, *Design this screen* on planned cards, *Redesign…* on real ones |
| `App/AppDelegate.swift` | `MOBILE_STUDIO_SNAPSHOT_DESIGN=1` snapshots the Design window |
| `AGENTS.md` | Design section, design mode rules, the vocabulary |

## Tests (pure layer)

- `DesignTokens`: decode, every validation issue (hex, missing role, contrast), a valid set has none.
- `TokensCSS`: every role and size becomes a variable, light and dark blocks, `@font-face` per font file, a system
  font fallback when a file is missing.
- `ThemeRenderer`: renders a `theme.dart` with every role, `GoogleFonts.getTextTheme`/`getFont` for the families (none
  for `"system"`), elevation, borders and density; Dart string escaping; same input, same output.
- `DesignStyle`: every bundled style decodes, and its default tokens are valid and pass the contrast check.
- `LookSuggestions`: decode, a theme failing contrast is dropped with a reason, a font not in the catalog is dropped,
  combining a style, a theme and a pairing gives valid tokens.
- `GoogleFonts` catalog: lookup ignores case, missing weights reported, the CSS API URL for a family and its weights.
- `PubspecAssets`: adds the folder under an existing `flutter:` / `assets:`, creates them when missing, keeps
  comments, idempotent.
- `DesignSchemeHandler` path resolution (pure `DesignURL.resolve`): `..`, absolute paths and other schemes refused.
- `DesignLint`: each forbidden thing found once, kit overlays allowed, an icon name not in Flutter's `Icons` flagged,
  a clean screen has no issues.
- `GoogleFontFile.name`: every weight and italic gives the file name `google_fonts` expects (`Inter-Regular.ttf`,
  `Inter-SemiBoldItalic.ttf`); the CSS parser takes one TTF URL per weight and reports WOFF2 as the wrong format.
- `DesignLibrary`: meta tag beats file name, unknown screens listed apart, plan screen names matched like
  `AppFlow.adding(_:)`.
- `DesignVersions`: next ids never reuse a file, rounds group, newest of a round becomes chosen, a missing file drops
  its entry, an older `screen.json` decodes.
- `DesignHandoff`: milestone → only its screens' chosen versions, missing designs skipped; a redesign lists
  `current.html`, the chosen version and `current.png` (when captured) in that order.
- `ClaudeAgentCall` with `editablePattern`: `--permission-mode default`, `Edit(design/**)` in `--allowedTools`, no
  Bash; without it, arguments unchanged.
- `AgentPermissionPolicy`: an edit outside `design/` in design mode is refused with the design message.
- Not unit tests: the web view rules and rendering (snapshot run), and the CLI's pattern matching (below).

## Phases

0. **Fidelity spike, no code.** In today's build chat, on a throwaway project: mock up three screens as HTML with a
   first draft of `kit.css`, then build them. Then the other way: redraw one existing screen as `current.html`, change
   it, and ask for only the difference. Compare side by side. What didn't translate goes into the vocabulary and the
   lint. **If the builds don't come out close, stop here and rethink the format.**
**Order: redesign first.** Phases 1–5 ship redesign for every existing project before the look step exists. That
proves the hardest loop (Dart → `current.html` → versions → applying the difference to the Dart) without font
downloads, `pubspec.yaml` changes or the look cards. *Restyle the whole app* arrives with phase 6.

1. **Values + tests:** tokens (with `"system"` fonts), the two renderers, lint (with icon names), library, versions,
   handoff.
2. **Design call:** `ChatMode.design`, `editablePattern`, policy, prompt, the kit template written into `design/` on
   first open. Checked with a stand-in CLI, then once with the real CLI on a throwaway project to confirm
   `Edit(design/**)` matches (a few cents).
3. **Window and canvas:** scene, artboards, `ms-design://` handler, file watching, previews, light/dark. Snapshots
   in light and dark.
4. **Versions:** `screen.json`, app-chosen file names, the version strip, Compare, Choose, Undo, batches of up to four
   screens per turn.
5. **Redesign:** entry points, Capture, the Current turn (with tokens from `ThemeData`), Mockup / In the app,
   Apply to the app with the difference prompt, `sourceHash` and Redraw.
6. **Look and approval:** styles, suggestions, font catalog and pubspec values with their tests; the six styles and
   their samples, the look turn, colour and font cards, More / Use my colour, font downloads (check the TTF path
   first, with the fallback), Use this look; Use this design → `google_fonts`, bundled fonts, `theme.dart`;
   Restyle the whole app; the plan's next step.
7. **Handoff:** references in Build milestone, previews on App Flow cards, *Built* status.
8. **Can have** (below).

Each phase ends with zero warnings, tests green, and AGENTS.md updated.

---

## Decisions (proposed)

| Decision | Choice | Why | Alternative |
|---|---|---|---|
| Where it lives | Its own window (asked for) | Room for many artboards next to a chat; the main window stays on the running app | A third canvas mode (Device / App Flow / Design) |
| Mockup format | Restricted HTML + a component kit | Instant to render and change; Claude's strongest format | Dart screens in a gallery app (exact, but every change waits on a build); a JSON spec drawn in SwiftUI (limited) |
| Source of style | `tokens.json` → `tokens.css` and `theme.dart` | One source, so mockup and app colours can't disagree | Claude writes `theme.dart` itself |
| Folder | `design/` at the root, in git | Visible, diffable, read by the build turn and outside agents | App Support (hidden) |
| Previews | PNGs in App Support | Keeps the repo text-only; regenerated from the HTML at any time | Committed under `design/` |
| Writes | Only `design/**`, no Bash | Designing can't touch code | The build call's permissions |
| Who writes the theme | The app, on Use this design: `design_theme.dart`, and the project's `theme.dart` pointed at it | Predictable, undoable, in one hot reload, and keeps what else the project's theme file holds | Every design turn (the app changes colour while the user is still choosing) |
| Design → code | Only by button (Use this design, Apply to the app) | The two never drift silently | Rebuild on every design change |
| Choosing the look | Style, then colours, then fonts, as cards | Three small choices are easier than judging whole directions; colours and fonts swap tokens under one drawing, so trying them is free | Three complete directions drawn by Claude (about three times the cost) |
| Styles | Six bundled presets with free local samples, plus Describe your own | Seeing every style costs nothing; a style is data, so adding one is easy | Claude invents a style each time |
| Colour themes | Claude suggests four per style; the app checks contrast; Use my colour | Suggestions fit the app and the style; nobody gets an unreadable theme | A fixed palette library; a seed colour only |
| Fonts | Google Fonts, checked against a bundled catalog, bundled into the app on Use this design | Huge choice, free licences, works offline and in store builds | System font only; `google_fonts` fetching at run time (fails offline, first launch flashes) |
| Mockups and the network | `ms-design://` serves `design/` only; the app downloads fonts into `design/fonts/` | The page never touches the network or the disk outside `design/` | Allow `fonts.googleapis.com` in the web view |
| Models | Opus for the look turn, Sonnet for everything else | Taste up front, cheap iteration | Sonnet throughout |
| Agents at once | One per project | `FileSnapshot` covers the whole folder | Two, with per-folder snapshots |
| Versions | New files per request, never edited; app names them | Nothing liked is lost; any two compare; Undo stays per turn | Edit in place and rely on Undo |
| Redesign's starting point | Claude redraws the code as `current.html`, beside the captured picture | Changes need an editable mockup in the same vocabulary; the picture shows what the redraw missed | The screenshot alone (can't be edited); the Dart alone (no picture to check against) |
| Redesign → code | Change only the difference between Current and the chosen version | Keeps the rest of the screen untouched | Rebuild the screen from the version |
| Which screen a capture is | The user picks from App Flow's list | Always right, no extra cost | Claude identifies it from the picture |
| Style in a redesign | Versions can't change tokens; Restyle the whole app instead | Colours are app-wide; a per-screen colour change would fork the theme | Per-screen token overrides |

## Must have / can have (for this feature)

**Must have:** the kit and the vocabulary; tokens with validation and contrast check; lint fed back to Claude; design
mode limited to `design/`; the Design window with chat, pan/zoom artboards, light/dark; the look step (six styles
with free samples, four suggested colour themes with a contrast check, More and Use my colour, three Google Fonts
pairings, Use this look); Google Fonts in the mockups and bundled into the app;
screens for every planned screen; selection-scoped messages; versions with rounds ("show me three"), the version
strip, Compare and Choose; Undo per turn; Use this design → `theme.dart`; references in Build milestone; previews on
App Flow; **redesign of existing screens** (Capture, Current as mockup and picture, versions, Apply to the app as a
difference, Redraw when the code changed), in projects with or without a plan; one agent at a time; logs
(`DiagnosticLog(name: "design")`).

**Can have:** *Point at* on an artboard (the app's script finds the element and attaches its snippet and a crop);
an `ms-design render <screen>` command through `AgentBridge`, so Claude checks its own render (and Current against
`current.png`) inside a turn; Claude identifying which screen a capture shows; capturing the screen by having the
build agent navigate there with `ms-sim`; a Compare view of a version next to the live simulator; editing tokens by
hand in an inspector (swatches, type scale); more styles (Glass, Retro, Dark-first, …); a font browser over the whole
catalog; hiding old versions; exporting the designs as a PDF to share.

**Not now:** importing from Figma; free-form drawing; designs for iPad or Android sizes; animations and transitions.

## Answered (2026-11-02)

1. **Styles:** keep the six: Minimal, Soft, Bold, Editorial, Playful, Classic. Between them they cover density, border
   weight, corner radius, shadow depth and serif against sans. A dark-first or glass style is can have; every style
   already has dark mode through its tokens.
2. **Icon font:** the full font, no subset, so no valid icon name renders as raw text. It is Flutter's own **Material
   Icons** font rather than Material Symbols: Symbols has names `Icons` doesn't, which would draw in the mockup and
   fail in the build. The lint checks names against the bundled `Icons` list. The font only lives in the Mac app and
   is never shipped in the user's app.
3. **Artboard size:** fixed at 393 × 852 pt, whatever simulator is selected, so artboards line up side by side, and
   prompts and previews stay comparable over time. A capture from another simulator is scaled for comparison.
4. **Redesign first:** yes. Phases 1–5 ship redesign; the look step (phase 6) follows once redraw, versions and apply
   work reliably.
5. **Several screens at once:** one turn for all selected screens, up to four, so a change reads the same everywhere.
   The versions share a round and the answer's `messageID`, so one Undo reverts the batch.
6. **Font files:** the `css2` API, saved under the names `google_fonts` expects. Checked on 2026-11-02: the suggested
   old desktop Chrome user agent returns split WOFF files, not TTF; **no browser user agent** returns one TTF per
   weight, so that is what the service sends. The `google/fonts` repository stays a possible fallback.
