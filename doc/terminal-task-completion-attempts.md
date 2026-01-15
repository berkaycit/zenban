# Terminal Task Completion Detection - Experiments Log

## Goal
Automatically move a card to "In Review" when an agent task finishes in the
embedded Ghostty terminal.

## Attempts (failed approaches)
1) Ghostty command-finished action
   - Existing `GHOSTTY_ACTION_COMMAND_FINISHED` path already drives
     `handleCommandFinished` -> `onTaskCompleted`.
   - Result: not triggered for long-running agent tasks; no card move.

2) Ghostty desktop notification action (OSC 9)
   - Added handling for `GHOSTTY_ACTION_DESKTOP_NOTIFICATION` to trigger
     `onTaskCompleted` (focus bypassed).
   - Explicitly set `desktop-notifications = true` in Ghostty config.
   - Added `NotificationService` call on desktop notification action.
   - Result: libghostty does NOT emit DESKTOP_NOTIFICATION action for OSC 9
     sequences in embedded usage. The action handler exists but never fires.

3) Claude Code Stop hook emitting OSC 9
   - Added `.claude/hooks/task_completed_notify.sh` to emit:
     `ESC ] 9 ; <message> ESC \`.
   - Added `.claude/settings.json` Stop hook to run the script.
   - Result: Hook commands run in separate processes - their stdout doesn't
     reach the embedded terminal's TTY.

## Working Solution: URL Scheme + Claude Code Hooks

### Implementation
1. Registered `zenban://` URL scheme in Info.plist
2. Added `.onOpenURL` handler in zenbanApp.swift to process `zenban://notify` URLs
3. Configured Claude Code Stop hook in `~/.claude/settings.json`:
   ```json
   {
     "hooks": {
       "Stop": [{
         "matcher": "",
         "hooks": [{
           "type": "command",
           "command": "open 'zenban://notify?body=Task%20Completed'"
         }]
       }],
       "Notification": []
     }
   }
   ```

### How it works
- Claude Code Stop hook runs when agent finishes
- `open` command triggers macOS URL handling
- SwiftUI `.onOpenURL` receives the URL
- Shows notification with card title and moves card from To Do to In Review

### Files modified
- `zenban/Info.plist` - CFBundleURLTypes for zenban:// scheme
- `zenban/zenbanApp.swift` - handleZenbanURL for notification and card move
- `zenban/Terminal/GhosttyTerminal/Ghostty.App.swift` - DESKTOP_NOTIFICATION handler
- `~/.claude/settings.json` - Stop hook configuration

## References
- Ghostty config reference: https://ghostty.org/docs/config/reference
- Ghostty OSC 9 spec: https://ghostty.org/docs/vt/osc/9
- iTerm2 escape codes (OSC 9 notifications): https://iterm2.com/documentation-escape-codes.html
- Claude Code hooks: https://code.claude.com/docs/en/hooks
