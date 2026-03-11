# memory-bank.md

When you make a change, add a new item to the list below describing the change.
Each item should follow this format:
- **Summary**: A concise, single-sentence summary of the changes.
- **Description**: A more detailed description of what was changed and why.

## List

- **Summary**: Move delete confirmation above portal-hosted terminals
- **Description**: Replaced the card delete popup's SwiftUI overlay presentation with an item-driven sheet so the confirmation always renders above Ghostty's AppKit portal layer. `BoardStore` now stores the delete request context (board, card, title) at open time, which keeps confirmation bound to the originally requested card even if selection changes before the user confirms.

- **Summary**: Shorten agent launch hot path
- **Description**: Reduced initial agent startup latency by removing the first explicit card-open debounce, prewarming the tmux server as soon as a workspace record exists, and dropping the bundled Claude/Codex/Gemini wrappers' synchronous socket ping before exec. `TerminalManager` still keeps the rapid-switch debounce behavior for intermediate card changes, so only the first deliberate open becomes immediate. This follows the useful parts of `agent-view`'s faster startup path without changing Zenban's existing worktree-aware launch model.

- **Summary**: Speed up initial git agent startup
- **Description**: Restored the intended two-stage startup path for git-backed cards so agent launch no longer blocks on worktree creation. `TerminalManager` now starts the selected agent from the board repository path immediately, then performs a single worktree-ready handoff only when the launched session still needs to move into the card worktree. `AgentLaunchPlan` now carries an explicit interrupt flag so worktree handoffs and agent switches reuse the same tmux launch path without duplicating restart logic.

- **Summary**: Unify executable lookup and dev command UI
- **Description**: Added a shared `ExecutableLocator` so tmux, npm, and Claude executable discovery all use the same candidate-path and PATH fallback behavior instead of duplicating `which` logic in multiple services. Refactored `PackageJsonParser` to model package managers explicitly and reuse a single lockfile-priority helper for both setup-command and dev-command detection. Also extracted the repeated setup/dev command entry layout in `DevServerCommandSheet` into a local reusable section without changing the existing sheet behavior.

- **Summary**: Debounce auto-launch during rapid card switching
- **Description**: Borrowed the useful part of `agent-view`'s selection-driven scheduling without bringing back its polling model. `TerminalManager` now queues pending agent launches per card, waits 150ms before auto-launching a board-detail card, cancels intermediate launches during rapid navigation, and still launches immediately for detached windows or explicit agent switches. The actual tmux command path moved behind an async `TmuxSessionManager` launch API so card switching no longer blocks the main actor on `send-keys` and environment refresh work. Synced the architecture and feature docs to describe the settled auto-launch behavior.

- **Summary**: Fix explicit agent completion delivery under `cmuxOnly` socket mode
- **Description**: Completion hooks were firing from the Claude/Codex/Gemini wrappers but the local socket rejected them because tmux/agent subprocess ancestry did not always satisfy the inherited `cmuxOnly` check. The socket path now accepts same-user wrapper callbacks when they first authenticate with a per-session token injected into the agent launch environment, and the bundled `cmux` helper now treats socket `ERROR` responses as failures instead of logging false success.

- **Summary**: Simplify agent lifecycle to explicit hooks
- **Description**: Replaced Zenban's tmux pane polling and raw-status parsing with a minimal explicit lifecycle: terminal submit now means `started`, and bundled Claude/Codex/Gemini wrappers report `completed` over the local cmux-compatible socket. The runtime reducer now tracks only whether a card has an active task, still moves `In Review` back to `To Do` on new work, and only notifies when completion actually changes the card back to `In Review`. Synced the architecture, features, and notification docs to describe the new wrapper-based flow.

- **Summary**: Add Claude runtime completion hooks
- **Description**: Wired `claude_hook` socket events into the shared agent runtime so Claude can complete an active task without waiting for tmux polling alone. Completion notifications now fire only when the reducer actually moves a card into `In Review`, which prevents duplicate notifications for cards already there. Synced the architecture, feature, and notification docs to reflect that Claude now has an explicit completion path while Codex and Gemini still rely on tmux heuristics.

