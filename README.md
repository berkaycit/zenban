# Zenban

A macOS kanban board application built with SwiftUI.

## Requirements

- macOS 15.6+
- Xcode 26.2+
- Swift 5

## Build

Open the project in Xcode:

```bash
open zenban.xcodeproj
```

Or build and test from the command line:

```bash
xcodebuild -project zenban.xcodeproj -scheme zenban -configuration Debug build
xcodebuild -project zenban.xcodeproj -scheme zenban test
```

## Current App State

- Git-backed boards still create one worktree per card.
- Git Changes and File Browser overlays are still available.
- Dev server setup, process management, and logs are still available.
- The card detail pane embeds a cmux-derived Ghostty workspace for the selected card.
- The ready dev server state opens an embedded cmux browser surface instead of an external browser.
- Desktop notifications and Finder Services come from the copied cmux host stack.

## Optional Tools

Zenban can help install these optional tools from Settings:

- Homebrew
- GitHub CLI
- Claude Code CLI

## Bundle Identifier

`com.berkaycit.zenban`
