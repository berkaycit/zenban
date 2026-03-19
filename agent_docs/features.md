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

- The lower detail pane embeds a cmux-derived Ghostty workspace per card
- `Done` cards keep their terminal closed by default and expose an `Open Terminal` action for manual reopening
- Agent pills update stored card state and relaunch the selected command when needed
- Git Changes, File Browser, and Dev Server actions still open from the card header

## Git Worktrees

- Each card gets its own git worktree on branch `card/<uuid>`
- Worktrees are created lazily and cleaned up on delete
- Git Changes opens a board-area diff and history workspace

## Dev Server

- Per-board setup and dev commands
- Package-manager-aware command detection
- Live setup and process logs during startup
- Ready-state embedded cmux browser preview for the selected card
- `Cmd+Shift+S` toggles the session
- `Cmd+Shift+R` refreshes the current dev server preview

## Notifications And Finder Services

- cmux-derived desktop notifications can reopen the owning card workspace
- Finder Services expose “New Zenban Workspace Here” and “New Zenban Window Here”
- The app bundle includes a cmux-based AppleScript dictionary and English localization catalogs

## Optional Tools

- Settings can check and install Homebrew
- Settings can check and install GitHub CLI
- Settings can check and install Claude Code CLI

## Data Storage

- Boards are stored at `~/Library/Application Support/com.berkaycit.zenban/boards.json`
- Saves are debounced automatically
