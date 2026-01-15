# Zenban

A macOS application built with SwiftUI.

## Requirements

- macOS 15.6+
- Xcode 26.2+
- Swift 5.0+
- Zig (for building libghostty): `brew install zig`

## Building from Source

```bash
git clone https://github.com/berkaycit/zenban.git
cd zenban

# Build libghostty (universal arm64 + x86_64)
./scripts/build-libghostty.sh

# Open in Xcode and build
open zenban.xcodeproj
```

To rebuild libghostty at a specific commit:
```bash
./scripts/build-libghostty.sh <commit-sha>
```

## Bundle Identifier

`com.berkaycit.zenban`

## Claude Code Integration

Zenban automatically moves cards between columns based on Claude Code activity:
- **User sends prompt** → Card moves to "To Do"
- **Claude becomes idle** → Card moves to "In Review"

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
    "Notification": [
      {
        "matcher": "idle_prompt",
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