- **Summary**: Harden tmux completion notifications
- **Description**: Reworked Zenban's notification path to borrow the defensive pieces of cmux without reintroducing the cmux notification store. `NotificationService` now tracks authorization state, defers the first automatic prompt until the app is active, coalesces notifications per card, and clears stale entries on focus, click, or delete. The tmux workflow also got stricter: launches only arm monitoring after `send-keys` succeeds, board/card reselection on notification click no longer gets cleared by the board-change observer, and repeated pane-capture failures now fall back to `stopped` instead of leaving cards stuck mid-cycle.

- **Summary**: Re-verify notification docs against current code
- **Description**: Re-read the live notification and agent workflow code after user reversions, then corrected the docs to match the current implementation more precisely. Fixed the column naming to `In Review` and tightened the notification workflow wording so it reflects the actual initial-launch, worktree-ready, and agent-switch launch paths in `TerminalManager`.

- **Summary**: Document current notification workflow
- **Description**: Synced the architecture and feature docs with the current tmux-based agent notification code, removing stale references to the older richer telemetry model. Added `agent_docs/notification-workflow.md` as a single reference for how submit detection, raw tmux status polling, card movement, and macOS notifications currently work.

- **Summary**: Gate agent completion on explicit submit
- **Description**: Changed the tmux-driven agent workflow so task cycles start only after Zenban observes a real terminal submit, matching the centralized send model used in `agent-view`. Typing, startup noise, and other tmux activity no longer move cards or trigger completion notifications. The Ghostty terminal surface now reports Enter/newline submits into `AgentSessionMonitor`, while launch and relaunch paths stay internal-only.

- **Summary**: Add tmux-driven agent runtime workflow
- **Description**: Replaced the old direct agent launch and Claude URL-hook path with a shared `AgentLauncher` plus `AgentSessionMonitor` that classifies tmux session output and activity. Cards now stay in `To Do` while work is running or waiting, automatically move to `In Review` on completion, and jump back to `To Do` when the same terminal gets new work. The inherited cmux notification store, unread tab badges, Ghostty notification ring, and related socket commands were removed so Zenban now relies only on its own `NotificationService`.

- **Summary**: Simplify Zenban quick-win cleanup paths
- **Description**: Removed unused helper APIs and stale prompt/notification/cmux compatibility shims that no longer had call sites. Simplified `BoardStore`, `GitChangesView`, `GitDiffViewModel`, and `FileBrowserStore` so overlay handling, diff resets, placeholder UI, and file-browser error/session flows are more centralized. `DevServerManager` now avoids rebuilding the full output string on every log chunk, and `ProcessEnvironment` plus board/file-browser lookups now do less repeated work.

- **Summary**: Restore tmux-backed Ghostty card sessions
- **Description**: Added a new `TmuxSessionManager` and put each terminal split back on its own tmux session without reintroducing `libghostty`. Hidden cards now suspend Ghostty surfaces while their tmux-backed shells keep running, then resume into the same session when the card is shown again. Startup and shutdown now clear stale Zenban tmux sessions, and dependency/settings flows once again require Homebrew plus tmux while keeping `gh` and `claude` optional.

- **Summary**: Remove terminal browser create affordances
- **Description**: Removed the user-facing ways to open browser tabs from the cmux workspace shell, including the empty-pane browser button, browser-create shortcuts, and bonsplit chrome/context-menu affordances. Dev Server preview and internal/socket-driven browser APIs stay intact, so embedded browsers still exist where the app needs them without exposing manual terminal-side creation.

- **Summary**: Refine dev server preview controls
- **Description**: Added a board-level `autoOpenConsole` option so the cmux browser console stays off by default and only opens automatically when requested. The board-area dev server preview now also hides the sidebar for the active session, restores the previous split visibility on close, and supports `Cmd+Shift+R` reloads against the same live browser panel.

- **Summary**: Switch dev server preview to the cmux browser stack
- **Description**: Replaced the board-area dev server overlay's custom WebView and mirrored browser console with a cmux `BrowserPanelView` owned directly by `DevServerView`. Startup logs now stay visible until a ready URL is detected, the cmux JavaScript console auto-opens for the live preview session, `Cmd+Shift+R` reloads the same browser panel, and `DevServerManager` is back to server-process output only while unexpected exits surface the error/log view again.

- **Summary**: Clarify cmux parity and worktree docs
- **Description**: Updated the architecture and feature docs to reflect how Zenban's terminal stack actually differs from upstream cmux. The docs now call out the lazy card-to-workspace mapping, the two-phase worktree startup path, and the fact that detached terminal windows currently host one card workspace at a time. Refreshed agent guidance files so terminal changes are documented against the correct layer.

