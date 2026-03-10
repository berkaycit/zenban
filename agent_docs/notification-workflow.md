# Notification Workflow

## Scope

- Zenban now uses one explicit lifecycle for Claude, Codex, and Gemini.
- `started` means the user submitted terminal input from Zenban's surface.
- `completed` means the bundled agent wrapper sent an explicit socket callback.
- The only user-facing notification path is still `NotificationService`.

## Main pieces

| Piece | Responsibility |
|------|------|
| `NotificationService` | Refreshes macOS authorization, defers the first automatic prompt until the app is active, coalesces one completion notification per card, only posts when completion actually moves the card into `In Review`, clears stale delivered/pending entries when the card is focused or deleted, and re-selects the owning board/card on click. |
| `TerminalManager` | Creates and tracks the card's tmux-backed terminal session, wires `onUserSubmit`, forwards matching `agent_hook` socket signals from the controller, and only registers a launch after tmux accepts the injected agent command. |
| `AgentLauncher` | Builds the shell command plus tmux env for Claude, Codex, and Gemini and injects that command into the card's tmux session. |
| `AgentSessionMonitor` | Holds the minimal task reducer. `started` arms a card task, can move `In Review` back to `To Do`, and `completed` closes the task, moves the card to `In Review`, and asks `NotificationService` to notify only when that move changed the column. |
| `GhosttyTerminalView` | Tracks whether the user has meaningful pending draft input and only emits submit on Enter/Return or newline paste. |
| `Resources/bin/{claude,codex,gemini}` | Zenban-owned wrappers that turn each agent's native hook/notify surface into `cmux agent-hook <agent> completed`. |

## Runtime flow

1. `TerminalManager` launches the selected agent through `AgentLauncher` on initial card launch, worktree-ready relaunch, or agent switch.
2. After `tmux send-keys` succeeds, `AgentSessionMonitor.registerLaunch` clears any stale active-task bit for that card.
3. Pure typing does nothing. Zenban only treats Enter/Return or newline paste as a task start.
4. `onUserSubmit` sends `started` into the monitor.
5. `started` marks the card active. If the card was already in `In Review`, it moves back to `To Do`.
6. The bundled wrapper reports `completed` over the local socket when that agent turn ends.
7. `completed` only does work if the card still has an active task bit.
8. Completion moves the card to `In Review`, and `NotificationService` posts a macOS notification only if that move actually changed the column.
9. Clicking that notification clears the stale delivered entry, re-selects the board/card, re-activates the workspace when one exists, and activates the app.

## What does not notify

- Initial launch, worktree relaunch, and agent switch by themselves.
- Pure typing without submit.
- Completion callbacks for cards that were never armed by Zenban submit.
- Cards that are already in `In Review` when completion arrives.
- `Done` cards.
- External tmux input that bypasses Zenban's terminal surface.

## Current limits

- `started` is defined as terminal submit, not first-token emission.
- `completed` is defined as agent turn completion; success, cancel, and partial-turn outcomes are not distinguished.
- Zenban no longer polls tmux pane output for task movement, so explicit wrapper callbacks are now required for automatic completion.
