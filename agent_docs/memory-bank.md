# memory-bank.md

When you make a change, add a new item to the list below describing the change.
Each item should follow this format:
- **Summary**: A concise, single-sentence summary of the changes.
- **Description**: A more detailed description of what was changed and why.

## List

- **Summary**: Add TCC-safe Zenban testing skill
- **Description**: Added the repo-local `zenban-tcc-safe-testing` skill under `.agents/skills/` so future notification, hook, terminal-agent, app-hosted xcodebuild, and Computer verification runs use cache-backed state by default. The skill documents the required `CMUX_UI_TEST_MODE=1` and `CMUX_UI_TEST_BOARD_STORAGE_DIRECTORY=~/Library/Caches/Zenban/...` launch pattern, forbids protected Desktop/Documents/Downloads/Photos/Music workdirs, and includes a wrapper script for TCC-safe `xcodebuild` invocations.

- **Summary**: Clarify TCC-safe app-hosted test launches
- **Description**: App-hosted `xcodebuild` tests that can launch Zenban must be prefixed with `CMUX_UI_TEST_MODE=1` and `CMUX_UI_TEST_BOARD_STORAGE_DIRECTORY` pointing under `~/Library/Caches/Zenban/...`. Running those tests without the cache-backed env can boot the normal Zenban app state and surface stale TCC-protected folders such as Desktop, Documents, Downloads, Photos, or Music. If prompts reappear, clear stale app state such as `NSOSPLastRootDirectory` and rerun from a cache-backed board/workdir.

- **Summary**: Restore visible card terminal startup and narrow git worktree latency
- **Description**: Computer verification on the real `voxel-pipeline` board reproduced two separate issues: a card terminal could stay visually blank until the Ghostty view was clicked, and git-backed new cards spent most of their time in `Preparing workspace...` while the card worktree was being checked out. Visible workspace transitions now explicitly start/reattach the terminal surface, system `git` resolution is cached, initial workspace git metadata probes start later and stop after a usable snapshot, and new-card worktree creation uses system `git worktree add` without unconditional stale cleanup on the hot path. Follow-up Computer checks with `cc-33` and `cc-34` showed the terminal appears without clicking; remaining delay is dominated by the repo checkout itself. On `voxel-pipeline`, each worktree is about 3.6 GB, `repo-worktrees/card` was about 34 GB, and the disk had only about 1.7 GB free, so future speed tests should account for disk pressure before blaming terminal rendering. Continue using cache-backed `CMUX_UI_TEST_MODE=1` fixtures with `CMUX_UI_TEST_BOARD_STORAGE_DIRECTORY` under `~/Library/Caches/Zenban/...` for automated terminal/notification tests so TCC prompts for Desktop, Documents, Downloads, Photos, and Music do not block the run.

- **Summary**: Speed up interactive Zellij agent launch
- **Description**: Selected-card launches now let the visible Ghostty/Zellij surface start directly and start interactive Zellij session preparation in parallel when the terminal surface has not loaded yet. This keeps the fast visible path without regressing newly-created git-backed cards, where skipping preparation entirely made the first terminal/agent startup happen visibly late. Background-prewarm still awaits preparation ahead of time, while interactive launch polling checks readiness every 50ms instead of 200ms. Computer verification for terminal launch work should keep using cache-backed `CMUX_UI_TEST_MODE=1` fixtures with `CMUX_UI_TEST_BOARD_STORAGE_DIRECTORY` under `~/Library/Caches/Zenban/...` so TCC-protected Desktop, Documents, Downloads, Photos, and Music prompts do not block tests.

- **Summary**: Keep Zellij launch retries alive through slow shell startup
- **Description**: Git-backed card terminals no longer give up after a single missing `launch_request_started` acknowledgement. Pending Claude launches now retry automatically for a longer window, accept acknowledgements from the panel that owned the queued launch request even if the workspace panel mapping changes, and only fall back to manual selection-sync retry after the automatic retry limit is exhausted. Computer verification should continue using cache-backed `CMUX_UI_TEST_MODE=1` fixtures so TCC-protected Desktop, Documents, Downloads, Photos, and Music prompts do not block terminal launch tests.

- **Summary**: Align Ghostty header with linked kit
- **Description**: Zenban keeps the current copied `GhosttyKit.xcframework` instead of upgrading to cmux's newer Ghostty submodule pointer. The copied `ghostty.h` now matches the canonical header for the linked `7dd589824d4c9bda8265355718800cccaf7189a0` GhosttyKit, while Swift-only compatibility declarations cover the extra selection symbols exported by that binary. Future Ghostty upgrades should update framework, header, and Swift adapter code together.

