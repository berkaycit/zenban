# Terminal Task Completion Detection - Experiments Log

## Goal
Automatically move a card to "In Review" when an agent task finishes in the
embedded Ghostty terminal.

## Attempts (all failed)
1) Ghostty command-finished action
   - Existing `GHOSTTY_ACTION_COMMAND_FINISHED` path already drives
     `handleCommandFinished` -> `onTaskCompleted`.
   - Result: not triggered for long-running agent tasks; no card move.

2) Ghostty desktop notification action
   - Added handling for `GHOSTTY_ACTION_DESKTOP_NOTIFICATION` to trigger
     `onTaskCompleted` (focus bypassed).
   - Explicitly set `desktop-notifications = true` in Ghostty config.
   - Added `NotificationService` call on desktop notification action.
   - Result: no desktop notification event observed; no card move.

3) Claude Code Stop hook emitting OSC 9
   - Added `.claude/hooks/task_completed_notify.sh` to emit:
     `ESC ] 9 ; <message> ESC \`.
   - Added `.claude/settings.json` Stop hook to run the script.
   - Result: no notification and no card move.

## What this indicates
- On macOS, Ghostty does not emit "command finished" notifications by itself
  (`notify-on-command-finish` is GTK-only).
- A desktop notification action only appears if the running app emits OSC 9/777.
- The Stop hook either did not fire in this environment, or the OSC output did
  not reach the embedded Ghostty surface.

## References
- Ghostty config reference: https://ghostty.org/docs/config/reference
- Ghostty OSC 9 spec: https://ghostty.org/docs/vt/osc/9
- iTerm2 escape codes (OSC 9 notifications): https://iterm2.com/documentation-escape-codes.html
- Claude Code hooks: https://code.claude.com/docs/en/hooks.md
