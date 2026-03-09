# Features

## Kanban Board

- 3 fixed columns: To Do, In Progress, Done
- Multiple boards with sidebar navigation
- Drag-and-drop cards between columns
- Pin boards to top of sidebar
- Board-level agent selection (Claude Code, Codex, Gemini)

## Card Management

- Create cards with Cmd+Shift+A
- Delete cards via Cmd+Shift+D (with confirmation)
- Per-card agent override
- Agent completion monitor keeps unfinished agent cards in `To Do`, but only starts a task cycle after a real Zenban terminal submit; typing without Enter does not move the card or notify

## Terminal Integration

- Embedded terminal now uses cmux's Ghostty host stack, including `Workspace`, `TabManager`, Bonsplit splits, browser panels, and find/search state inside the card detail area
- The board owns one shared cmux `TabManager`; each card is treated as a cmux workspace with card IDs exported as `CMUX_WORKSPACE_ID`/`CMUX_TAB_ID`, and terminal panels export `CMUX_SURFACE_ID`
- Every terminal split now runs inside its own tmux session; hidden cards tear down Ghostty surfaces to save memory, then reattach to the same tmux-backed shell when the card becomes visible again
- Agent startup is centralized: Claude launches with `--dangerously-skip-permissions`, Codex and Gemini with `--yolo`, and tmux session env is refreshed on first launch, worktree handoff, and agent switch
- Zenban now watches tmux session activity plus pane output to detect `running`, `waiting`, `idle`, `error`, and `stopped` agent states without Claude URL hooks, while card completion is gated by explicit submit events from the terminal surface
- The workspace UI no longer offers manual browser creation; browser panels are now surfaced only by Dev Server preview or internal automation/link-routing paths
- Card switches use a selected+retiring handoff so old Ghostty/browser portals are hidden before the previous card unmounts
- Workspaces can move into detached terminal-only windows and back without changing card identity or worktree routing; detached windows currently host one card workspace and detached cards show a placeholder in the detail pane that focuses the external window
- Runtime/resources are copied from `clone/cmux` with a build phase that recreates cmux's `ghostty`, `terminfo`, `shell-integration`, and `bin` bundle layout
- Ghostty reads the user's standard config files and receives the same app/surface color-scheme updates cmux uses, so theme resolution now matches cmux behavior
- Zenban writes `~/.zenban/tmux.conf` from the active Ghostty selection colors and treats Homebrew plus tmux as required terminal dependencies
- Bundled `cmux`, `claude`, and `open` helpers are in `Resources/bin`, and the app starts a cmux-compatible local socket controller so shell integration can report pwd/tty/git/pr state back into the owning workspace whether it is embedded or detached
- The inherited cmux notification store, unread tab badges, and Ghostty notification ring are removed; only Zenban's `NotificationService` sends macOS completion notifications

## Git Worktrees

- Each card gets its own git worktree (branch: card/uuid)
- Workspace uses the card worktree directory when ready; otherwise it opens at the repo path first and the agent later switches into the worktree with `cd && launch`
- View Changes button opens diff view
- Worktrees cleaned up on card/board deletion with best-effort branch removal

## Dev Server Preview

- Per-board dev server config (setup/dev commands)
- Auto-detects package manager from lock files
- Board-area preview reuses cmux's browser stack (`BrowserPanelView`) once the server is ready
- Startup/setup output stays visible until the URL is detected
- Optional board-level "Open console automatically" setting keeps the cmux JavaScript console off by default and opens it only after the preview finishes loading when enabled
- Board list auto-collapses while the preview is active and restores its previous visibility when the preview closes
- Port auto-detection from output
- Toggle with Cmd+Shift+S
- Reload the current preview with Cmd+Shift+R

## Git Changes View

- Toggle with Cmd+Shift+X
- Split-view diff renderer
- Commit, Merge, Create PR actions
- AI-generated commit messages via Claude CLI
- On-demand diff loading per file

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| Cmd+Shift+N | New Board |
| Cmd+Shift+A | New Card |
| Cmd+Shift+D | Delete selected card |
| Cmd+Shift+S | Toggle Dev Server |
| Cmd+Shift+R | Reload Dev Server |
| Cmd+Shift+X | Toggle Git Changes |
| Shift+Arrow Up/Down | Navigate cards/boards |
| Shift+Arrow Left/Right | Navigate columns |

## Data Storage

- JSON file at `~/Library/Application Support/com.berkaycit.zenban/boards.json`
- Auto-saves with 500ms debounce
