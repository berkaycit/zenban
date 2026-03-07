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
- Auto-move on task completion (In Progress -> Done via notification)

## Terminal Integration

- Embedded Ghostty terminal is active again
- Runtime/resources are copied from `clone/cmux` with a build phase that recreates cmux's `ghostty`, `terminfo`, and `shell-integration` bundle layout
- Ghostty now reads the user's standard config files (`~/.config/ghostty/config` and Ghostty app-support fallbacks) instead of a Zenban-specific bundled preset
- Zenban pushes macOS appearance into the Ghostty app and each surface so `theme=light:...,dark:...` and `window-theme` resolve the same way they do in cmux
- Terminal reuses suspended surfaces when switching cards

## Git Worktrees

- Each card gets its own git worktree (branch: card/uuid)
- Embedded terminal starts in the card worktree directory
- View Changes button opens diff view
- Worktrees cleaned up on card/board deletion

## Dev Server Preview

- Per-board dev server config (setup/dev commands)
- Auto-detects package manager from lock files
- WebView preview with toggleable console
- Port auto-detection from output
- Toggle with Cmd+Shift+S

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
| Cmd+Shift+X | Toggle Git Changes |
| Shift+Arrow Up/Down | Navigate cards/boards |
| Shift+Arrow Left/Right | Navigate columns |

## Data Storage

- JSON file at `~/Library/Application Support/com.berkaycit.zenban/boards.json`
- Auto-saves with 500ms debounce
