<p align="center">
  <img src="zenban-icon.jpeg" width="160" alt="Zenban" />
</p>

<h1 align="center">Zenban</h1>

<p align="center">A kanban board for macOS where every card is a real workspace.</p>

Drop a card into **To Do**, pick an agent, and Claude opens up inside the card's own git worktree. Keep working. When the agent finishes the job, the card slides over to **In Review** on its own. Dev server, browser preview, file browser, git diff, all already living inside the card.

## What you get

- Three column board with drag and drop, pinning, and per board defaults.
- A dedicated git worktree per card on branch `card/<uuid>`, created on demand, cleaned up on delete.
- An embedded Ghostty terminal in every card, backed by a persistent Zellij session.
- Per board dev server with package manager detection, live logs, and a built in browser preview.
- Desktop notifications that move cards between columns when your agent reports back.
- Finder service: "New Zenban Workspace Here".

## Shortcuts

| Keys | Action |
|---|---|
| `Cmd+Shift+A` | New card |
| `Cmd+Shift+E` | Delete card |
| `Cmd+Shift+S` | Toggle dev server |
| `Cmd+Shift+C` | Commit in Git Changes, DevTools in preview |
| `Cmd+Shift+R` | Refresh preview |
| `Cmd+Shift+T` | Fullscreen the focused terminal |

## Build

```bash
open zenban.xcodeproj
```

Or from the shell:

```bash
xcodebuild -project zenban.xcodeproj -scheme zenban -configuration Debug build
xcodebuild -project zenban.xcodeproj -scheme zenban test
```

Needs macOS 15.6 and Xcode 26.2.

## Bundle

`com.berkaycit.zenban`
