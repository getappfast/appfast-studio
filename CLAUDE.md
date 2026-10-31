@AGENTS.md

## Claude Code notes

`AGENTS.md` above is the full guide and applies as written. These notes are only about working here with
Claude Code.

- After creating, moving or deleting a Swift file, run `xcodegen generate` before building, or Xcode won't see it.
- Prefer `xcodebuild … test` over reasoning about whether a parser change is safe; the pure layer is covered.
- To see the app, build it and use `open` on `Mobile Studio.app` in the build products. The user may already
  have a copy running; launch yours with `open -n` and quit only yours.
- The app runs `claude` itself, with `--safe-mode`. Your own skills, hooks and MCP servers don't reach those
  runs, so don't rely on them when debugging what the in-app agent did. Read
  `~/Library/Logs/Mobile Studio/chat.log` and `claude-fix.log` instead.
- Don't run `flutter run` in a user's project from here: the app owns that process.
