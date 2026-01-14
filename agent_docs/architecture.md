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
│   ├── Settings/    # App settings (terminal font, theme)
│   └── Components/  # Reusable UI components
├── Terminal/        # Embedded terminal per card
│   └── GhosttyTerminal/  # Ghostty integration (Metal rendering, input handling)
├── Services/        # App-wide services (notifications, git, AI providers)
├── Utilities/       # Shared helpers (ProcessExecutor, RelativeDateFormatter)
├── Commands/        # Menu keyboard shortcuts
└── Extensions/      # Color theme, Notification.Name extensions
```

## Data Flow

1. `BoardStore` (@Observable) holds all state
2. `BoardStorage` handles JSON file I/O with debounced saves
3. Views read from `BoardStore` via `@Environment`
4. User actions call `BoardStore` methods which update state and trigger save

## Key Components

| Component | Purpose |
|-----------|---------|
| `BoardStore` | Central state manager. OverlayState FSM unifies dev server, git changes, and file browser (mutually exclusive). Creates/deletes worktrees. |
| `BoardStorage` | JSON persistence to Application Support |
| `Board/Card/Column` | Data models. Board has repositoryPath/agent. Card can override agent. Column has display name/color. |
| `TerminalManager` | Manages GhosttyTerminalView per card with LRU eviction (max 50). Hibernates on deselect. Auto-launches agent. |
| `TmuxSessionManager` | Actor managing tmux sessions (zenban- prefix). Sync cleanup on app quit, async on card delete. |
| `GhosttyTerminalView` | Terminal with state machine (shell/agentActive/agentIdle). OSC 133 for command detection. Ctrl+C exits agent. |
| `GhosttyApp` | Singleton for Ghostty context. Routes actions, handles clipboard, reloads config on settings change. |
| `GitService` | Git via libgit2: repo init, worktree CRUD, status/diff, commit/push, merge. PR via gh CLI. AI commit messages. |
| `ClaudeService` | Claude Code CLI integration implementing AIProvider protocol. |
| `DevServerManager` | Dev server processes. Setup (npm install), port detection, WebView preview. 100KB output buffer. |
| `GitChangesView` | Board-area view (Cmd+Shift+X). Two tabs: Changes (file list + diff) and History (commit log + diff). GitDiffViewModel for batch loading with LRU cache. |
| `GitHistoryView` | Commit history list with pagination. Uses GitLogService for async loading. |
| `GitLogService` | Actor for commit history and diff retrieval via libgit2 and ProcessExecutor. |
| `DiffView` | NSTableView diff renderer with upfront parsing. Scroll tracking, file navigation, copy support. |

## Board Creation

Three options: existing directory, create new repo (git init), or empty. Agent (Claude/Codex/Gemini) auto-runs on terminal open.

## Card Worktrees

For boards with git repo, each card gets worktree (branch: `card/<uuid>`, location: `../repo-worktrees/`). Terminal starts in worktree. Cleanup prunes stale entries, best-effort branch deletion.

## Terminal Agent Detection

State machine: shell -> agentActive -> agentIdle. OSC 133 D triggers idle, Ctrl+C exits to shell. hasBeenFocused guard prevents false positives.

## Dev Server Preview

Board stores DevServerConfig. First run prompts for commands (auto-detected from package.json). WebView shows in board area. ProcessEnvironment sets BROWSER=none.

## Keyboard Shortcuts

Cmd+Shift: N (new board), A (new card), D (delete card), S (dev server), X (git changes), F (file browser). Cmd+W closes file tab.
Shift+Arrow: Up/Down navigates cards/boards, Left/Right moves columns. Enter focuses terminal.
FocusRegion tracks keyboard focus. NSEvent monitor in zenbanApp for app-wide capture.
