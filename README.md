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
- The card detail terminal area is currently a placeholder.
- The embedded web preview is currently a placeholder that shows the detected URL.

## Optional Tools

Zenban can help install these optional tools from Settings:

- Homebrew
- GitHub CLI
- Claude Code CLI

## Bundle Identifier

`com.berkaycit.zenban`
