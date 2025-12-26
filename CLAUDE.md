# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Zenban is a macOS application built with SwiftUI, targeting macOS 15.6+. The project uses Xcode 26.2 and Swift 5.0.

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

- **zenban/**: Main app target containing SwiftUI views and app entry point
  - `zenbanApp.swift`: App entry point using `@main` attribute
  - `ContentView.swift`: Root view of the application
- **zenbanTests/**: Unit tests using Swift Testing framework (`import Testing`)
- **zenbanUITests/**: UI tests using XCTest framework

## Swift Concurrency

The project uses Swift 6 concurrency features:
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` - all code defaults to MainActor isolation
- `SWIFT_APPROACHABLE_CONCURRENCY = YES` - enables approachable concurrency mode

## Bundle Identifier

`com.berkaycit.zenban`

## Local Packages

- **LocalPackages/SwiftTerm**: Local fork of SwiftTerm with a bug fix. The original `calculateMouseHit` in `MacTerminalView.swift:898` added `yDisp` to the row, but selection functions (`startSelection`, `dragExtend`, etc.) also add `yDisp`, causing double-addition. This resulted in mouse selection offset after scrolling. Fix: Removed `+ terminal.buffer.yDisp` from `calculateMouseHit`. Do not switch back to the remote SwiftTerm package until this fix is merged upstream.

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
- Don’t use emojis