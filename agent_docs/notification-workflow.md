# Notification Workflow

## Scope

- Zenban no longer uses Claude URL hooks.
- Zenban no longer uses the inherited cmux notification store, unread badges, or Ghostty notification ring.
- The only user-facing notification path is `NotificationService`.

## Main pieces

| Piece | Responsibility |
|------|------|
| `NotificationService` | Requests macOS notification permission, sends completion notifications, re-selects the owning board/card on click, and activates the app. |
| `TerminalManager` | Creates and tracks the card's tmux-backed terminal session, wires `onUserSubmit`, and registers launch or relaunch events with the monitor. |
| `AgentLauncher` | Builds the shell command plus tmux env for Claude, Codex, and Gemini and injects that command into the card's tmux session. |
| `AgentSessionMonitor` | Polls tmux, captures pane output when needed, derives a raw agent status, applies the task reducer, moves cards, and triggers notifications. |
| `GhosttyTerminalView` | Tracks whether the user has meaningful pending draft input and only emits a submit signal on Enter/Return or newline paste. |

## Runtime flow

1. `TerminalManager` launches the selected agent through `AgentLauncher` on the relevant path: initial card launch, worktree-ready relaunch, or explicit agent switch.
2. `AgentSessionMonitor.registerLaunch` marks the card as `bootstrapping`.
3. The monitor polls tmux every second and only captures pane output when activity changes, when a card is not yet `ready`, or when no cached status exists.
4. The reducer advances `bootstrapping -> warmingUp -> ready` once the agent settles into an initial baseline.
5. User typing alone does nothing. The terminal must first record meaningful draft input.
6. Enter/Return or newline paste fires `onUserSubmit`.
7. `registerTaskSubmission` marks the card as `activeTask`. If the card is currently in `In Review`, it is moved back to `To Do`.
8. While `activeTask` is running, `waiting` and `error` keep the card in `To Do`.
9. When the same session returns to raw status `idle`, the reducer completes the cycle, the card moves to `In Review`, and `NotificationService` posts a macOS notification.
10. Clicking that notification selects the board, selects the card, and activates the app.

## Raw status detection

- Claude uses tmux pane text heuristics for busy, waiting, stopped, and error prompts, then falls back to recent tmux activity to distinguish `running` from `idle`.
- Codex and Gemini use the same monitor but only generic waiting/error/spinner detection plus activity-based `running`/`idle`.
- The current parser is raw-status based. It does not model prompt ownership or richer prompt fingerprints.

## What does not notify

- Initial launch, worktree relaunch, and agent switch by themselves.
- Pure typing without submit.
- Sessions that end in `waiting`, `error`, or `stopped`.
- External tmux input that bypasses Zenban's terminal surface.

## Current limits

- Completion is heuristic because tmux pane parsing is heuristic.
- Submit tracking is a simple pending-draft boolean, not a full editable line model.
- The reducer is intentionally small: `bootstrapping`, `warmingUp`, `ready`, and `activeTask`.
