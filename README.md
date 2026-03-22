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

## Tool Availability

- Zenban bundles its terminal runtime internally, including `cmux`, `open`, and the workspace session tooling it needs.
- System `git` is still used for git history, commit diffs, and shell git probes.
- `Claude Code CLI` remains optional and is only used for AI-assisted commit message generation.
- Pull requests are created through the GitHub API with a token such as `GITHUB_TOKEN` or `GITHUB_PAT`.

## Sentry Symbols

Zenban uploads debug symbols to the `zenban` Sentry project with:

```bash
./scripts/upload-sentry-dsyms.sh
```

Before running it, make sure:

- `sentry-cli` is installed and available in `PATH`
- `SENTRY_AUTH_TOKEN` is set in your current shell or CI environment
- you have already built the app binary you want to symbolicate

Example:

```bash
export SENTRY_AUTH_TOKEN='...'
xcodebuild -project zenban.xcodeproj -scheme zenban -configuration Debug -derivedDataPath build/codex-derived build
./scripts/upload-sentry-dsyms.sh
```

Notes:

- `export SENTRY_AUTH_TOKEN=...` only lasts for the current terminal session unless you store it elsewhere
- rerun the upload script after new app/helper builds, release builds, or archives that produce new debug symbols
- if nothing changed, the script will report that all files are already on the server

## Bundle Identifier

`com.berkaycit.zenban`
