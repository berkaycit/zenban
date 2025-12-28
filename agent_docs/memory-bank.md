# memory-bank.md

When you make a change, add a new item to the list below describing the change.
Each item should follow this format:
- **Summary**: A concise, single-sentence summary of the changes.
- **Description**: A more detailed description of what was changed and why.

## List

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
