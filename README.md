# Zenban

A macOS kanban board application with integrated terminal, built with SwiftUI.

## Requirements

- macOS 15.6+
- Xcode 26.2+
- Swift 5.0+

## Building from Source

### 1. Build GhosttyKit.xcframework

Zenban uses Ghostty as its embedded terminal emulator. You need to build the xcframework from the [Ghostty](https://github.com/ghostty-org/ghostty) source:

```bash
# Clone ghostty (if you don't have it)
git clone https://github.com/ghostty-org/ghostty.git
cd ghostty

# Build the xcframework (requires zig: brew install zig)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  zig build -Demit-xcframework=true -Doptimize=ReleaseFast

# Copy to Vendor/
cp -R macos/GhosttyKit.xcframework /path/to/zenban/Vendor/
```

### 2. Build Zenban

```bash
open zenban.xcodeproj
# Build and run (Cmd+R)
```

Or from the command line:
```bash
xcodebuild -project zenban.xcodeproj -scheme zenban -configuration Debug build
```

## Terminal Configuration

Zenban loads your standard Ghostty configuration from `~/.config/ghostty/config`. All terminal settings (font, theme, colors, keybindings) are configured there -- no separate settings UI in Zenban.

If no Ghostty config exists or it has errors, Zenban falls back to default settings.

Shell integration is injected automatically for zsh shells via ZDOTDIR override.

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