- **Summary**: Port focus-neutral cmux layout commands
- **Description**: After auditing the latest 45 upstream cmux commits, Zenban now carries the local, cloud-free pieces that affect copied runtime behavior: focus-neutral workspace/surface/pane creation, split-off routing, browser and markdown open focus flags, scoped surface config reloads, and Claude OSC suppression gated by the integration setting. The new `surface.split_off` socket method resolves real surfaces across windows, refuses empty-source split-offs, and preserves focus unless the caller explicitly passes `--focus true`. Review-bot, CI, cloud/VM, upstream sidebar PR UI, and settings-file-store commits stayed out of scope because they do not map cleanly onto Zenban's embedded card host.

- **Summary**: Port local cmux socket write hardening
- **Description**: After auditing the last two months of upstream cmux commits, Zenban now carries the relevant cloud-free socket response write hardening from cmux: listener sockets are protected with `SO_NOSIGPIPE` before being made non-blocking, accepted socket clients are restored to blocking mode with a send timeout, socket responses write the full payload and stop on failed writes, and fast-closing accepted peers no longer spam `accept_client_config.failed`. The stale notification-ring state variable left after the OSC notification rendering fix was also removed. The audit confirmed the copied CLI and shell integration are otherwise already at the current cmux surface plus Zenban's Zellij launch additions.

- **Summary**: Keep notification tests out of TCC-protected folders
- **Description**: Computer-driven notification and hook verification should launch Zenban with `CMUX_UI_TEST_MODE=1` and `CMUX_UI_TEST_BOARD_STORAGE_DIRECTORY` under `~/Library/Caches/Zenban/...`, then verify launched agents inherit that cache path in `CMUX_AGENT_LAUNCH_CWD` and `PWD`. Avoid Desktop, Documents, Downloads, Photos, and Music during unattended tests; if prompts return, check stale app state such as `NSOSPLastRootDirectory` before retesting notification delivery.

- **Summary**: Restore bundled agent notification hooks
- **Description**: Zenban `cmuxOnly` socket authorization now trusts the bundled cmux helper when it is launched from a Zenban terminal with the active socket, bundle, and surface environment, so Claude/Codex wrapper hooks can still deliver completion notifications after Zellij re-parents the shell outside the app process tree. Agent launch signatures also include the resolved launch command so wrapper changes force relaunch, and local notification verification should use a cache-backed workdir instead of protected user folders to avoid macOS TCC prompts.

- **Summary**: Route Codex launches through bundled hooks
- **Description**: Codex cards now launch the bundled `bin/codex` wrapper instead of relying on global Codex hook installation. The wrapper injects Zenban socket hooks at process launch, while the notification queue and delivery path now log accepted, dropped, suppressed, and scheduled events for reproducible agent notification debugging.
- **Summary**: Sync cmux CLI hooks and socket parity
- **Description**: Refreshed the copied cmux CLI, shell integrations, Bonsplit package, Claude/Codex hook handling, Feed TUI and OpenCode plugin resources, notification queue, Feed socket bridge, top/debug/equalize socket methods, tab move-to-new-workspace server path, and local terminal paste/drop behavior against the recent upstream window. Zenban keeps cloud, VM, remote, and upstream sidebar UI paths out of scope while preserving the valuable local hook, notification, and terminal workspace surfaces.

- **Summary**: Auto-launch selected agent in extra terminals
- **Description**: Ghostty-created tabs and splits now queue the card's currently selected agent command into each panel session's own Zellij launch-request file the first time that independent terminal starts. This keeps the root workspace terminal on the existing acknowledged Claude launch path while making new tabs and splits feel like full card terminals instead of empty shells. The extra panels still keep isolated sessions, so their shell state stays separate even though they launch the same selected agent by default.

- **Summary**: Let Ghostty own terminal-local tabs and splits
- **Description**: Embedded terminal shortcuts now defer to Ghostty's own bindings when a Ghostty surface is focused, so remapping `new_tab`, `new_split`, `previous_tab`, `next_tab`, or `close_surface` in Zenban's app-scoped Ghostty config takes effect without host-level overrides. The workspace root terminal keeps the managed Claude/Zellij launch flow, but extra tabs and splits now get independent persistent Zellij sessions keyed by panel instead of sharing the root shell. Hidden-card runtime reclaim preserves both the root session and those independent panel sessions so reopening a card restores the same terminal topology.