- **Summary**: Add cmux-style detached terminal windows
- **Description**: Zenban's terminal adapter now uses a single board-owned cmux `TabManager` instead of creating one manager per card, while still keeping card UUIDs as workspace identity. `AppDelegate` now acts as the cmux-style window host contract, tracking the main board window, detached terminal-only windows, and socket routing/focus between them. Detached cards keep their worktree and shell-integration IDs, and the card detail pane now shows a placeholder that focuses the detached terminal window instead of mounting a duplicate host.

- **Summary**: Add cmux-style card handoff for Ghostty
- **Description**: Replaced the terminal section's direct single-card host with a persistent `CardWorkspaceDeckView` that mirrors cmux workspace switching at the card level. Card changes now keep only the selected and retiring workspaces mounted, activate the new card immediately, and explicitly hide retiring terminal/browser portals before unmounting. `TerminalManager` now owns deferred cross-card unfocus and portal-hide helpers so rapid card switching no longer leaves stale Ghostty content visible.

- **Summary**: Replace card terminal host with cmux workspace stack
- **Description**: Zenban now mounts cmux's Ghostty host stack per card by importing the Bonsplit-based workspace/tab manager layer into `zenban/CmuxParity` and mapping `card.id` directly to cmux workspace identity. Added a local socket controller plus bundled `Resources/bin/cmux` helper so shell integration, `claude`, and `open` wrappers can talk to the in-app workspace using cmux-style env vars. Verified with a successful Debug build and bundle inspection showing `claude`, `cmux`, and `open` inside `zenban.app/Contents/Resources/bin`.

- **Summary**: Port cmux host-side Ghostty contract
- **Description**: Extended Zenban's Ghostty host layer to mirror cmux more closely by exporting cmux-style surface/workspace environment variables with card IDs, bundling cmux `Resources/bin` wrappers, and handling additional Ghostty actions such as reload-config, open-url, key-sequence, and key-table updates. The terminal view now tracks runtime background overrides and cmux-style keybinding routing so theme and shortcut behavior line up better with cmux. Verified with a successful Debug build and bundle inspection showing `Resources/bin/claude` and `Resources/bin/open` in the app.

- **Summary**: Finalize cmux-based Ghostty integration
- **Description**: Completed the cmux-aligned Ghostty import so Zenban now packages Ghostty resources with the same bundle layout, reads the user's standard Ghostty config, and syncs macOS appearance into the Ghostty app before surfaces render. Added runtime handling for Ghostty config/color change actions so terminal backgrounds stay aligned with the resolved theme. Removed temporary backup/debug artifacts after verifying the terminal now renders the correct theme.

- **Summary**: Align Ghostty bundle layout with cmux
- **Description**: Moved Zenban's Ghostty resource packaging to the same cmux-style bundle structure by copying repo-root `ghostty`, `terminfo`, and shell-integration assets with an Xcode script phase. Switched runtime config loading back to standard Ghostty user config files, wired Zenban to the cmux shell-integration scripts, and made terminal theme selection respect `window-theme` from the user's config. Verified with a successful Debug build and bundle inspection showing `ghostty/themes`, `terminfo`, and cmux shell integration files in the app resources.

- **Summary**: Restore Ghostty from cmux runtime
- **Description**: Re-enabled the embedded terminal by restoring Zenban's card-based Ghostty adapter layer and wiring it back into the app target. Copied `GhosttyKit.xcframework` plus Ghostty resource files from `clone/cmux`, replaced the config parser with the cmux version, and aligned environment setup with cmux's resource resolution logic. Verified with a successful Debug build using Xcode's full toolchain.

- **Summary**: Remove legacy terminal backend
- **Description**: Deleted the previous embedded terminal implementation, resources, vendor artifacts, build script, and project wiring. `TerminalManager` and terminal settings now act as placeholders so the app stays buildable while the replacement backend is prepared. Documentation was updated to reflect that the embedded terminal is temporarily disabled pending a cmux-based import.

- **Summary**: Replace terminal backend with cmux approach and remove tmux
- **Description**: Replaced the custom embedded terminal integration with a cmux-style approach. Switched from a vendored static archive to an xcframework-based backend. Removed all tmux dependency: deleted TmuxSessionManager, removed tmux from DependencyCheckService, TerminalManager, and settings UI. The app-level terminal wrapper now loads the user's standard config with fallback, adds rich clipboard support, and injects zsh shell integration via ZDOTDIR. Performance optimizations included display ID management for CVDisplayLink vsync, CATransaction batching in layout, color scheme caching, and a Ctrl key fast path bypassing IME.

