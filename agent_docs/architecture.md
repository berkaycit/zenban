# Architecture

## Directory Structure

```
zenban/
├── Models/          # Data models (Board, Card, Column, GitModels, AIModels, DiffTypes)
├── Storage/         # JSON persistence layer
├── ViewModels/      # @Observable state management
├── Views/
│   ├── Sidebar/     # Board list navigation
│   ├── Board/       # Kanban board layout
│   ├── Card/        # Card display and editing
│   ├── Git/         # Git changes view, diff display, PR creation
│   ├── DevServer/   # Board-area dev server preview using cmux browser panels
│   ├── Settings/    # Unified settings (General, Terminal, Dev Server)
│   └── Components/  # Reusable UI components
├── Terminal/        # Embedded Ghostty terminal layer
├── Services/        # App-wide services (notifications, git, AI providers)
├── Utilities/       # Shared helpers (ProcessExecutor, RelativeDateFormatter)
├── Commands/        # Menu keyboard shortcuts
└── Extensions/      # Color theme, Notification.Name extensions
```

## Layout

ContentView uses NavigationSplitView with three columns: sidebar (board list), content (kanban/overlays), detail (card). Column widths enforced via navigationSplitViewColumnWidth. BoardView centers columns horizontally with top alignment.

## Data Flow

1. `BoardStore` (@Observable) holds all state
2. `BoardStorage` handles JSON file I/O with debounced saves
3. Views read from `BoardStore` via `@Environment`
4. User actions call `BoardStore` methods which update state and trigger save

## Key Components

| Component | Purpose |
|-----------|---------|
| `BoardStore` | Central state manager. OverlayState FSM unifies dev server, git changes, and file browser (mutually exclusive). Creates/deletes worktrees. O(1) board index lookup via lazy cache. |
| `BoardStorage` | JSON persistence to Application Support |
| `Board/Card/Column` | Data models. Board has repositoryPath/agent/agentCounters. Card can override agent. Column has display name/color. Agent has autoNamePrefix for card naming. |
| `TerminalManager` | Terminal adapter between Zenban cards and the cmux host stack. The board owns one cmux-style `TabManager`, lazily creates one `Workspace` per card using the card UUID, and keeps workspaces alive until card teardown. Agent launch goes through `AgentLauncher`, Claude runtime hooks are forwarded from the local socket controller only for the matching Claude panel, and Zenban only arms the shared notification workflow after tmux accepts the injected launch command. |
| `AgentSessionMonitor` | Polls the isolated Zenban tmux server, captures pane output only when activity changes or a card is mid-cycle, and collapses pane output into raw agent states (`running`/`waiting`/`idle`/`error`/`stopped`). A small reducer tracks `bootstrapping -> warmingUp -> ready -> activeTask`; accepted submits can move cards from `In Review` back to `To Do`, Claude `stop`/`idle` hooks can complete an armed task immediately, the first accepted completion only notifies when it actually moves the card into `In Review`, and repeated pane-capture failures now fall back to `stopped` so cards do not remain stuck mid-cycle forever. |
| `AppDelegate` | Window-level terminal host contract for Zenban's reduced cmux shell. Tracks the main board window plus single-card detached terminal windows, routes active `TabManager`/window focus into `TerminalController`, starts the local cmux-compatible socket controller, and preserves card identity while workspaces move between the board and detached windows. |
| `NotificationService` | Zenban's only remaining notification path. Tracks authorization state, defers the first automatic prompt until the app is active, coalesces one completion notification per card, clears stale delivered/pending entries when the user focuses that card again, only posts on real transitions into `In Review`, and replaces the removed cmux-derived unread/notification store. |
| `GitService` | Git via libgit2: repo init, worktree CRUD, status/diff, commit/push, merge. PR via gh CLI. AI commit messages. |
| `ClaudeService` | Claude Code CLI integration implementing AIProvider protocol. |
| `DevServerManager` | Dev server setup/process lifecycle, port detection, and server-output buffering. Ready-state preview is owned by `DevServerView`, not the manager. |
| `DependencyCheckService` | Actor for checking/installing dependencies (Homebrew and tmux required; gh and Claude CLI optional). Shows `DependencySetupView` on startup when required terminal runtime deps are missing and can install tmux through Homebrew. |
| `GitChangesView` | Board-area view (Cmd+Shift+X). Two tabs: Changes (file list + diff) and History (commit log + diff). `GitDiffViewModel` handles cancellable on-demand diff loading with caching and lightweight diff-source fallback logic. |
| `GitHistoryView` | Commit history list with pagination. Uses GitLogService for async loading. |
| `GitLogService` | Actor for commit history and diff retrieval via libgit2 and ProcessExecutor. |
| `DiffView` | NSTableView diff renderer with upfront parsing. Scroll tracking, file navigation, copy support. |

## Board Creation

Three options: existing directory, create new repo (git init), or empty. Agent (Claude/Codex/Gemini) auto-runs in the embedded Ghostty terminal on first open.

## Card Creation

Cards auto-named by agent prefix (cc-1, codex-1, gemini-1). Per-board counters persist across restarts.

## Card Worktrees

For boards with git repo, each card gets worktree (branch: `card/<uuid>`, location: `../repo-worktrees/`). Workspace startup uses the repo path until the worktree is ready, then `TerminalManager` relaunches the selected agent through the shared `AgentLauncher` path with the worktree directory and refreshed tmux session env. Cleanup prunes stale entries with best-effort branch deletion.

## Detached Terminal Windows

Cards still equal workspaces, but a workspace can move out of the board detail pane into a dedicated terminal-only window. Detached windows currently host one card workspace at a time. The board keeps the card selected while `AppDelegate` and `TerminalManager` rebind the workspace's `TabManager`, and the card detail pane shows a focus placeholder instead of mounting a duplicate Ghostty host.

## Dev Server Preview

Board stores `DevServerConfig`, including the optional `autoOpenConsole` flag that defaults to `false`. First run prompts for commands (auto-detected from package.json). `DevServerView` keeps setup/start output visible during startup, then swaps the board-area surface to a cmux `BrowserPanelView` tied to the card ID once the server reaches `ready(url)`. The preview reuses that live browser panel for in-session reloads, only auto-opens the cmux JavaScript console when the board config requests it, and returns the board area to the error/log view on unexpected server exits. `ContentView` temporarily collapses the sidebar while the dev server overlay is active and restores the prior split visibility when the session ends. `ProcessEnvironment` sets `BROWSER=none` so the dev command never launches an external browser.

## Keyboard Shortcuts

Cmd+Shift: N (new board), A (new card), D (delete card), S (dev server), R (reload dev server), X (git changes), F (file browser). Cmd+W closes file tab. Cmd+/ opens shortcuts help.
Shift+Arrow: Up/Down navigates cards/boards, Left/Right moves columns. Enter focuses terminal.
FocusRegion tracks keyboard focus. NSEvent monitor in zenbanApp for app-wide capture.

See also: `agent_docs/notification-workflow.md` for the current tmux/submit/completion notification flow.
