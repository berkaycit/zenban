# Zenban

A macOS kanban board application built with SwiftUI.

## Requirements

- macOS 15.6+
- Xcode 26.2+
- Swift 5.0+
- zig

## Building from Source

Zenban uses the terminal code and runtime assets that are already vendored or copied into this repository.

### 1. Prepare Ghostty dependencies

```bash
./scripts/setup.sh
```

This prepares `GhosttyKit.xcframework` from the repo's local `ghostty` tree and reuses the bundled runtime assets under `Resources/` and `vendor/`.

### 2. Build Zenban

```bash
open zenban.xcodeproj
# Build and run (Cmd+R)
```

Or from the command line:
```bash
xcodebuild -project zenban.xcodeproj -scheme zenban -configuration Debug build
```

## Terminal Status

Embedded Ghostty is enabled. Zenban ships the Ghostty runtime and cmux-derived workspace stack from assets already stored in this repo, packages them with the `Copy Ghostty Resources` build phase, and reads the user's standard Ghostty config files.

Each card maps to a cmux-style workspace. For git boards, cards get their own worktrees; the workspace uses the worktree path when available and otherwise starts from the board repo path until worktree setup finishes. Card switches reuse suspended surfaces and stay in sync with Ghostty light/dark theme selection driven by macOS appearance and `window-theme`.

## Bundle Identifier

`com.berkaycit.zenban`

## Claude Code Integration

Zenban automatically moves cards between columns based on Claude Code activity:
- **User sends prompt** -> Card moves to "To Do"
- **Claude stops** -> Card moves to "In Review"

### Setup

**Automatic:** In Zenban, go to **Zenban > Install Claude Code Hooks** to automatically configure the required hooks.

**Manual:** Add the following hooks to your `~/.claude/settings.json`:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "[ -n \"$ZENBAN_TERMINAL\" ] && open 'zenban://prompt-submitted'"
          }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "[ -n \"$ZENBAN_TERMINAL\" ] && open 'zenban://notify?body=Task%20Completed'"
          }
        ]
      }
    ]
  }
}
```

The `$ZENBAN_TERMINAL` environment variable is automatically set when Claude Code is launched from within Zenban. This ensures the hooks only trigger for sessions started from the Zenban terminal, not from other terminals or projects.

This requires Zenban to be running for the URL scheme to work.
