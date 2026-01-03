# Repository Guidelines

## Project Structure & Module Organization
- `zenban/`: main macOS app target (SwiftUI app entry, Views, ViewModels, Models, Services, Storage, Terminal).
- `zenbanTests/`: unit tests using Swift Testing.
- `zenbanUITests/`: UI tests using XCTest.
- `LocalPackages/`: local Swift packages (GhosttyKit, GhosttySwift, SwiftTerm fork).
- `agent_docs/`: architecture and conventions references for larger changes.
- `aizen/`: related app and vendor code; treat as a separate module with its own docs.

## Build, Test, and Development Commands
- Requires macOS 15.6+ and Xcode 26.2 (Swift 5).
- `xcodebuild -project zenban.xcodeproj -scheme zenban -configuration Debug build`: build Debug.
- `xcodebuild -project zenban.xcodeproj -scheme zenban test`: run unit tests.
- `xcodebuild -project zenban.xcodeproj -scheme zenbanUITests test`: run UI tests.
- `xcodebuild -project zenban.xcodeproj -scheme zenban -configuration Release build`: build Release.
- `open zenban.xcodeproj`: open in Xcode for local development.

## Coding Style & Naming Conventions
- SwiftUI with default `MainActor` isolation; move heavy work off the main actor explicitly.
- State: prefer `@Observable` stores, inject with `.environment()`, read via `@Environment`, and bind with `@Bindable`.
- Naming: views use `*View.swift`, stores use `*Store.swift`, models are singular (e.g., `Board`, `Card`).
- Performance: keep view bodies lean, prefer `LazyVStack` for large lists, debounce and write storage atomically.

## Testing Guidelines
- Unit tests live in `zenbanTests/` using Swift Testing (`@Test`, `#expect(...)`).
- UI tests live in `zenbanUITests/` using XCTest (`XCTestCase`, `XCUIApplication`).
- Name tests `*Tests.swift` or `*UITests.swift` and add regression coverage near the feature.

## Commit & Pull Request Guidelines
- Commits are short, imperative, sentence case (e.g., "Add Ghostty", "Update ...", "Fix ..."). Use "Revert ..." for rollbacks.
- PRs should include a clear summary, test commands run, and screenshots for UI changes.

## Local Packages & Dependencies
- `LocalPackages/SwiftTerm` is a local fork with required fixes; do not swap back to upstream yet.
- Keep local package references stable unless updating dependencies intentionally.

## Swift Concurrency

The project uses Swift 6 concurrency features:
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` - all code defaults to MainActor isolation
- `SWIFT_APPROACHABLE_CONCURRENCY = YES` - enables approachable concurrency mode

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