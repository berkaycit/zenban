# CLAUDE.md

## Build Commands

```bash
# Build the app
xcodebuild -project zenban.xcodeproj -scheme zenban -configuration Debug build

# Run unit tests
xcodebuild -project zenban.xcodeproj -scheme zenban test

# Run UI tests
xcodebuild -project zenban.xcodeproj -scheme zenbanUITests test

# Build for release
xcodebuild -project zenban.xcodeproj -scheme zenban -configuration Release build
```

## Architecture

- **zenban/**: Main app target containing SwiftUI views, app entry point, board UI, services, and the embedded cmux host adapter
- **zenban/CmuxImport/**: copied cmux workspace, browser, notification, AppleScript, and Ghostty host code
- **zenban/CmuxHostStore.swift**: Zenban-only adapter that lazily maps cards 1:1 to cmux workspaces and git-backed worktrees
- **cmux-import/**: copied `clone/cmux` inputs such as CLI, Ghostty runtime, bonsplit, and packaged assets
- **zenbanTests/**: Unit tests using Swift Testing framework (`import Testing`)
- **zenbanUITests/**: UI tests using XCTest framework

## Swift Concurrency

The project uses Swift 6 concurrency features:
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` - all code defaults to MainActor isolation
- `SWIFT_APPROACHABLE_CONCURRENCY = YES` - enables approachable concurrency mode

## Bundle Identifier

`com.berkaycit.zenban`

## Vendor Libraries

- **Vendor/libgit2**: Pre-built libgit2 C library for git operations.
- **cmux-import/GhosttyKit.xcframework**: Ghostty runtime copied from `clone/cmux`.
- **cmux-import/bonsplit**: Local cmux-derived package for split panes and workspace chrome.
- **cmux-import/ghostty**, **cmux-import/shell-integration**, **cmux-import/terminfo-overlay**, **cmux-import/bin**, **ghostty/zig-out/share**: cmux-sourced Ghostty assets and helpers bundled by the `Copy Ghostty Resources` build phase.
- **zenban/CmuxImport**: copied cmux host-side workspace stack, browser, notification store, local socket controller, and AppleScript support.
- **zenban/CmuxHostStore.swift**: card-scoped workspace registry and agent/browser bridge layered on top of copied cmux code.

## When to Read Agent Docs

| Task | Read |
|------|------|
| Project structure, components, data flow | agent_docs/architecture.md |
| Code patterns, naming, performance | agent_docs/conventions.md |
| App features, shortcuts, storage | agent_docs/features.md |
| Recent changes history | agent_docs/memory-bank.md |

## Rules

- Efficiency is critical. This will be a continuously running program, so minimize CPU and memory usage as much as possible.
- ALWAYS read and understand relevant files before proposing edits. Do not speculate about code you have not inspected
- If critical info is needed and you suspect your knowledge may be outdated, fetch the latest docs via Context7 MCP first
- Before writing new code, check for existing related methods/classes and reuse or modify them instead of duplicating functionality
- Avoid generic names; choose flexible, extensible naming for classes
- Prefer clear function/variable names over inline comments
- If a critical point is unclear, ask clarifying questions with options before implementing the plan
- Only create an abstraction if it’s actually needed
- Only make changes that are directly requested. Keep solutions simple and focused
- Avoid helper functions when a simple inline expression would suffice
- Ensure your changes are easy to verify
- After each change, do NOT run npm run build
- If doing any Firebase related work, use the Firebase MCP
- Don't use emojis

## Gotchas
- **Keyboard event monitor**: `zenbanApp.swift` has a global NSEvent monitor for board/card navigation shortcuts. When adding overlays/dialogs with their own keyboard handling, add a skip condition to the monitor. Terminal behavior is split between copied `zenban/CmuxImport` code and the Zenban-only `CmuxHostStore` bridge, so do not assume every cmux app-shell feature exists here.