- **Summary**: Robust Claude CLI install with node support
- **Description**: DependencyCheckService now auto-installs Node.js via Homebrew if npm is missing before installing Claude CLI. Added npmPath() and installNode() functions. ProcessEnvironment extended to detect volta and fnm node managers alongside nvm. New findExecutable() helper consolidates path-checking logic. GeneralSettingsView shows dependency status with check/install buttons.

- **Summary**: Add optional gh and Claude CLI dependencies
- **Description**: DependencyCheckService now tracks four dependencies: Homebrew and tmux (required), gh and Claude Code CLI (optional). Status struct has subscript for cleaner dependency lookup. Optional deps shown with "(Optional)" label in orange; required deps in red when missing. Dialog only auto-shows when required deps are missing. Claude CLI installed via npm with ProcessEnvironment for nvm support.

- **Summary**: Add automatic dependency check and installer
- **Description**: App now checks for Homebrew and tmux on startup and shows inline installer dialog if missing. DependencyCheckService actor handles detection and installation with real-time output streaming. DependencySetupView modal displays status, install progress, and skip option (persisted via UserDefaults). Integrated into app startup via BoardStore.checkDependencies() call.

- **Summary**: Add terminal scroll restoration on card switch
- **Description**: TerminalManager caches scroll state (position + cell size) when hibernating terminals. TerminalScrollView hides terminal on wake until first scrollbar update positions it correctly, then fades in. Eliminates visible scroll animation when switching between cards with scrolled terminals.

- **Summary**: Add Git History tab with fast diff loading
- **Description**: GitChangesView now has two tabs: Changes and History. History tab shows paginated commit list (GitHistoryView) with diff panel. GitLogService actor fetches commits via libgit2 and diffs via non-blocking ProcessExecutor. DiffView refactored from lazy O(n^2) parsing to upfront O(n) single-pass parsing, eliminating DiffLineParser. New utilities: ProcessExecutor for async subprocess execution, RelativeDateFormatter for date display.

- **Summary**: Add Claude Code task completion notifications via URL scheme
- **Description**: Zenban now receives notifications when Claude Code finishes tasks. Registered `zenban://` URL scheme in Info.plist. Claude Code Stop hook calls `open 'zenban://notify?body=...'` which triggers SwiftUI `.onOpenURL`. Handler shows macOS notification with card title and moves card from To Do to In Review. Also added a DESKTOP_NOTIFICATION handler in the previous terminal backend for future OSC 9 support.

- **Summary**: Optimize AI commit message generation for large diffs
- **Description**: generateCommitMessage() now uses smart summarization for large changesets (>200 lines). When threshold exceeded, createSummarizedDiff() builds condensed context: top 30 files listed with +/- stats, top 8 non-binary files fetched in parallel via withTaskGroup, snippets truncated to 300 chars. Binary/generated files (30+ extensions, lock files, .min.js) auto-skipped via shouldSkipFile(). Performance: O(n log n) sort, O(1) dictionary lookup for snippets, array join instead of string concatenation. Timeout reduced from 60s to 30s via new .commitMessage config. Prompt updated to handle both full diff and summarized formats.

- **Summary**: Add browser console capture and structured output lines
- **Description**: DevServerManager now captures browser console messages (log, warn, error, info, debug) via WebView JS injection. OutputLine struct with OutputSource enum replaces raw string buffers for better error/warning categorization. Separate stdout/stderr pipes with partial line buffering prevent mid-line cuts. DevServerView displays colored output based on source type. WebViewContainer injects console override script and communicates via WKScriptMessageHandler.

- **Summary**: Add drag-and-drop file support to terminal
- **Description**: The previous terminal view now accepts file drops via NSDraggingDestination protocol. Dropped files have their paths shell-escaped and sent to terminal as text. Supports multiple files, paths with spaces, and special characters. Enables dragging screenshots/files to Claude CLI.

- **Summary**: Unify overlay state with OverlayState FSM
- **Description**: Replaced separate devServerState, gitChangesCardID, and fileBrowserCardID with single OverlayState enum. Overlays are now mutually exclusive - opening one automatically closes others. Added Cmd+Shift+F shortcut for file browser. OverlayState includes cardID and isDevServer helpers for cleaner delete/cleanup logic.

