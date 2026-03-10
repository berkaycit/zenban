# Notification Workflow

## Scope

- Zenban no longer uses Claude URL hooks.
- Claude can also emit explicit `claude_hook` runtime signals over the local cmux-compatible socket.
- Zenban no longer uses the inherited cmux notification store, unread badges, or Ghostty notification ring.
- The only user-facing notification path is `NotificationService`.

## Main pieces

| Piece | Responsibility |
|------|------|
| `NotificationService` | Refreshes macOS notification authorization, defers the first automatic prompt until the app is active, coalesces one completion notification per card, only posts when a completion actually moves the card into `In Review`, clears stale delivered/pending entries when the card is focused or deleted, and re-selects the owning board/card on click. |
| `TerminalManager` | Creates and tracks the card's tmux-backed terminal session, wires `onUserSubmit`, forwards matching Claude runtime hooks from the socket controller, and only registers a launch after tmux accepts the injected agent command. |
| `AgentLauncher` | Builds the shell command plus tmux env for Claude, Codex, and Gemini and injects that command into the card's tmux session. |
| `AgentSessionMonitor` | Polls tmux, captures pane output when needed, derives a raw agent status, accepts explicit Claude submit/completion signals, applies the task reducer, moves cards, and falls back to `stopped` after repeated pane-capture failures so cycles do not stay stuck forever. |
| `GhosttyTerminalView` | Tracks whether the user has meaningful pending draft input and only emits a submit signal on Enter/Return or newline paste. |

## Runtime flow

1. `TerminalManager` launches the selected agent through `AgentLauncher` on the relevant path: initial card launch, worktree-ready relaunch, or explicit agent switch.
2. `AgentSessionMonitor.registerLaunch` marks the card as `bootstrapping`, but only after `tmux send-keys` succeeds.
3. The monitor polls tmux every second and only captures pane output when activity changes, when a card is not yet `ready`, or when no cached status exists.
4. The reducer advances `bootstrapping -> warmingUp -> ready` once the agent settles into an initial baseline.
5. User typing alone does nothing. The terminal must first record meaningful draft input.
6. Enter/Return or newline paste fires `onUserSubmit`.
7. `registerTaskSubmission` marks the card as `activeTask`. If the card is currently in `In Review`, it is moved back to `To Do`.
8. While `activeTask` is running, `waiting` and `error` keep the card in `To Do`.
9. For Claude, matching `claude_hook stop|idle` signals can complete an armed task immediately without waiting for the next tmux poll.
10. Otherwise, when the same session returns to raw status `idle`, the reducer completes the cycle.
11. Completion moves the card to `In Review`, and `NotificationService` posts a macOS notification only if that move actually changed the column.
12. Clicking that notification clears the stale delivered entry, re-selects the board/card, re-activates the workspace when one exists, and activates the app.

## Raw status detection

- Claude uses explicit `prompt-submit` and `stop`/`idle` runtime hooks when available, then falls back to tmux pane text heuristics for busy, waiting, stopped, and error prompts plus recent tmux activity for `running` vs `idle`.
- Codex and Gemini use the same monitor but only generic waiting/error/spinner detection plus activity-based `running`/`idle`.
- If pane capture fails repeatedly for the same session, the monitor escalates that session to raw status `stopped` so `activeTask` does not remain armed forever.
- The current parser is raw-status based. It does not model prompt ownership or richer prompt fingerprints.

## What does not notify

- Initial launch, worktree relaunch, and agent switch by themselves.
- Pure typing without submit.
- Sessions that end in `waiting`, `error`, or `stopped`.
- Cards that are already in `In Review` when completion arrives.
- External tmux input that bypasses Zenban's terminal surface.

## Current limits

- Claude completion is less heuristic now because explicit runtime hooks are wired, but Codex and Gemini completion is still heuristic because it depends on tmux pane parsing plus activity.
- Submit tracking is a simple pending-draft boolean, not a full editable line model.
- The reducer is intentionally small: `bootstrapping`, `warmingUp`, `ready`, and `activeTask`.
- Repeated pane-capture failures now recover by falling back to `stopped`, but that still does not synthesize a completion notification.
