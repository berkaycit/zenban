# memory-bank.md

When you make a change, add a new item to the list below describing the change.
Each item should follow this format:
- **Summary**: A concise, single-sentence summary of the changes.
- **Description**: A more detailed description of what was changed and why.

## List

- **Summary**: Migrate terminal from SwiftTerm to Ghostty
- **Description**: Replaced SwiftTerm terminal emulator with Ghostty. Removed LocalPackages/SwiftTerm and LocalPackages/GhosttySwift in favor of vendored libghostty.a static library. New GhosttyTerminal/ module contains Swift wrappers: GhosttyTerminalView (NSView-based terminal), Ghostty.App (singleton app context), Ghostty.Surface (terminal surface management), plus input handling (Key, KeyEvent, MouseEvent, Mods, Input). TerminalManager and TerminalContainerView updated for new API.

- **Summary**: Move GitChangesView to board area with toggle
- **Description**: GitChangesView relocated from CardDetailView overlay to ContentView board area (like DevServerView). New Cmd+Shift+X keyboard shortcut toggles the view. BoardStore tracks gitChangesCardID state with toggleGitChanges/stopGitChanges methods. New stopOverlays() method consolidates cleanup of dev server and git changes on board switch or card/board deletion.

- **Summary**: Add delete confirmation dialog and update shortcuts
- **Description**: New DeleteConfirmationView with arrow-key navigation for confirming card deletion. Keyboard shortcuts changed from Shift to Cmd+Shift (A for new card, D for delete, S for toggle dev server). BoardStore gains showDeleteConfirmation state and request/confirm/cancel methods. zenbanApp event monitor updated to skip when dialog is visible.

- **Summary**: Centralize dev server state with FSM in BoardStore
- **Description**: DevServerState enum (idle/configuring/running/reconfiguring) moved to BoardStore for centralized state management. DevServerView relocated from CardDetailView overlay to ContentView, replacing board area when active. Browser suppression added via BROWSER=none in ProcessEnvironment and link handling override in ZenbanTerminalView. Terminal ANSI black color adjusted from #282828 to #676767 for visibility on dark backgrounds.

- **Summary**: Add throttled console output and on-demand diff loading
- **Description**: DevServerManager now limits output buffer to 100KB with throttled UI updates (150ms interval) to prevent performance issues with verbose servers. DevServerView adds toggleable console panel for viewing server output. GitChangesView loads diffs on-demand when files are expanded instead of preloading all. DiffContentView parses diffs asynchronously with 300-line limit and "show more" button. Port detection uses pre-compiled regex and scans only last 2KB of output.

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