- **Summary**: Isolate Zenban Ghostty config from system Ghostty
- **Description**: Zenban now seeds a dedicated Ghostty config file in its own Application Support directory and opens that file from `Ghostty Settings…` instead of the shared standalone Ghostty config. Embedded terminals reload only the Zenban-scoped config plus bundled overrides, so system Ghostty edits no longer bleed into Zenban. The seeded default config includes the app's preferred theme, typography, split bindings, and `Alt+Shift+Left/Right` tab navigation defaults on first launch.

- **Summary**: Expose Ghostty config controls in Zenban
- **Description**: Zenban now surfaces `Ghostty Settings…` and `Reload Configuration` in the active app menu and in General settings so embedded terminals can pick up config edits without leaving the app. Reloaded Ghostty `previous_tab` and `next_tab` bindings now map to terminal tab cycling in the focused pane when a terminal is focused, while `Cmd+T` stays owned by Zenban's existing New Surface flow. Added focused shortcut regressions so the new bridge only consumes events from terminal focus and does not break the existing split-navigation overrides.

- **Summary**: Expand terminal fullscreen to app content
- **Description**: Terminal fullscreen no longer stops at the detail column. When Ghostty toggles fullscreen for the selected card, Zenban now swaps out the split view and lets that card's detail view own the full app content area while keeping window chrome unchanged. The existing cleanup and shortcut routing rules stay the same, and a new root-view regression locks the presentation mode switch.

- **Summary**: Add Ghostty-driven terminal fullscreen mode
- **Description**: When the selected card's embedded Ghostty terminal is focused, `Cmd+Shift+T` now routes Ghostty's fullscreen action into a Zenban-only detail fullscreen mode instead of relying on window fullscreen. `BoardStore` tracks the fullscreen card and clears it when card selection, board selection, overlays, or workspace lifecycle changes. The card detail view now hides metadata while fullscreen is active, and focused regressions cover both store cleanup and Ghostty-to-host routing.

- **Summary**: Stop Zenban debug from opening standalone cmux
- **Description**: Zenban now treats the copied cmux app shell as an embedded host instead of a standalone window/session manager when the app bundle is `com.berkaycit.zenban`. Main-window registration no longer triggers cmux startup session restore or autosave in Zenban, and standalone fallback paths that previously created a fresh cmux window now return early. Zenban debug builds also use their own socket path instead of sharing `/tmp/cmux-debug.sock`, and focused regression tests cover the embedded-host guards and socket split.

- **Summary**: Align runtime tool messaging with actual dependencies
- **Description**: `DependencyCheckService` now acts as a read-only availability checker for external `git` and `Claude Code CLI` only, while Settings shows bundled-vs-external tool status without install CTAs. Git history/diff loading now fails with a clear system-git message instead of silently degrading, PR creation remains token-and-API based with no `GitHub CLI` dependency, and the user-facing docs now state that Zenban already bundles its own terminal runtime.

- **Summary**: Refine Zellij launch lifecycle handling
- **Description**: Zellij-backed card sessions now move their blocking session prep and cleanup work into a dedicated process runner, while `CmuxHostStore` uses a single queue-and-ack launch path with timeout-based retry instead of the legacy direct-send branch. Startup attach scripts and launch env are cached per workspace so repeated selection syncs do not rewrite the same files, recoverable setup failures now log and preserve pending prompts instead of crashing, and dead launch-shell plumbing was removed. Added focused launch, lifecycle, environment, and session-manager regressions around retry, cleanup, hidden detach, and startup wiring.

- **Summary**: Queue Claude launch until shell ack
- **Description**: Claude launch delivery now writes a tokenized Zellij request file and waits for a shell-side `launch_request_started` acknowledgement before Zenban finalizes launch state. Visible cards nudge the prompt with a newline instead of injecting the full Claude command through Ghostty, and pending launches survive workspace recreation until they are acknowledged. Shell integration, host-store state, and launch regression tests were updated together so the post-Zellij race no longer drops Claude starts silently.

- **Summary**: Back card terminals with bundled Zellij sessions
- **Description**: Card workspaces now launch their shell inside a bundled Zellij session while Ghostty acts as the visible renderer. Hidden cards release their Ghostty runtime surface after a short delay but keep shells, agents, and targeted notifications alive through the preserved session. `Done` cards still stay closed by default, reopen on demand, and tear their session back down when the user leaves the card.

