# Zenban

A macOS kanban board application built with SwiftUI.

## Requirements

- macOS 15.6+
- Xcode 26.2+
- Swift 5.0+

## Building from Source

### 1. Build Zenban

```bash
open zenban.xcodeproj
# Build and run (Cmd+R)
```

Or from the command line:
```bash
xcodebuild -project zenban.xcodeproj -scheme zenban -configuration Debug build
```

## Terminal Status

Embedded Ghostty is enabled. Zenban ships the Ghostty runtime and resource layout copied from the `cmux` project, packages them with the `Copy Ghostty Resources` build phase, and reads the user's standard Ghostty config files.

Each card terminal starts in its board or worktree directory, reuses suspended surfaces when switching cards, and now stays in sync with Ghostty light/dark theme selection driven by macOS appearance and `window-theme`.

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
