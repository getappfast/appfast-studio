# Mobile Studio

A native macOS app for building Flutter apps with a coding agent. Your project, a live iOS Simulator and a
Claude Code chat sit in one window: ask for a change, watch it hot-reload, and tap a widget on the simulator to
show Claude exactly what you mean.

## Features

- **Live simulator in the window.** Boot any installed iOS Simulator and see its screen in the app. Click to
  tap, drag to swipe. There's no Simulator.app window and no screen-recording permission involved.
- **Run and Hot reload.** One button runs the project on the selected simulator. Mobile Studio also finds an
  app left running by an earlier run or a terminal and reconnects to it.
- **Chat with Claude Code** in your project folder. Changed files are listed from the disk itself, not from
  what Claude says it did.
- **Pick.** Tap an element in the running app to attach its widget and source location to your next message.
- **Fix with Claude.** When a run fails, Claude finds the cause, makes the smallest fix, and the app runs
  again to check it.
- **Project check.** Claude (read-only) confirms the folder is a Flutter app and lists its run flavors.
- **Several Claude accounts.** Add accounts in Settings and switch between them. Check which models each one
  can use.

## Requirements

- macOS 14 or later, and Xcode with an iOS Simulator runtime
- [Flutter](https://docs.flutter.dev/get-started/install/macos) on your `PATH`
- The [Claude Code CLI](https://docs.claude.com/en/docs/claude-code), signed in:
  ```bash
  curl -fsSL https://claude.ai/install.sh | bash
  ```
- [XcodeGen](https://github.com/yonaskolb/XcodeGen), to build from source:
  ```bash
  brew install xcodegen
  ```

## Build and run

```bash
xcodegen generate
```

```bash
xcodebuild -project MobileStudio.xcodeproj -scheme MobileStudio build
```

Or open `MobileStudio.xcodeproj` in Xcode and press ⌘R. Run the tests with:

```bash
xcodebuild -project MobileStudio.xcodeproj -scheme MobileStudio test
```

`MobileStudio.xcodeproj` is generated from `project.yml`. Edit `project.yml`, not the project.

## Using it

1. Open **Settings (⌘,)** and check that the Claude CLI is found and an account is signed in.
2. Click **Choose folder…** and select your Flutter project, the folder that contains `pubspec.yaml`.
3. Pick a simulator, then click **Boot**.
4. Click **Run on <device>**. Once it's running, use **Hot reload** and **Pick**, or just chat.

## How it works

| Area | Folder | Notes |
|---|---|---|
| App shell | `MobileStudio/App` | Composition root, `Workspace` (the main window's models and the rules between them) |
| Views | `MobileStudio/Views` | SwiftUI, layout only |
| Project and run | `MobileStudio/Project` | Folder inspection, `flutter run`/`attach`, output parsing, Fix with Claude, file snapshots |
| Chat | `MobileStudio/Chat` | Conversation per project folder, saved in Application Support |
| Claude CLI | `MobileStudio/ClaudeCLI` | Finding the CLI, account access, safe agent calls, parsing its event stream |
| Simulator | `MobileStudio/Simulator` | `simctl`, and an Objective-C bridge to CoreSimulator's framebuffer and input |
| Inspector | `MobileStudio/Inspector` | Pick, over the Dart VM service and Flutter's widget inspector |
| Core | `MobileStudio/Core` | Process running, logs, shell `PATH`, shared extensions |

Read [AGENTS.md](AGENTS.md) for the architecture rules and conventions.

### Safety

Mobile Studio runs Claude with edit access to your project, so every call is restricted:

- It runs in safe mode, so your machine's plugins, skills, MCP servers and hooks stay off.
- Edits are limited to the project folder, and shell commands to an allow-list: `flutter pub/build/analyze/test`,
  `dart format/analyze/fix`, `pod`, and read-only `git`.
- Each call has a spending cap and a timeout.
- The project check is read-only.

The app is not sandboxed, because it has to run your `claude`, `flutter`, `xcrun` and `git`. The live simulator
view uses Apple's private CoreSimulator framework, so a new Xcode can break it. When it does, the app shows an
error rather than crashing.

### Logs

Every run, check, chat and fix writes the exact command and output to `~/Library/Logs/Mobile Studio/`. Each
failure in the app has a **Show log** button.