- **Summary**: Migrate GitService from git CLI to libgit2
- **Description**: GitService now uses libgit2 (native C library via Clibgit2 module) instead of spawning git processes. New Libgit2* files in Services/Git/Libgit2/ wrap C API for repository, branch, commit, diff, remote, status, and worktree operations. SSH authentication via SSHConfigParser for host resolution. Improves performance and reduces process overhead.

- **Summary**: Add batch diff loading and scroll tracking
- **Description**: GitDiffViewModel now supports batch loading via loadAllDiffs() which fetches all file diffs in a single git call and parses them with DiffParser.splitDiffByFile(). GitDiffCache simplified to store [DiffLine] directly with single-file invalidation. DiffView gains scroll tracking (onFileVisible callback), file navigation (scrollToFile), and onOpenFile callback. GitChangesView uses batch loading after fetching file list for faster diff display.

- **Summary**: Add terminal hibernation and LRU eviction
- **Description**: TerminalManager now hibernates terminals when cards are deselected to save memory (tmux preserves sessions in background). LRU cache limits active terminals to 50, evicting least recently used. TerminalContainerView triggers hibernation in dismantleNSView. Scroll views are cached separately for faster restoration. Delayed cleanup prevents dangling pointer crashes during terminal surface teardown.

- **Summary**: Migrate terminal from SwiftTerm to a native backend
- **Description**: Replaced SwiftTerm with a native terminal backend. Removed the old local terminal packages in favor of a vendored terminal archive. A new terminal module added NSView-based rendering, shared app context management, terminal surface management, and input handling types. TerminalManager and TerminalContainerView were updated for the new API.

- **Summary**: Move GitChangesView to board area with toggle
- **Description**: GitChangesView relocated from CardDetailView overlay to ContentView board area (like DevServerView). New Cmd+Shift+X keyboard shortcut toggles the view. BoardStore tracks gitChangesCardID state with toggleGitChanges/stopGitChanges methods. New stopOverlays() method consolidates cleanup of dev server and git changes on board switch or card/board deletion.

- **Summary**: Add delete confirmation dialog and update shortcuts
- **Description**: New DeleteConfirmationView with arrow-key navigation for confirming card deletion. Keyboard shortcuts changed from Shift to Cmd+Shift (A for new card, D for delete, S for toggle dev server). BoardStore gains showDeleteConfirmation state and request/confirm/cancel methods. zenbanApp event monitor updated to skip when dialog is visible.

- **Summary**: Centralize dev server state with FSM in BoardStore
- **Description**: DevServerState enum (idle/configuring/running/reconfiguring) moved to BoardStore for centralized state management. DevServerView relocated from CardDetailView overlay to ContentView, replacing board area when active. Browser suppression added via BROWSER=none in ProcessEnvironment and link handling override in ZenbanTerminalView. Terminal ANSI black color adjusted from #282828 to #676767 for visibility on dark backgrounds.

- **Summary**: Add throttled console output and on-demand diff loading
- **Description**: DevServerManager now limits output buffer to 100KB with throttled UI updates (150ms interval) to prevent performance issues with verbose servers. DevServerView adds toggleable console panel for viewing server output. GitChangesView loads diffs on-demand via GitDiffViewModel with LRU caching. DiffView (NSTableView-based) renders diffs with lazy line parsing. Port detection uses pre-compiled regex and scans only last 2KB of output.

- **Summary**: Add dev server settings sheet and UI improvements
- **Description**: New DevServerSettingsSheet accessible from sidebar toolbar for editing board dev server config (setup command, dev command, skip setup). DevServerView error states now offer Reconfigure option. CardDetailView redesigned with compacted 160px info section, segmented pill controls for column/agent selection, and icon-only quick actions. Refactored repeated board lookups into computed properties.

