# Features

## Kanban Board

- Three fixed columns: `To Do`, `In Review`, and `Done`
- Multiple boards with sidebar navigation
- Drag-and-drop cards between columns
- Board pinning in the sidebar
- Board-level default agent selection

## Card Management

- Create cards with `Cmd+Shift+A`
- Delete cards with `Cmd+Shift+E`
- Delete every card in the `To Do`, `In Review`, or `Done` column from the column header
- Override the board agent per card
- Persist agent choice as card metadata and auto-launch it inside the card workspace
- Claude completion notifications move the owning card to `In Review`, and Claude resuming work moves it back to `To Do`
- Show worktree readiness in the detail pane for git-backed boards

## Card Workspaces

- The lower detail pane embeds a cmux-derived Ghostty workspace per card, backed by a bundled Zellij session per workspace
- Claude auto-launch now goes through a per-workspace launch request queue that the shell prompt hook acknowledges before Zenban marks the launch as delivered or consumes a pending prompt
- Hidden card terminals stop rendering after a short delay but keep their shell and agent processes running in Zellij
- The app menu and General settings expose `Ghostty Settings…` and `Reload Configuration`; Zenban now seeds and opens its own app-scoped Ghostty config at `~/Library/Application Support/com.berkaycit.zenban/config.ghostty`
- Embedded terminals no longer inherit the standalone Ghostty user config; Zenban reloads only its own Ghostty config plus bundled performance overrides
- The embedded workspace chrome uses the current cmux Bonsplit tab and split package, including its latest tab-bar action lane and drop-handling behavior
- When an embedded terminal is focused, terminal-local bindings such as `new_tab`, `new_split`, `previous_tab`, `next_tab`, and `close_surface` now route through Ghostty's own config instead of Zenban's host shortcut layer
- `Cmd+T` and other remapped Ghostty tab shortcuts can now change with the Zenban-scoped Ghostty config; stale host shortcuts are swallowed instead of overriding Ghostty
- Extra terminal tabs and splits now get their own persistent Zellij-backed shell sessions instead of sharing the root card session, those independent sessions survive card hide/reopen runtime reclaim, and each new panel auto-launches the card's currently selected agent command on first startup
- When the selected card's Ghostty terminal is focused, `Cmd+Shift+T` toggles an app-content fullscreen mode for that card and exits automatically if selection, overlays, or workspace availability changes
- Terminal paste/drop follows the current cmux local behavior for UTF-8 plain text and image-only payloads; remote upload handling is intentionally not enabled in Zenban
- `Done` cards keep their terminal closed by default and expose an `Open Terminal` action for manual reopening
- Leaving a reopened `Done` card closes its workspace and tears down that card's Zellij session again
- Agent pills update stored card state and relaunch the selected command when needed
- Git Changes, File Browser, and Dev Server actions still open from the card header

## Git Worktrees

- Each card gets its own git worktree on branch `card/<uuid>`
- Worktrees are created lazily and cleaned up on delete
- Git Changes opens a board-area diff and history workspace
- `Cmd+Shift+C` opens the commit sheet in Git Changes and submits the commit when the sheet is open

## Dev Server

- Per-board setup and dev commands
- Package-manager-aware command detection
- Live setup and process logs during startup
- Ready-state embedded cmux browser preview for the selected card
- App-owned dev server process groups are cleaned up on quit and reaped on the next launch if the app was interrupted
- Same-worktree port conflicts reclaim stale listeners first, then retry once on a fallback port only when another process still owns the requested port
- `Cmd+Shift+S` toggles the session
- `Cmd+Shift+C` toggles the preview browser developer tools when that preview is focused, opening the JavaScript console when closed
- `Cmd+Shift+R` refreshes the current dev server preview

## Notifications And Finder Services

- cmux-derived desktop notifications still queue, mark unread, move cards into `In Review`, and clear again when the owning workspace is focused
- Claude and Codex card launches go through bundled wrappers so completion notifications and Feed hook telemetry target the active Zenban socket; OpenCode hook telemetry still uses the copied cmux Feed socket bridge
- The bundled CLI includes the Feed TUI and OpenCode hook plugin resources needed by the copied hook commands
- The copied cmux CLI can inspect Zenban terminal panels through `top` and `debug-terminals`, create caller-targeted notifications, equalize splits, and move a terminal tab into a new workspace without requiring cmux cloud, VM, or sidebar UI
- Finder Services expose “New Zenban Workspace Here” and “New Zenban Window Here”
- The app bundle includes a cmux-based AppleScript dictionary and English localization catalogs

## Tool Availability

- Settings shows read-only availability for external tools used by optional workflows
- Zenban bundles its terminal runtime internally and does not require separate Homebrew, tmux, zellij, or GitHub CLI installs
- Ghostty config changes can be reloaded in place for embedded terminals without restarting the app
- System `git` is used for git history, commit diffs, and shell git probes
- `Claude Code CLI` remains optional and is only used for AI-assisted commit messages

## Data Storage

- Boards are stored at `~/Library/Application Support/com.berkaycit.zenban/boards.json`
- Saves are debounced automatically
