# Features

## Kanban Board

- Three fixed columns: `To Do`, `In Review`, and `Done`
- Multiple boards with sidebar navigation
- Drag-and-drop cards between columns
- Board pinning in the sidebar
- Board-level default agent selection

## Card Management

- Create cards with `Cmd+Shift+A`
- Delete cards with `Cmd+Shift+D`
- Override the board agent per card
- Persist agent choice as card metadata without launching any runtime
- Show worktree readiness in the detail pane for git-backed boards

## Card Detail Placeholder

- The lower detail pane is a temporary terminal placeholder
- Agent pills still update stored card state
- Git Changes, File Browser, and Dev Server actions still open from the card header

## Git Worktrees

- Each card gets its own git worktree on branch `card/<uuid>`
- Worktrees are created lazily and cleaned up on delete
- Git Changes opens a board-area diff and history workspace

## Dev Server

- Per-board setup and dev commands
- Package-manager-aware command detection
- Live setup and process logs during startup
- Ready-state placeholder showing the detected local URL
- `Cmd+Shift+S` toggles the session
- `Cmd+Shift+R` restarts the current session

## Optional Tools

- Settings can check and install Homebrew
- Settings can check and install GitHub CLI
- Settings can check and install Claude Code CLI

## Data Storage

- Boards are stored at `~/Library/Application Support/com.berkaycit.zenban/boards.json`
- Saves are debounced automatically
