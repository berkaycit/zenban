---
name: zenban-ui-xctest
description: Write and debug Zenban macOS UI tests that interact with card-driven Ghostty workspaces, unread notification outlines, and screenshot-heavy failure diagnosis. Use when adding or fixing XCTest coverage for Zenban card creation, card selection, embedded terminal input, notification-driven column moves, screenshot attachments, or Peekaboo-based UI inspection.
---

# Zenban UI XCTest

## Overview

Follow the real Zenban card workflow, not the terminal chrome workflow. Prefer deterministic app hooks plus step-by-step screenshots so UI failures are visible before reaching for manual diagnosis.

## Core Workflow

1. Read the existing Zenban UI path before editing tests.
   Focus on `/Users/berkaycit/Documents/GitHub/utility/zenban/zenbanUITests/zenbanUITests.swift`, `/Users/berkaycit/Documents/GitHub/utility/zenban/zenban/ViewModels/BoardStore.swift`, `/Users/berkaycit/Documents/GitHub/utility/zenban/zenban/ZenbanRootView.swift`, `/Users/berkaycit/Documents/GitHub/utility/zenban/zenban/Views/Card/CardView.swift`, and `/Users/berkaycit/Documents/GitHub/utility/zenban/zenban/Views/Card/CardDetailView.swift`.
2. Create cards the same way the app does.
   Use `Cmd+Shift+A` for new cards. Zenban already auto-selects the new card and opens its detail pane terminal path through `selectedCardID` and `cmuxHost.syncSelection(...)`.
3. Re-select the card explicitly after creation when the test is about terminal input.
   Click `BoardCard.<title>` so the detail pane and cmux selection are definitely aligned before typing.
4. Type into the selected card's embedded terminal, not terminal chrome.
   Try the terminal accessibility field first if it exists.
   If accessibility is flaky, click a fallback coordinate in the lower detail pane where the selected card terminal lives.
   Do not click the `terminal` button/tab when the test intent is "type into the selected card's terminal".
5. Add a screenshot after every important UI step.
   Wrap major actions and assertions in a helper such as `performStep(...)` and attach a `keepAlways` screenshot.
   Use stable names like `01-board-loaded`, `02-create-card`, `03-send-prompt`, `04-notification-arrived`.
6. Verify the product behavior, not just the mechanics.
   For unread outline flows, wait for the card to move into `In Review` and then verify the orange outline from a screenshot or card crop.
7. Use deterministic in-app hooks when external automation is brittle.
   For notification-driven tests, prefer existing `DEBUG` UI-test hooks in `/Users/berkaycit/Documents/GitHub/utility/zenban/zenban/CmuxImport/AppDelegate.swift` over ad hoc socket or shell orchestration.

## Known Traps

- Clicking the `terminal` button can send input to the wrong place or effectively test a different terminal path than the card's own embedded workspace.
- Assuming the Ghostty accessibility node always appears as `text entry area` is unsafe. XCTest may fail to expose it on some runs.
- Skipping screenshots makes UI failures look like logic bugs when they are often focus or hit-target bugs.
- Verifying only "test passed" is not enough for UI flows. Confirm the screenshots show the intended card, pane, and outline state.

## Rules To Reuse

- Keep screenshot capture built into the test helper layer, not added ad hoc after a failure.
- Prefer card identifiers such as `BoardCard.<title>` over vague text-only targeting.
- Keep fallback clicks in the detail pane's terminal region, not in the top workspace chrome.
- When a UI test depends on unread notification state, reuse existing notification plumbing instead of inventing a second unread mechanism.
- When a failure looks visual or focus-related, inspect the screenshot attachments first and only then escalate to Peekaboo.

## Peekaboo Triage

Use Peekaboo when XCTest screenshots show the wrong region, the terminal is not focusable, or a click appears to hit the wrong target.

Useful commands:

```bash
peekaboo image --mode window --path /tmp/zenban-window.png
peekaboo see --app Zenban --json
```

Use Peekaboo to answer these questions:

- Which element actually received focus?
- Did the click land in the card detail terminal region or in terminal chrome?
- Did the expected card remain selected after creation?
- Did the outline render around the correct card?

## Done Criteria

- Keep a screenshot attachment for every major UI step.
- Ensure card creation, selection, and typing happen on the intended card path.
- Ensure unread outline tests show the real card moving to `In Review`.
- Leave the test in a form where the next UI failure is diagnosable from XCTest artifacts before any manual reproduction.
