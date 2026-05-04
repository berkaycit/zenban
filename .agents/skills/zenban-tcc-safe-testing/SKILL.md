---
name: zenban-tcc-safe-testing
description: Run and validate Zenban macOS tests without triggering macOS TCC permission prompts. Use when testing Zenban notifications, terminal-agent launch, hook delivery, app-hosted xcodebuild suites, or Computer-driven app verification that could otherwise touch Desktop, Documents, Downloads, Photos, Music, or stale app state.
---

# Zenban TCC-Safe Testing

## Core Rule

Run every Zenban app-hosted test or Computer verification from cache-backed test state:

- Set `CMUX_UI_TEST_MODE=1`.
- Set `CMUX_UI_TEST_BOARD_STORAGE_DIRECTORY` to a path under `~/Library/Caches/Zenban/...`.
- Use card workdirs under `~/Library/Caches/Zenban/...`.
- Clear stale `NSOSPLastRootDirectory` before launching the app.
- Do not use Desktop, Documents, Downloads, Photos, Music, or other TCC-protected paths.

If a TCC prompt appears, stop the run and fix the launch state. Do not keep testing by clicking through permission prompts.

## App-Hosted xcodebuild Tests

Use the wrapper script for any `xcodebuild test` command that can launch the Zenban app host:

```bash
ZENBAN_TCC_TEST_NAME=notification-duplicate \
.agents/skills/zenban-tcc-safe-testing/scripts/run-xcodebuild-tcc-safe.sh \
  -project zenban.xcodeproj \
  -scheme zenban \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -only-testing:zenbanTests/TerminalNotificationStoreDuplicateTests \
  test
```

The wrapper creates a fresh cache board directory, deletes stale `NSOSPLastRootDirectory`, exports the required env, and then execs `xcodebuild`.

Use a specific `ZENBAN_TCC_TEST_NAME` per task so logs and leftover cache paths are easy to inspect.

## Computer App Verification

When using Computer to inspect the running app, launch Zenban directly with env. Do not use `open Zenban.app`, because `open` does not reliably preserve the required test env.

```bash
TEST_BOARD_DIR="$HOME/Library/Caches/Zenban/computer-notification-test"
rm -rf "$TEST_BOARD_DIR"
mkdir -p "$TEST_BOARD_DIR"
defaults delete com.berkaycit.zenban NSOSPLastRootDirectory 2>/dev/null || true

DERIVED_DATA="$(mktemp -d /tmp/zenban-derived.XXXXXX)"
xcodebuild -project zenban.xcodeproj \
  -scheme zenban \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA" \
  build

CMUX_UI_TEST_MODE=1 \
CMUX_UI_TEST_BOARD_STORAGE_DIRECTORY="$TEST_BOARD_DIR" \
"$DERIVED_DATA/Build/Products/Debug/Zenban.app/Contents/MacOS/Zenban"
```

After launch, use Computer against that process. For notification or hook tests, verify the launched terminal/agent sees cache paths:

```bash
printf 'CMUX_AGENT_LAUNCH_CWD=%s\nPWD=%s\n' "$CMUX_AGENT_LAUNCH_CWD" "$PWD"
```

Both values should point under `~/Library/Caches/Zenban/...` for unattended verification.

## TCC Prompt Recovery

If macOS asks Zenban for access to Desktop, Documents, Downloads, Photos, Music, or media libraries:

1. Quit the current Zenban test app.
2. Check stale state:
   ```bash
   defaults read com.berkaycit.zenban NSOSPLastRootDirectory 2>/dev/null || true
   ```
3. Clear it:
   ```bash
   defaults delete com.berkaycit.zenban NSOSPLastRootDirectory 2>/dev/null || true
   ```
4. Rerun with `CMUX_UI_TEST_MODE=1` and `CMUX_UI_TEST_BOARD_STORAGE_DIRECTORY` under `~/Library/Caches/Zenban/...`.

If the prompt still appears, inspect the board/card workdir selection before debugging product behavior.

## Reporting

When reporting a Zenban terminal, hook, notification, or Computer verification result, include:

- The exact test command or launch command.
- The cache board directory used.
- Whether any TCC prompt appeared.
- For agent/hook tests, the observed `CMUX_AGENT_LAUNCH_CWD` and `PWD`.

Treat a run that produced TCC prompts as invalid for behavior verification.
