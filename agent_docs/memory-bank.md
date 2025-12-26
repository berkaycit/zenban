# memory-bank.md

When you make a change, add a new item to the list below describing the change.
Each item should follow this format:
- **Summary**: A concise, single-sentence summary of the changes.
- **Description**: A more detailed description of what was changed and why.

## List

- **Summary**: Add embedded terminal per card with tmux
- **Description**: Added Terminal module using SwiftTerm + tmux for persistent terminal sessions per card. Each card gets a tmux session (zenban_card_UUID) that survives app restarts. TerminalManager handles session lifecycle, TmuxSessionController manages tmux commands. App sandbox disabled for terminal access. Session cleanup on card deletion via BoardStore callback.

- **Summary**: Add card detail panel with selection
- **Description**: Added 3-column NavigationSplitView layout with card detail panel on right. Cards are selected via single tap or drag start. CardDetailView shows column badge, editable title, creation date, and move-to-column buttons. BoardStore tracks selectedCardID with proper cleanup on card/board deletion.

- **Summary**: Add type-safe drag-drop with custom UTType
- **Description**: Card now conforms to Transferable with custom UTType (com.berkaycit.zenban.card) declared in Info.plist. Refactored BoardStore with helper methods for index lookups. Moved Column.accentColor from ColumnHeaderView to Column enum. Removed unused state variables.

- **Summary**: Initial Kanban board implementation
- **Description**: Created full Kanban app with multiple boards, 3 fixed columns (To Do, In Progress, Done), drag-drop cards, JSON persistence with debounced save, keyboard shortcuts (Cmd+N, Cmd+Shift+N). Uses @Observable for state, LazyVStack for performance.
