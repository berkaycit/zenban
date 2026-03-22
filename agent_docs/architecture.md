# Architecture

## Directory Structure

- `zenban/Models`: Board, card, column, git, and AI data models
- `zenban/Storage`: JSON persistence
- `zenban/ViewModels`: `@Observable` app state
- `zenban/Views`: sidebar, board, card, git, dev server, settings, shared components
- `zenban/Services`: git, AI, dev server, dependency, process helpers, and Zellij session management
- `zenban/CmuxImport`: copied cmux Swift host layer, panels, browser, notifications, and AppleScript support
- `zenban/CmuxHostStore.swift`: Zenban adapter that maps cards 1:1 onto cmux workspaces
- `cmux-import/`: copied cmux CLI, Ghostty runtime, bonsplit package, and bundled assets
- `zenban/Utilities`, `Commands`, `Extensions`: shared helpers and app commands

## Data Flow

1. `BoardStore` owns app state, selection, overlays, worktree actions, and settings flows.
2. `BoardStorage` persists `boards.json` with debounced saves.
3. Views read and mutate state through `@Environment(BoardStore.self)`.
4. Services perform side effects such as git operations, process execution, and tool availability checks.

## Key Components

- `BoardStore`: Central state manager for boards, cards, overlays, worktrees, and dev server configuration.
- `BoardStorage`: JSON persistence under Application Support.
- `CmuxHostStore`: Card-scoped workspace registry, Ghostty/Zellij residency control, agent auto-launch bridge, browser surface management, and notification-to-card routing.
- `ZellijSessionManager`: Bundles and owns the root workspace Zellij session plus independent panel-scoped sessions, along with attach scripts, config isolation, and quit-time cleanup.
- `GitService`: libgit2-backed repository, worktree, diff, commit, push, merge, and PR helpers.
- `DevServerManager`: Runs setup and dev commands, buffers output, detects ready URLs, and owns process lifecycle.
- `DependencyCheckService`: Reports whether external tools like `git` and `Claude Code CLI` are available on this Mac.
- `GitChangesView`: Board-area diff and history workspace for the selected card.
- `GitLogService`: Async commit history and diff loading.
- `DiffView`: Native diff renderer with file navigation and copy support.

## Board Creation

Boards can point at an existing directory, create a new git repository, or stay empty. Board-level agent selection still exists as saved metadata.

## Card Worktrees

For git-backed boards, each card gets its own worktree at `../repo-worktrees/` on branch `card/<uuid>`. Cleanup removes worktrees and prunes card branches on card or board deletion when possible.

## Card Detail

The detail pane shows card metadata, column controls, agent selection, and worktree status above an embedded cmux `WorkspaceContentView`. `To Do` and `In Review` cards lazily create a workspace from the card worktree or board repository path; the first terminal panel is the workspace-root managed session that owns Claude launch delivery, while later Ghostty-created tabs and splits get independent persistent Zellij sessions keyed by panel. Agent auto-launch now uses two related paths in `CmuxHostStore` and `ZellijSessionManager`: the root session keeps the tokenized workspace-scoped launch-request queue that waits for `launch_request_started`, while each independent panel writes the card's currently selected agent command into its own panel-scoped launch request file the first time that panel session starts. Hidden interactive cards can reclaim Ghostty runtime surfaces without killing either the root session or independent panel sessions, and `Done` cards keep the whole workspace closed until the user explicitly reopens it from the detail CTA.

## Dev Server

Boards store `DevServerConfig` with `setupCommand`, `devCommand`, and `skipSetup`. `DevServerView` keeps logs visible during startup, then mounts a cmux `BrowserPanelView` for the selected card once the server is ready. `DevServerManager` persists app-owned process groups so quit and next-launch recovery can reclaim stale listeners before falling back to an alternate port. `ProcessEnvironment` still sets `BROWSER=none` so dev commands do not open an external browser automatically.

## Notifications And Scripting

`zenbanApp` bootstraps copied cmux app delegate state, Ghostty resources, bundled Zellij resources, and socket defaults before SwiftUI renders. `TerminalNotificationStore` still owns the desktop notification flow, and card routing continues to work even when a card terminal is detached because cmux-targeted notifications and Claude hooks do not depend on a mounted Ghostty surface. `cmux.sdef` exposes AppleScript support, and Finder Services call back into the copied `openTab` and `openWindow` handlers.

## Keyboard Shortcuts

`Cmd+Shift+N` creates a board, `Cmd+Shift+A` creates a card, `Cmd+Shift+E` deletes the selected card, `Cmd+Shift+S` toggles the dev server, `Cmd+Shift+R` refreshes the dev server preview, `Cmd+Shift+C` toggles the focused preview console or drives the Git commit flow, `Cmd+Shift+X` toggles Git Changes, and `Shift+Arrow` shortcuts move selection across boards, cards, and columns. When a Ghostty terminal has focus, terminal-local shortcuts such as tab creation, splits, close, and terminal-tab navigation are owned by the Zenban-scoped Ghostty config rather than `KeyboardShortcutSettings`.