- **Summary**: Redesign terminal with modern styling
- **Description**: Updated terminal appearance for better readability. TerminalConfiguration.swift now uses static properties for all styling: SF Mono 14pt font, soft white foreground (#D9D9DE), teal cursor (#5FC9E3), selection highlight (#335980). Custom ANSI color palette with One Dark inspired colors - muted normal colors and distinct bright variants for bold text. Background color kept at original (#2A2A27) via TerminalContainerView default. To change colors dynamically, modify TerminalConfiguration static properties and call installColors() for ANSI palette updates.

- **Summary**: Add dev server preview with WebView
- **Description**: New dev server feature for cards with worktrees. DevServerManager handles process lifecycle, setup commands (npm install), and port detection from output. PackageJsonParser auto-detects commands from lock files. DevServerCommandSheet configures setup/dev commands (saved per board). DevServerView shows output during startup, then displays WebView once port is detected. ProcessEnvironment extracted from ClaudeService as shared PATH builder for node/nvm support.

- **Summary**: Add AI commit message generation with Claude CLI
- **Description**: New AIProvider protocol enables pluggable AI services. ClaudeService implements it for Claude Code CLI with path resolution and nvm/node environment setup. GitService.generateCommitMessage uses ClaudeService to generate commit messages from diffs. PromptTemplates enum holds prompts, DefaultCommitMessageParser handles response parsing with fallback strategies. CommitSheet's "Auto-generate" replaced with "Generate with AI" button. GitChangesView improved with hasCommittedChanges state for better Merge/PR button logic.

- **Summary**: Add Git changes view with diff, commit, merge, PR
- **Description**: New Views/Git/ module for viewing and managing worktree changes. GitChangesView overlay shows branch diff with split-view (additions/deletions side by side). Supports commit with auto-generated message, merge to target branch with rollback on failure, and PR creation via gh CLI. GitModels.swift holds GitStatus, FileChange, BranchInfo, PRConfig structs. GitService expanded with branch operations, diff stats, and PR helpers.

- **Summary**: Add keyboard navigation for boards, cards, and terminal
- **Description**: Full keyboard navigation without mouse. Shift+Arrow up/down navigates cards in column or boards in sidebar. Shift+Arrow left/right moves between columns, with left from first column going to sidebar and right from sidebar entering cards. Enter focuses terminal if not already focused. Uses NSEvent local monitor for app-wide key capture. FocusRegion enum tracks focus area. Sidebar selection uses custom listRowBackground for focus-aware styling.

- **Summary**: Make worktree cleanup robust and resilient
- **Description**: Board deletion now cleans up worktrees for all cards. Worktree operations use best-effort cleanup: prune stale entries, remove worktree registration, delete branch, remove directory. Handles edge cases like manually deleted worktrees, leftover branches from failed deletions. Refactored GitService with WorktreePaths struct and shared pruneAndCleanup helper. BoardStore marked @MainActor for thread safety.

- **Summary**: Add automatic git worktree per card
- **Description**: Cards in boards with git repos now get their own worktree automatically. Created on card add (branch: card/uuid), deleted on card delete. Terminal starts in worktree directory. Shell readiness detection via output instead of fixed delay. CardDetailView shows worktree status with Copy Path/Reveal in Finder context menu.

- **Summary**: Add per-card agent switching in card detail
- **Description**: Cards can now override board's default agent. CardDetailView shows agent picker below column buttons. Selecting different agent sends Ctrl+C twice, clears terminal, then launches new agent. Card model has optional agent property (nil = use board's default). TerminalManager.switchAgent handles the terminal commands.

- **Summary**: Add agent selection and Reveal Folder for boards
- **Description**: Board creation now includes agent picker (Claude Code, Codex, Gemini). Selected agent auto-launches in terminal after shell starts. Agent enum in Board.swift stores launch commands. BoardRowView context menu adds "Reveal Folder" to open board directory in Finder. UI improvements: larger popup (420px), bigger buttons, consistent input box styling.

- **Summary**: Add git repository selection for board creation
- **Description**: Board creation now offers three options: select existing directory, create new repository (mkdir + git init), or empty board. Board model has optional `repositoryPath`. TerminalManager uses board's path as terminal start directory (falls back to Documents/Desktop if path missing or deleted). New files: GitService.swift, DirectoryPicker.swift. AddBoardSheet uses multi-step flow with state machine.

- **Summary**: Fix terminal process leaks on card/board deletion and app quit
- **Description**: Three memory leak issues fixed: (1) Card deletion: killSessionForCard now calls process.terminate() to send SIGTERM. (2) Board deletion: deleteBoard calls onCardDeleted for each card before removing the board. (3) App termination: Added willTerminateNotification observer in zenbanApp.init that calls terminateAllSessions(). Note: LocalProcess cleanup in SwiftTerm was attempted but caused crashes, reverted to original. See TerminalManager.swift:25-29, BoardStore.swift:37-47, zenbanApp.swift:16-24.