- **Summary**: Simplify preview shortcuts and dev server cleanup
- **Description**: Preview shortcut routing now stays in one Zenban override that reuses the copied cmux browser APIs and treats `Cmd+Shift+C` as a focused-preview toggle instead of a one-way console opener. `DevServerManager` dropped the root-PID tree cleanup model in favor of persisted app-owned process groups, which makes quit-time cleanup and next-launch orphan reaping smaller and easier to reason about. Shortcut copy and dev server docs were updated to match the new behavior.

- **Summary**: Make Cmd+Shift+C context-aware
- **Description**: `Cmd+Shift+C` now opens the dev server preview console only when the selected card's preview browser is actually focused. The same shortcut still opens Git commit flow from Git Changes and now submits the commit while the sheet is open. This keeps preview/browser behavior and Git behavior in one shortcut without changing the copied cmux defaults.

- **Summary**: Route Cmd+Shift+R to preview refresh
- **Description**: When the dev server overlay is open, `Cmd+Shift+R` now refreshes the selected card's embedded preview browser instead of restarting the process. The menu command is enabled only when a real preview surface exists, the old restart notification path was removed, and the copied cmux `renameWorkspace` shortcut conflict is resolved through an app delegate override. This keeps the shortcut behavior consistent even while the browser surface is focused.

- **Summary**: Reduce hidden Ghostty workspace load
- **Description**: Hidden card terminals now drive real Ghostty occlusion so off-screen workspaces stop rendering while staying reopenable. Zenban also loads an embedded Ghostty performance override after user config to cap scrollback and image memory and disable blur for embedded surfaces. `CmuxHostStore` tracks hidden prewarm workspace residency and only reclaims runtime surfaces for long-hidden, prompt-idle shells that never showed agent activity, avoiding session loss for interactive or active workspaces.

- **Summary**: Keep Done card terminals manual
- **Description**: `Done` cards now close their cmux workspace as soon as they move into the completed column and no longer auto-open a terminal when selected. The detail pane shows an `Open Terminal` CTA instead, and that manual session is torn down again when the user leaves the card. Added focused lifecycle and launch regression coverage around the new manual-open flow.

- **Summary**: Enable bulk delete for Done cards
- **Description**: Extended the column-header bulk delete action to the `Done` column so every workflow lane now uses the same confirmation and batch-deletion flow. Updated the focused store regression tests to cover `Done` request creation and kept empty-column guards in place. This keeps the UI and destructive actions consistent across the board.

- **Summary**: Add bulk column card deletion
- **Description**: `To Do` and `In Review` column headers now expose a trash action that opens the shared delete confirmation sheet for a column snapshot. `BoardStore` now models delete confirmations for both single-card and bulk-column deletes, preserving workspace cleanup, overlay cleanup, and selection fallback while batching persistence. Added focused store regression tests for column snapshots, guarded columns, selection fallback, and cleanup hooks.

- **Summary**: Automate Claude-driven card column moves
- **Description**: `CmuxHostStore` now observes Claude lifecycle signals from the copied cmux notification and status streams. Completion notifications move the owning card into `In Review`, while Claude returning to active work moves it back to `To Do`. Added focused lifecycle regression tests around the completion and status classification rules.

- **Summary**: Add cmux localization and scripting resources
- **Description**: Added English-only `Localizable.xcstrings` and `InfoPlist.xcstrings` copied from cmux plus `cmux.sdef` for the app bundle. `Info.plist` now exposes Finder Services and the cmux AppleScript dictionary while intentionally leaving out cmux update-feed metadata and `http/https` URL handling.

- **Summary**: Embed copied cmux host stack
- **Description**: Replaced the stripped-down placeholder state with a copied cmux host stack under `zenban/CmuxImport` and `cmux-import/`. `CmuxHostStore` now maps cards 1:1 to cmux workspaces, launches the selected agent in the embedded Ghostty surface, and opens cmux browser panels for dev server previews. Desktop notifications now route back into Zenban card selection through the copied cmux notification store and app delegate wiring.

- **Summary**: Remove embedded runtime and preview host
- **Description**: Deleted the current embedded terminal, browser host, notification flow, and agent launch runtime from the app, project settings, and bundled resources. Card detail and ready-state dev server views now show placeholders while keeping worktrees, git tooling, and dev server logs intact. Updated the architecture and feature docs to match this temporary stripped-down state before a future replacement is copied in.
