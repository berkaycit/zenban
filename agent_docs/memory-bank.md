# memory-bank.md

When you make a change, add a new item to the list below describing the change.
Each item should follow this format:
- **Summary**: A concise, single-sentence summary of the changes.
- **Description**: A more detailed description of what was changed and why.

## List

- **Summary**: Automate Claude-driven card column moves
- **Description**: `CmuxHostStore` now observes Claude lifecycle signals from the copied cmux notification and status streams. Completion notifications move the owning card into `In Review`, while Claude returning to active work moves it back to `To Do`. Added focused lifecycle regression tests around the completion and status classification rules.

- **Summary**: Add cmux localization and scripting resources
- **Description**: Added English-only `Localizable.xcstrings` and `InfoPlist.xcstrings` copied from cmux plus `cmux.sdef` for the app bundle. `Info.plist` now exposes Finder Services and the cmux AppleScript dictionary while intentionally leaving out cmux update-feed metadata and `http/https` URL handling.

- **Summary**: Embed copied cmux host stack
- **Description**: Replaced the stripped-down placeholder state with a copied cmux host stack under `zenban/CmuxImport` and `cmux-import/`. `CmuxHostStore` now maps cards 1:1 to cmux workspaces, launches the selected agent in the embedded Ghostty surface, and opens cmux browser panels for dev server previews. Desktop notifications now route back into Zenban card selection through the copied cmux notification store and app delegate wiring.

- **Summary**: Remove embedded runtime and preview host
- **Description**: Deleted the current embedded terminal, browser host, notification flow, and agent launch runtime from the app, project settings, and bundled resources. Card detail and ready-state dev server views now show placeholders while keeping worktrees, git tooling, and dev server logs intact. Updated the architecture and feature docs to match this temporary stripped-down state before a future replacement is copied in.

- **Summary**: Unify executable lookup and dev command UI
- **Description**: Added a shared `ExecutableLocator` so npm and Claude executable discovery use the same candidate-path and PATH fallback behavior. Refactored package-manager parsing to reuse one lockfile-priority helper for setup-command and dev-command detection. Also cleaned up the repeated setup and dev command entry layout in the command sheet.

- **Summary**: Simplify quick-win cleanup paths
- **Description**: Removed unused helper APIs and stale compatibility shims that no longer had call sites. Simplified overlay handling, diff resets, placeholder UI, and file-browser error/session flows so more of the logic lives in one place. `DevServerManager` also now avoids rebuilding the full output string on every log chunk.

- **Summary**: Robust Claude CLI install with node support
- **Description**: `DependencyCheckService` now installs Node.js first when npm is missing before attempting the Claude Code CLI install. `ProcessEnvironment` was extended to better detect common node managers. The settings UI now shows check and install actions for each optional tool.

- **Summary**: Add Git History tab with fast diff loading
- **Description**: `GitChangesView` now includes both file changes and commit history. `GitLogService` loads commits and diffs asynchronously, and the diff renderer was rewritten for linear parsing to avoid slow repeated scans.

- **Summary**: Optimize AI commit message generation
- **Description**: Commit message generation now summarizes large changesets instead of always sending full diffs. The summarization path prioritizes representative files, trims oversized snippets, and skips generated or binary files to reduce latency and token usage.

- **Summary**: Unify overlay state with OverlayState FSM
- **Description**: Replaced separate overlay flags with a single `OverlayState` enum so dev server, git changes, and file browser views stay mutually exclusive. The store now centralizes cleanup when boards or cards change. This also made new overlay-specific shortcuts easier to add safely.

- **Summary**: Migrate GitService to libgit2
- **Description**: `GitService` now uses libgit2 instead of spawning git processes for core repository operations. Native repository, diff, branch, remote, and worktree helpers reduce process overhead and improve consistency across git features.

- **Summary**: Add batch diff loading and scroll tracking
- **Description**: Diff loading now supports fetching multiple file diffs in one pass and caches parsed output more directly. The diff UI also tracks visible files for better navigation and smoother synchronization with the file list.

- **Summary**: Move Git Changes to the board area
- **Description**: The Git Changes experience moved out of the card detail pane into the main board area, matching the dev server presentation model. A dedicated toggle action now opens and closes it without fighting other overlays.

- **Summary**: Add delete confirmation dialog
- **Description**: Added a dedicated delete confirmation flow for cards and updated keyboard shortcuts around destructive actions. The store now keeps delete request context so confirmation always applies to the intended card.
