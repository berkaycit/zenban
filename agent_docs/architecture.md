# Architecture

## Directory Structure

```
zenban/
├── Models/          # Data models (Board, Card, Column, GitModels, AIModels)
├── Storage/         # JSON persistence layer
├── ViewModels/      # @Observable state management
├── Views/
│   ├── Sidebar/     # Board list navigation
│   ├── Board/       # Kanban board layout
│   ├── Card/        # Card display and editing
│   ├── Git/         # Git changes view, diff display, PR creation
│   ├── DevServer/   # Dev server preview with WebView
│   └── Components/  # Reusable UI components
├── Terminal/        # Embedded terminal per card (SwiftTerm)
├── Services/        # App-wide services (notifications, git, AI providers)
├── Commands/        # Menu keyboard shortcuts
└── Extensions/      # Color theme extensions
```

## Data Flow

1. `BoardStore` (@Observable) holds all state
2. `BoardStorage` handles JSON file I/O with debounced saves
3. Views read from `BoardStore` via `@Environment`
4. User actions call `BoardStore` methods which update state and trigger save

## Key Components

| Component | Purpose |
|-----------|---------|
| `BoardStore` | Central state manager with `sortedBoards` (pinned first). Tracks `focusRegion` for keyboard navigation, `devServerState` FSM, and `gitChangesCardID`. Skips redundant column moves. Creates/deletes worktrees for cards. Auto-selects next card after deletion. `stopOverlays()` unified cleanup for dev server and git changes on card/board delete. |
| `BoardStorage` | JSON persistence to Application Support |
| `Board` | Data model with `isPinned`, optional `repositoryPath`, and `agent` selection |
| `Agent` | Enum (Claude/Codex/Gemini) with launch commands. Board sets default, Card can override. |
| `Column` | Enum with display name and accent color |
| `HSplitView` | Three-column layout: sidebar, board, card detail (enforces min widths) |
| `ColumnView` | Handles drag-drop with `.onDrag` and `.dropDestination()` |
| `CardDetailView` | Right panel with card editing, column move, and agent picker (switches terminal) |
| `TerminalManager` | Manages terminal views per card. Uses card's worktree or board's repo as start directory. Auto-launches agent when shell is ready. Terminates processes on card/board deletion and app quit. Applies styling from TerminalConfiguration. |
| `ZenbanTerminalView` | Terminal with state machine for Claude detection. Strips ANSI codes for Ctrl+R support. Auto-moves cards between columns. Detects shell readiness via output. |
| `TerminalConfiguration` | Static styling config: font (SF Mono 14pt), colors (foreground, cursor, selection), ANSI palette (One Dark inspired). Background via TerminalContainerView. To customize: modify static properties, use installColors() for ANSI updates. |
| `NotificationService` | macOS notifications + card movement callbacks (onTaskCompleted, onAgentResumed) |
| `GitService` | Git operations: repository init, worktree CRUD, status/diff, commit/push, merge, PR creation (gh CLI), AI commit message generation |
| `ClaudeService` | Claude Code CLI integration implementing AIProvider protocol. |
| `ProcessEnvironment` | Shared utility for building process environment with PATH setup (node/nvm/homebrew). Used by ClaudeService and DevServerManager. |
| `DevServerManager` | Manages dev server processes for cards. Handles setup (npm install), port detection, and WebView preview. Single server at a time with proper cleanup. Output buffer limited to 100KB with throttled UI updates (150ms). |
| `DevServerSettingsSheet` | Sidebar-accessible sheet for editing board dev server config (setup command, dev command, skip setup toggle). |
| `GitChangesView` | Board-area view (toggled via Cmd+Shift+X or button) showing diff, branch picker, Commit/Merge/Create PR actions. Loads diffs on-demand when files are expanded. |
| `DiffContentView` | Split-view diff renderer with async parsing and line limiting (300 lines visible by default). |
| `DirectoryPicker` | NSOpenPanel wrapper for folder selection |

## Board Creation

Three directory options:
1. **From Existing Directory** - Select folder, terminal starts there
2. **Create New Repository** - Create folder + `git init`
3. **Empty** - No directory association

Agent selection (Claude Code, Codex, Gemini) determines which command auto-runs when terminal opens. Context menu offers "Reveal Folder" to open board directory in Finder.

## Terminal Agent Detection

State machine: `shell` → `agentActive` → `agentIdle`. Detects "claude" in input/output, 2s idle triggers card move to "In Review", new message moves to "To Do", Ctrl+C exits to shell. Strips ANSI codes for Ctrl+R support. Guards: `hasBeenFocused` (prevents init trigger), `minActivityBytes` (ignores <10 bytes).

## Card Worktrees

For boards with git repo, each card gets worktree (branch: `card/<uuid>`, location: `../repo-worktrees/`). Created on card add, deleted on card/board delete. Terminal starts in worktree, agent launches when shell ready. "View Changes" opens GitChangesView with split-diff. Cleanup resilient: prunes stale entries, best-effort branch deletion.

## AI Integration

AIProvider protocol enables pluggable AI services. ClaudeService implements it for Claude Code CLI. GitService.generateCommitMessage uses ClaudeService to generate commit messages from diffs. PromptTemplate enum holds prompt strings. DefaultCommitMessageParser handles response parsing with fallback strategies.

## Dev Server Preview

Board stores DevServerConfig (setup command, dev command). CardDetailView shows "Start Dev Server" button for cards with worktree. First run prompts for commands (auto-detected from package.json/lock files), subsequent runs use saved config. DevServerManager runs one server at a time, auto-detects port from output, shows WebView in board area with toggleable console panel. ProcessEnvironment sets BROWSER=none to suppress external browser launch. ZenbanTerminalView overrides link handling to prevent dev server URLs opening externally. Cleanup on dismiss, card delete, and app quit. Toolbar settings button opens DevServerSettingsSheet for manual config editing. Error states offer Reconfigure option.

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| Cmd+Shift+N | New Board |
| Cmd+Shift+A | New Card |
| Cmd+Shift+D | Delete selected card (with confirmation) |
| Cmd+Shift+S | Toggle Dev Server |
| Cmd+Shift+X | Toggle Git Changes |
| Shift+Arrow Up/Down | Navigate cards in column (when in cards) or boards (when in sidebar) |
| Shift+Arrow Left | Previous column, or go to sidebar from first column |
| Shift+Arrow Right | Next column, or go to cards from sidebar |
| Enter | Focus terminal (if not already focused) |

`FocusRegion` enum tracks whether sidebar or cards has keyboard focus. Keyboard navigation uses NSEvent local monitor in AppDelegate for app-wide capture. Sidebar selection uses custom `listRowBackground` for focus-aware styling. DeleteConfirmationView provides arrow-key navigable confirmation dialog.
