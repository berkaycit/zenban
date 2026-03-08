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
│   ├── DevServer/   # Dev server preview with WebView
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
| `TerminalManager` | Terminal adapter between Zenban cards and the cmux host stack. The main board now owns one cmux-style `TabManager`, each card maps 1:1 to a `Workspace` using the card UUID, and detached terminal windows temporarily re-home that workspace into a dedicated window manager before attaching it back to the board. `CardWorkspaceDeckView` still keeps only the selected + retiring card mounted during handoff so split layout, browser panels, search state, scrollback, and focus survive card switches without stale Ghostty/WebKit portals bleeding through. |
| `AppDelegate` | Window-level terminal host contract for cmux parity. Tracks the main board window plus detached terminal windows, routes active `TabManager`/window focus into `TerminalController`, starts the local cmux-compatible socket controller, and preserves card identity while workspaces move between the board and detached windows. |
| `GitService` | Git via libgit2: repo init, worktree CRUD, status/diff, commit/push, merge. PR via gh CLI. AI commit messages. |
| `ClaudeService` | Claude Code CLI integration implementing AIProvider protocol. |
| `DevServerManager` | Dev server processes. Setup (npm install), port detection, WebView preview. 100KB output buffer. |
| `ClaudeHooksInstaller` | Installs Claude Code hooks to ~/.claude/settings.json for Zenban URL scheme integration. |
| `DependencyCheckService` | Actor for checking/installing dependencies (Homebrew required; gh, Claude CLI optional). Shows DependencySetupView modal on startup if required deps missing. |
| `GitChangesView` | Board-area view (Cmd+Shift+X). Two tabs: Changes (file list + diff) and History (commit log + diff). GitDiffViewModel for batch loading with LRU cache and content hash validation. |
| `GitHistoryView` | Commit history list with pagination. Uses GitLogService for async loading. |
| `GitLogService` | Actor for commit history and diff retrieval via libgit2 and ProcessExecutor. |
| `DiffView` | NSTableView diff renderer with upfront parsing. Scroll tracking, file navigation, copy support. |

## Board Creation

Three options: existing directory, create new repo (git init), or empty. Agent (Claude/Codex/Gemini) auto-runs in the embedded Ghostty terminal on first open.

## Card Creation

Cards auto-named by agent prefix (cc-1, codex-1, gemini-1). Per-board counters persist across restarts.

## Card Worktrees

For boards with git repo, each card gets worktree (branch: `card/<uuid>`, location: `../repo-worktrees/`). Terminal starts in worktree. Cleanup prunes stale entries, best-effort branch deletion.

## Detached Terminal Windows

Cards still equal workspaces, but a workspace can move out of the board detail pane into a dedicated terminal-only window. The board keeps the card selected while `AppDelegate` and `TerminalManager` rebind the workspace's `TabManager`, and the card detail pane shows a focus placeholder instead of mounting a duplicate Ghostty host.

## Dev Server Preview

Board stores DevServerConfig. First run prompts for commands (auto-detected from package.json). WebView shows in board area. ProcessEnvironment sets BROWSER=none.

## Keyboard Shortcuts

Cmd+Shift: N (new board), A (new card), D (delete card), S (dev server), X (git changes), F (file browser). Cmd+W closes file tab. Cmd+/ opens shortcuts help.
Shift+Arrow: Up/Down navigates cards/boards, Left/Right moves columns. Enter focuses terminal.
FocusRegion tracks keyboard focus. NSEvent monitor in zenbanApp for app-wide capture.
