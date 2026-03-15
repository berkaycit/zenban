# Architecture

## Directory Structure

- `zenban/Models`: Board, card, column, git, and AI data models
- `zenban/Storage`: JSON persistence
- `zenban/ViewModels`: `@Observable` app state
- `zenban/Views`: sidebar, board, card, git, dev server, settings, shared components
- `zenban/Services`: git, AI, dev server, dependency, and process helpers
- `zenban/CmuxImport`: copied cmux Swift host layer, panels, browser, notifications, and AppleScript support
- `zenban/CmuxHostStore.swift`: Zenban adapter that maps cards 1:1 onto cmux workspaces
- `cmux-import/`: copied cmux CLI, Ghostty runtime, bonsplit package, and bundled assets
- `zenban/Utilities`, `Commands`, `Extensions`: shared helpers and app commands

## Data Flow

1. `BoardStore` owns app state, selection, overlays, worktree actions, and settings flows.
2. `BoardStorage` persists `boards.json` with debounced saves.
3. Views read and mutate state through `@Environment(BoardStore.self)`.
4. Services perform side effects such as git operations, process execution, and tool installation.

## Key Components

- `BoardStore`: Central state manager for boards, cards, overlays, worktrees, and dev server configuration.
- `BoardStorage`: JSON persistence under Application Support.
- `CmuxHostStore`: Card-scoped workspace registry, agent auto-launch bridge, browser surface management, and notification-to-card routing.
- `GitService`: libgit2-backed repository, worktree, diff, commit, push, merge, and PR helpers.
- `DevServerManager`: Runs setup and dev commands, buffers output, detects ready URLs, and owns process lifecycle.
- `DependencyCheckService`: Checks and installs optional developer tools.
- `GitChangesView`: Board-area diff and history workspace for the selected card.
- `GitLogService`: Async commit history and diff loading.
- `DiffView`: Native diff renderer with file navigation and copy support.

## Board Creation

Boards can point at an existing directory, create a new git repository, or stay empty. Board-level agent selection still exists as saved metadata.

## Card Worktrees

For git-backed boards, each card gets its own worktree at `../repo-worktrees/` on branch `card/<uuid>`. Cleanup removes worktrees and prunes card branches on card or board deletion when possible.

## Card Detail

The detail pane shows card metadata, column controls, agent selection, and worktree status above an embedded cmux `WorkspaceContentView`. Each selected card lazily gets its own workspace rooted at the card worktree or board repository path.

## Dev Server

Boards store `DevServerConfig` with `setupCommand`, `devCommand`, and `skipSetup`. `DevServerView` keeps logs visible during startup, then mounts a cmux `BrowserPanelView` for the selected card once the server is ready. `ProcessEnvironment` still sets `BROWSER=none` so dev commands do not open an external browser automatically.

## Notifications And Scripting

`zenbanApp` bootstraps copied cmux app delegate state, Ghostty resources, and socket defaults before SwiftUI renders. `TerminalNotificationStore` provides the desktop notification flow, `cmux.sdef` exposes AppleScript support, and Finder Services call back into the copied `openTab` and `openWindow` handlers.

## Keyboard Shortcuts

`Cmd+Shift+N` creates a board, `Cmd+Shift+A` creates a card, `Cmd+Shift+E` deletes the selected card, `Cmd+Shift+S` toggles the dev server, `Cmd+Shift+R` reloads it, `Cmd+Shift+X` toggles Git Changes, and `Shift+Arrow` shortcuts move selection across boards, cards, and columns.