- **Summary**: Fix Ctrl+R history search agent detection
- **Description**: Ctrl+R sends commands directly to shell without going through inputBuffer. Two problems: (1) ANSI escape codes can split "claude" into "cla\e[0mude", breaking string matching. (2) Excessive terminal output overflows small buffer. Fixed by: stripping ANSI codes with regex before buffering, increasing buffer to 500 chars, and using agentDetectedInOutput flag that persists until Enter. See ZenbanTerminalView.swift:152-177 for implementation.

- **Summary**: Optimize terminal agent detection performance
- **Description**: Replaced Timer with DispatchWorkItem for lighter idle detection. Reduced output buffer from 500 to 100 chars. Optimized string search to check only newly added portion plus keyword overlap. Moved activityByteCount reset to agentActive transition only, removing unnecessary resets.

- **Summary**: Add state machine for Claude agent detection
- **Description**: ZenbanTerminalView now uses state machine (shell/agentActive/agentIdle) to detect Claude agent activity. Detects "claude" in input or output buffers, tracks idle via 2-second timer, handles Ctrl+C exit. Auto-moves cards: agentIdle triggers "In Review", new message moves back to "To Do". NotificationService extended with onTaskCompleted and onAgentResumed callbacks.

- **Summary**: Add terminal task completion notifications
- **Description**: Added macOS notifications when terminal output stops and user is not focused on that terminal. ZenbanTerminalView subclass detects idle state via 2-second timer after output. NotificationService handles UNUserNotificationCenter with click-to-navigate. Made becomeFirstResponder open in local SwiftTerm fork to track focus. Services/ folder added for app-wide services.

- **Summary**: Switch to HSplitView for enforced column widths
- **Description**: Replaced NavigationSplitView with nested HSplitView to enforce minimum column widths that NavigationSplitView ignored when dragging dividers. Layout now has sidebar (160-260px), board (900-950px), and card detail (400px+). Terminal now starts in Documents or Desktop directory. BoardRowView updated to show board name with creation date.

- **Summary**: Fix terminal mouse selection with local SwiftTerm
- **Description**: Removed tmux dependency to fix scroll issues. Found bug in SwiftTerm where yDisp was added twice in mouse coordinate calculation (once in calculateMouseHit, once in selection functions), causing selection offset after scrolling. Using local SwiftTerm fork at LocalPackages/SwiftTerm with fix applied. Simplified TerminalContainerView and TerminalManager, removed TmuxSessionController and AppDelegate.

- **Summary**: Fix terminal robustness and cleanup
- **Description**: Fixed race condition on fast card switching with task cancellation. Added sync cleanup of all zenban tmux sessions on app termination via AppDelegate. Centralized tmux path detection in TmuxSessionController as static reusable methods. Removed async cleanup that caused deadlock. Terminal background color matched to app theme (#2A2A27).

- **Summary**: Add embedded terminal per card with tmux
- **Description**: Added Terminal module using SwiftTerm + tmux for persistent terminal sessions per card. Each card gets a tmux session (zenban_card_UUID) that survives app restarts. TerminalManager handles session lifecycle, TmuxSessionController manages tmux commands. App sandbox disabled for terminal access. Session cleanup on card deletion via BoardStore callback.

- **Summary**: Add card detail panel with selection
- **Description**: Added 3-column NavigationSplitView layout with card detail panel on right. Cards are selected via single tap or drag start. CardDetailView shows column badge, editable title, creation date, and move-to-column buttons. BoardStore tracks selectedCardID with proper cleanup on card/board deletion.

- **Summary**: Add type-safe drag-drop with custom UTType
- **Description**: Card now conforms to Transferable with custom UTType (com.berkaycit.zenban.card) declared in Info.plist. Refactored BoardStore with helper methods for index lookups. Moved Column.accentColor from ColumnHeaderView to Column enum. Removed unused state variables.

- **Summary**: Initial Kanban board implementation
- **Description**: Created full Kanban app with multiple boards, 3 fixed columns (To Do, In Progress, Done), drag-drop cards, JSON persistence with debounced save, keyboard shortcuts (Cmd+N, Cmd+Shift+N). Uses @Observable for state, LazyVStack for performance.
