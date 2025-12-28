# Architecture

## Directory Structure

```
zenban/
├── Models/          # Data models (Board, Card, Column)
├── Storage/         # JSON persistence layer
├── ViewModels/      # @Observable state management
├── Views/
│   ├── Sidebar/     # Board list navigation
│   ├── Board/       # Kanban board layout
│   ├── Card/        # Card display and editing
│   └── Components/  # Reusable UI components
├── Terminal/        # Embedded terminal per card (SwiftTerm)
├── Services/        # App-wide services (notifications, git operations)
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
| `BoardStore` | Central state manager with `sortedBoards` (pinned first). Skips redundant column moves. |
| `BoardStorage` | JSON persistence to Application Support |
| `Board` | Data model with `isPinned` and optional `repositoryPath` for directory association |
| `Column` | Enum with display name and accent color |
| `HSplitView` | Three-column layout: sidebar, board, card detail (enforces min widths) |
| `ColumnView` | Handles drag-drop with `.onDrag` and `.dropDestination()` |
| `CardDetailView` | Right panel for viewing and editing selected card |
| `TerminalManager` | Manages terminal views per card. Uses board's `repositoryPath` as start directory. Terminates processes on card/board deletion and app quit. |
| `ZenbanTerminalView` | Terminal with state machine for Claude detection. Strips ANSI codes for Ctrl+R support. Auto-moves cards between columns. |
| `NotificationService` | macOS notifications + card movement callbacks (onTaskCompleted, onAgentResumed) |
| `GitService` | Creates git repositories (mkdir + git init) |
| `DirectoryPicker` | NSOpenPanel wrapper for folder selection |

## Board Creation

Three options when creating a board:
1. **From Existing Directory** - Select folder, terminal starts there
2. **Create New Repository** - Create folder + `git init`
3. **Empty** - No directory association (default behavior)

## Terminal Agent Detection

State machine with 3 states: `shell` → `agentActive` → `agentIdle`

**Flow:**
1. User types "claude" + Enter → `agentActive`, card stays
2. User sends message to Claude → card moves to "To Do"
3. Claude responds, 2s idle → `agentIdle`, card moves to "In Review"
4. User sends new message → back to step 2
5. Ctrl+C exits → back to `shell`

**Ctrl+R Support:** Shell history search bypasses input buffer. Solution: monitor output buffer for "claude", strip ANSI codes (they split keywords), persist flag until Enter.

**Key Guards:**
- `hasBeenFocused`: prevents triggering on terminal init
- `minActivityBytes`: ignores tiny outputs (< 10 bytes)
- `BoardStore.moveCard`: skips if card already in target column
