# Ghostty Vendor Library + tmux Migration Plan

## Overview

This document outlines the migration from Zenban's current LocalPackages-based Ghostty integration (GhosttySwift, GhosttyKit) to a vendor library approach (libghostty.a + bridging header), following Aizen's implementation pattern. The migration also adds tmux session persistence support.

**Reference Project:** `/Users/berkaycit/Documents/GitHub/aizen`

---

## Current State (Zenban)

### Existing Files
- `LocalPackages/GhosttySwift/` - Swift wrapper package
- `LocalPackages/GhosttyKit/` - Binary target (xcframework)
- `LocalPackages/ghostty/` - Ghostty source and build artifacts
- `LocalPackages/SwiftTerm/` - Old terminal (unused)

### Key Files
- `zenban/Terminal/TerminalManager.swift` - Terminal orchestration
- `zenban/Terminal/TerminalContainerView.swift` - SwiftUI wrapper
- `zenban/Terminal/ZenbanTerminalView.swift` - Old SwiftTerm (unused)
- `zenban/Resources/ghostty/shell-integration/` - Shell scripts (exists)

### Available Build Artifacts (Already Built)
- `LocalPackages/ghostty/macos/build/ReleaseLocal/libghostty-fat.a`
- `LocalPackages/ghostty/include/ghostty.h`

---

## Target State

### Directory Structure
```
zenban/
  Vendor/
    libghostty/
      include/
        ghostty.h
        module.modulemap
      lib/
        libghostty.a
  zenban/
    Terminal/
      TerminalManager.swift (modified)
      TerminalContainerView.swift (modified)
      GhosttyTerminal/
        Ghostty.App.swift
        Ghostty.Surface.swift
        GhosttyTerminalView.swift
        GhosttyInputHandler.swift
        GhosttyIMEHandler.swift
        GhosttyRenderingSetup.swift
        TerminalScrollView.swift
        Ghostty.Input.swift
        Ghostty.Key.swift
        Ghostty.KeyEvent.swift
        Ghostty.Mods.swift
        Ghostty.MouseEvent.swift
        Ghostty.Action.swift
        GhosttyProgressState.swift
    Services/
      TmuxSessionManager.swift
    Utilities/
      GhosttyThemeParser.swift
    Resources/
      ghostty/
        themes/ (442 theme files)
        shell-integration/ (exists)
    ghostty-bridging-header.h
```

---

## Phase 1: Create Vendor Directory

### 1.1 Create Directory Structure
```bash
mkdir -p Vendor/libghostty/include
mkdir -p Vendor/libghostty/lib
```

### 1.2 Copy/Move Files

| Destination | Source |
|-------------|--------|
| `Vendor/libghostty/lib/libghostty.a` | `LocalPackages/ghostty/macos/build/ReleaseLocal/libghostty-fat.a` |
| `Vendor/libghostty/include/ghostty.h` | `LocalPackages/ghostty/include/ghostty.h` |
| `Vendor/libghostty/include/module.modulemap` | Copy from Aizen: `/Users/berkaycit/Documents/GitHub/aizen/Vendor/libghostty/include/module.modulemap` |

---

## Phase 2: Bridging Header and Build Settings

### 2.1 Create Bridging Header
**File:** `zenban/ghostty-bridging-header.h`
```c
#ifndef ghostty_bridging_header_h
#define ghostty_bridging_header_h
#import "../Vendor/libghostty/include/ghostty.h"
#endif
```

### 2.2 Xcode Build Settings
Add to `zenban.xcodeproj/project.pbxproj`:
```
HEADER_SEARCH_PATHS = "$(SRCROOT)/Vendor/libghostty/include"
LIBRARY_SEARCH_PATHS = "$(SRCROOT)/Vendor/libghostty/lib"
OTHER_LDFLAGS = -lghostty
SWIFT_OBJC_BRIDGING_HEADER = "$(SRCROOT)/zenban/ghostty-bridging-header.h"
```

### 2.3 Link Static Library
In Xcode: Build Phases > Link Binary With Libraries > Add `libghostty.a`

---

## Phase 3: Copy GhosttyTerminal Swift Files

**Source:** `/Users/berkaycit/Documents/GitHub/aizen/aizen/GhosttyTerminal/`
**Destination:** `/Users/berkaycit/Documents/GitHub/zenban/zenban/Terminal/GhosttyTerminal/`

### Files to Copy (13 files)
1. `Ghostty.App.swift` - Lifecycle and config manager
2. `Ghostty.Surface.swift` - C pointer wrapper
3. `GhosttyTerminalView.swift` - Main NSView (REQUIRES ADAPTATION)
4. `GhosttyInputHandler.swift` - Keyboard/mouse/scroll dispatcher
5. `GhosttyRenderingSetup.swift` - Metal layer setup
6. `TerminalScrollView.swift` - Native macOS scrollbar
7. `Ghostty.Input.swift` - Input utilities
8. `Ghostty.Key.swift` - Key mapping constants
9. `Ghostty.KeyEvent.swift` - Key event struct
10. `Ghostty.Mods.swift` - Modifier OptionSet
11. `Ghostty.MouseEvent.swift` - Mouse event types
12. `Ghostty.Action.swift` - Callback action types
13. `GhosttyProgressState.swift` - OSC 9;4 progress states

**NOT INCLUDED:**
- `GhosttyIMEHandler.swift` - IME support not needed

---

## Phase 3.5: Remove IME References

Since we're not copying `GhosttyIMEHandler.swift`, we need to remove IME references from copied files.

### 3.5.1 In GhosttyTerminalView.swift

**REMOVE these lines:**
```swift
// REMOVE handler property:
private var imeHandler: GhosttyIMEHandler!

// REMOVE from init:
self.imeHandler = GhosttyIMEHandler(view: self, surface: nil)

// REMOVE from setupSurface:
imeHandler.updateSurface(self.surface)
```

**KEEP NSTextInputClient but SIMPLIFY it (CRITICAL for text input!):**

NSTextInputClient is REQUIRED for `interpretKeyEvents` → `insertText` chain.
Without it, normal keyboard input (a, b, c, 1, 2, 3) will NOT work!

```swift
// MARK: - NSTextInputClient (Simplified - no IME)

extension GhosttyTerminalView: NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        guard let str = string as? String else { return }
        send(text: str)  // This is the critical part!
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        // No-op: IME not supported
    }

    func unmarkText() {
        // No-op: IME not supported
    }

    func selectedRange() -> NSRange {
        return NSRange(location: NSNotFound, length: 0)
    }

    func markedRange() -> NSRange {
        return NSRange(location: NSNotFound, length: 0)
    }

    func hasMarkedText() -> Bool {
        return false
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        return nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        return []
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        return .zero
    }

    func characterIndex(for point: NSPoint) -> Int {
        return 0
    }
}
```

### 3.5.2 In GhosttyInputHandler.swift

**REMOVE IME handler references:**
```swift
// REMOVE property:
private weak var imeHandler: GhosttyIMEHandler?

// REMOVE from init parameter:
init(view: GhosttyTerminalView, surface: Ghostty.Surface?, imeHandler: GhosttyIMEHandler)

// SIMPLIFY to:
init(view: GhosttyTerminalView, surface: Ghostty.Surface?)

// REMOVE all imeHandler usage in handleKeyDown
```

---

## Phase 4: Adapt GhosttyTerminalView for Zenban

The Aizen GhosttyTerminalView lacks Zenban-specific features. Add the following:

### 4.1 Add Properties
```swift
var cardID: UUID?
var boardID: UUID?
var cardTitle: String = ""
```

### 4.2 Add Callbacks
```swift
var onTaskCompleted: ((UUID, UUID) -> Void)?
var onAgentResumed: ((UUID, UUID) -> Void)?
```

### 4.3 Add State Machine
```swift
enum TerminalState {
    case shell           // Normal shell, agent not running
    case agentActive     // Agent is running
    case agentIdle       // Agent task completed, awaiting review
}

enum TerminalEvent {
    case agentLaunched     // TerminalManager notified agent launch
    case commandFinished   // OSC 133 D received
    case newMessageSent    // User input while idle
    case agentExited       // Ctrl+C pressed
}

private var state: TerminalState = .shell

private func transition(event: TerminalEvent) {
    let newState: TerminalState? = switch (state, event) {
    case (.shell, .agentLaunched): .agentActive
    case (.agentActive, .commandFinished): .agentIdle
    case (.agentActive, .agentExited): .shell
    case (.agentIdle, .newMessageSent): .agentActive
    case (.agentIdle, .agentExited): .shell
    default: nil
    }

    if let newState = newState, newState != state {
        let oldState = state
        state = newState
        handleStateChange(from: oldState, to: newState)
    }
}

private func handleStateChange(from oldState: TerminalState, to newState: TerminalState) {
    switch (oldState, newState) {
    case (.agentActive, .agentIdle):
        triggerTaskCompleted()
    case (.agentIdle, .agentActive):
        triggerAgentResumed()
    default:
        break
    }
}

private func triggerTaskCompleted() {
    guard hasBeenFocused else { return }
    guard let cardID = cardID, let boardID = boardID else { return }
    onTaskCompleted?(cardID, boardID)
}

private func triggerAgentResumed() {
    guard let cardID = cardID, let boardID = boardID else { return }
    onAgentResumed?(cardID, boardID)
}
```

### 4.4 Add Properties for Shell Ready Logic
```swift
/// Whether the shell is ready to receive input
public private(set) var isShellReady = false

/// Command to send when shell becomes ready
private var pendingCommand: String?

/// Whether terminal has been focused (prevents false positives on init)
private var hasBeenFocused = false
```

### 4.5 Add Methods
```swift
/// Send text to the terminal
func send(text: String) {
    // Check for Ctrl+C to detect agent exit
    if text.contains("\u{03}") {
        transition(event: .agentExited)
    }
    surface?.sendText(text)
}

/// Send text when the shell is ready
func sendWhenReady(_ command: String) {
    if isShellReady {
        send(text: command)
    } else {
        pendingCommand = command
    }
}

/// Called by TerminalManager when an agent is launched
func notifyAgentLaunched() {
    transition(event: .agentLaunched)
}

/// Called by TerminalManager when user sends new message to idle agent
func notifyNewMessageSent() {
    transition(event: .newMessageSent)
}

/// Request the surface to close
func terminate() {
    // Close surface
}

/// Called when shell integration reports ready
func handleShellReady() {
    guard !isShellReady else { return }
    isShellReady = true
    executePendingCommandIfNeeded()
}

/// Called when shell integration reports command finished (OSC 133 D)
func handleCommandFinished() {
    guard state == .agentActive else { return }
    transition(event: .commandFinished)
}

private func executePendingCommandIfNeeded() {
    guard let command = pendingCommand else { return }
    pendingCommand = nil
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
        self?.send(text: command)
    }
}
```

### 4.6 Add Shell Ready Fallback
In `commonInit()` or equivalent, add 2-second fallback:
```swift
// Fallback: Mark shell as ready after delay if shell integration doesn't respond
DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
    guard let self = self, !self.isShellReady else { return }
    self.handleShellReady()
}
```

### 4.7 OSC 133 D Handling in Ghostty.App.swift
In `action_cb` callback, add command finished detection:
```swift
runtimeConfig.action_cb = { appPtr, target, action in
    guard target.tag == GHOSTTY_TARGET_SURFACE,
          let surface = target.target.surface,
          let userdata = ghostty_surface_userdata(surface) else {
        return false
    }

    let view = Unmanaged<GhosttyTerminalView>.fromOpaque(userdata).takeUnretainedValue()

    // Notify shell ready on any action
    DispatchQueue.main.async {
        view.handleShellReady()
    }

    switch action.tag {
    case GHOSTTY_ACTION_COMMAND_FINISHED:
        DispatchQueue.main.async {
            view.handleCommandFinished()
        }
        return true
    default:
        return false
    }
}
```

---

## Phase 5: Add TmuxSessionManager

### 5.1 Copy File
**Source:** `/Users/berkaycit/Documents/GitHub/aizen/aizen/Services/Terminal/TmuxSessionManager.swift`
**Destination:** `/Users/berkaycit/Documents/GitHub/zenban/zenban/Services/TmuxSessionManager.swift`

### 5.2 Adapt for Zenban
Replace these values:
```swift
// Change session prefix
private let sessionPrefix = "zenban-"  // was "aizen-"

// Change config path
private let configPath = "~/.zenban/tmux.conf"  // was "~/.aizen/tmux.conf"

// Change logger subsystem
Logger(subsystem: "com.berkaycit.zenban", category: "TmuxSessionManager")
```

### 5.2.1 Verify TmuxSessionManager.shared Exists
TmuxSessionManager is an `actor` with `static let shared`. This is used by GhosttyRenderingSetup.swift:
```swift
TmuxSessionManager.shared.isTmuxAvailable()
TmuxSessionManager.shared.sessionExistsSync(paneId:)
TmuxSessionManager.shared.attachOrCreateCommand(paneId:workingDirectory:)
```
Ensure `static let shared = TmuxSessionManager()` exists in the actor.

### 5.3 GhosttyThemeParser Dependency
TmuxSessionManager uses `GhosttyThemeParser.loadTmuxModeStyle()`. Copy this file:
**Source:** `/Users/berkaycit/Documents/GitHub/aizen/aizen/Utilities/GhosttyThemeParser.swift`
**Destination:** `/Users/berkaycit/Documents/GitHub/zenban/zenban/Utilities/GhosttyThemeParser.swift`

**Note:** Remove `CodeEditSourceEditor` dependency and `toEditorTheme()` method. Only keep `loadTmuxModeStyle()` functionality.

### 5.4 Clipboard.swift Dependency
Ghostty.App.swift uses Clipboard utility. Copy this file:
**Source:** `/Users/berkaycit/Documents/GitHub/aizen/aizen/Utilities/Clipboard.swift`
**Destination:** `/Users/berkaycit/Documents/GitHub/zenban/zenban/Utilities/Clipboard.swift`

### 5.5 Create Utilities Directory
If `zenban/Utilities/` directory doesn't exist, create it:
```bash
mkdir -p zenban/Utilities
```

---

## Phase 6: Update TerminalManager

**File:** `zenban/Terminal/TerminalManager.swift`

### Changes Required

```swift
// REMOVE:
import GhosttySwift

// UPDATE isTerminalAvailable:
var isTerminalAvailable: Bool {
    Ghostty.App.shared?.readiness == .ready
}

// UPDATE init():
init() {
    // Initialize Ghostty.App singleton
    _ = Ghostty.App.shared
}

// UPDATE createTerminalView():
private func createTerminalView(
    cardID: UUID,
    boardID: UUID,
    cardTitle: String,
    workingDirectory: String?
) -> GhosttyTerminalView {
    let frame = NSRect(x: 0, y: 0, width: 600, height: 400)

    guard let ghosttyApp = Ghostty.App.shared?.app else {
        fatalError("Ghostty not ready")
    }

    let terminalView = GhosttyTerminalView(
        frame: frame,
        worktreePath: workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path,
        ghosttyApp: ghosttyApp,
        appWrapper: Ghostty.App.shared,
        paneId: cardID.uuidString,  // For tmux session persistence
        command: nil
    )

    // Set Zenban-specific properties
    terminalView.cardID = cardID
    terminalView.boardID = boardID
    terminalView.cardTitle = cardTitle

    // Wire up callbacks
    terminalView.onTaskCompleted = { cardID, boardID in
        NotificationService.shared.triggerTaskCompleted(cardID: cardID, boardID: boardID)
    }

    terminalView.onAgentResumed = { cardID, boardID in
        NotificationService.shared.triggerAgentResumed(cardID: cardID, boardID: boardID)
    }

    return terminalView
}
```

---

## Phase 6.5: Update TerminalContainerView

**File:** `zenban/Terminal/TerminalContainerView.swift`

### 6.5.1 Remove Old Import
```swift
// REMOVE:
import GhosttySwift
```

### 6.5.2 Update Coordinator
```swift
final class Coordinator {
    var loadTask: Task<Void, Never>?
    var terminalView: GhosttyTerminalView?
    var scrollView: TerminalScrollView?  // ADD THIS
}
```

### 6.5.3 Integrate TerminalScrollView (IMPORTANT)
In `loadTerminal()` function, wrap terminal in scroll view:

```swift
@MainActor
private func loadTerminal(into hostView: NSView, coordinator: Coordinator, backgroundColor: SwiftUI.Color) async {
    do {
        let terminal = try await terminalManager.terminalView(for: cardID, boardID: boardID, cardTitle: cardTitle)

        try Task.checkCancellation()

        terminal.layer?.backgroundColor = NSColor(backgroundColor).cgColor

        // CHANGE: Wrap terminal in TerminalScrollView
        let scrollView = TerminalScrollView(contentSize: hostView.bounds.size, surfaceView: terminal)
        scrollView.frame = hostView.bounds
        scrollView.autoresizingMask = [.width, .height]

        hostView.subviews.forEach { $0.removeFromSuperview() }
        hostView.addSubview(scrollView)  // Add scrollView instead of terminal directly

        coordinator.terminalView = terminal
        coordinator.scrollView = scrollView  // Track scroll view
    } catch is CancellationError {
        // Task was cancelled, ignore
    } catch {
        // Handle error silently
    }
}
```

### 6.5.4 Update updateNSView
```swift
func updateNSView(_ nsView: NSView, context: Context) {
    nsView.layer?.backgroundColor = NSColor(backgroundColor).cgColor
    if let scrollView = context.coordinator.scrollView {
        scrollView.frame = nsView.bounds
    }
    if let terminal = context.coordinator.terminalView {
        terminal.layer?.backgroundColor = NSColor(backgroundColor).cgColor
    }
}
```

---

## Phase 7: Copy Resources

### 7.1 Theme Files
**Source:** `/Users/berkaycit/Documents/GitHub/aizen/aizen/Resources/ghostty/themes/`
**Destination:** `/Users/berkaycit/Documents/GitHub/zenban/zenban/Resources/ghostty/themes/`
- 442 theme files

### 7.2 Shell Integration
Already exists at `zenban/Resources/ghostty/shell-integration/` - verify completeness.

---

## Phase 8: Adapt Ghostty.App.swift (CRITICAL)

**File:** `zenban/Terminal/GhosttyTerminal/Ghostty.App.swift`

### 8.1 Update Logger Subsystem
```swift
Logger(subsystem: "com.berkaycit.zenban", category: "GhosttyApp")
```

### 8.2 Handle AppStorage Settings (CRITICAL)

Aizen uses these @AppStorage keys that Zenban does NOT have:

**In Ghostty.App.swift:**
```swift
@AppStorage("terminalFontName") private var terminalFontName = "Menlo"
@AppStorage("terminalFontSize") private var terminalFontSize = 12.0
@AppStorage("terminalThemeName") private var terminalThemeName = "Aizen Dark"
@AppStorage("terminalThemeNameLight") private var terminalThemeNameLight = "Aizen Light"
@AppStorage("terminalUsePerAppearanceTheme") private var usePerAppearanceTheme = false
@AppStorage("appearanceMode") private var appearanceMode = "system"
```

**In GhosttyRenderingSetup.swift:**
```swift
@AppStorage("terminalSessionPersistence") private var sessionPersistence = false
```

**Option A (Recommended):** Replace with hardcoded defaults for Zenban:

In Ghostty.App.swift:
```swift
private let terminalFontName = "Menlo"
private let terminalFontSize = 12.0
private let terminalThemeName = "Dracula"  // Or preferred theme
private let usePerAppearanceTheme = false
```

In GhosttyRenderingSetup.swift:
```swift
// Enable tmux by default (or set to false to disable)
private let sessionPersistence = true
```

**Option B:** Add Settings UI to Zenban (more work, future enhancement)

### 8.3 Update effectiveThemeName
If using hardcoded values, simplify:
```swift
private var effectiveThemeName: String {
    return terminalThemeName
}
```

### 8.4 Singleton Pattern Change
Aizen uses `Ghostty.App` as a class. Update TerminalManager references:
```swift
// OLD (current Zenban):
GhosttyApp.shared.isReady
GhosttyApp.shared.app

// NEW:
Ghostty.App.shared?.readiness == .ready
Ghostty.App.shared?.app
```

### 8.5 Add Static Singleton (CRITICAL)

Aizen uses `@EnvironmentObject` pattern, but Zenban uses singleton pattern.
Add static shared property to `Ghostty.App` class:

```swift
extension Ghostty {
    @MainActor
    class App: ObservableObject {
        // ADD THIS - Zenban needs singleton pattern
        private static var _shared: App?

        static var shared: App? {
            if _shared == nil {
                _shared = App()
            }
            return _shared?.readiness == .ready ? _shared : nil
        }

        // ... rest of existing class code
    }
}
```

This allows TerminalManager to use:
```swift
Ghostty.App.shared?.app  // Get ghostty_app_t pointer
Ghostty.App.shared?.readiness == .ready  // Check availability
```

---

## Phase 9: Delete Old Files

### Directories to Delete
- `/Users/berkaycit/Documents/GitHub/zenban/LocalPackages/GhosttySwift/`
- `/Users/berkaycit/Documents/GitHub/zenban/LocalPackages/GhosttyKit/`
- `/Users/berkaycit/Documents/GitHub/zenban/LocalPackages/ghostty/`
- `/Users/berkaycit/Documents/GitHub/zenban/LocalPackages/SwiftTerm/`

### Files to Delete
- `/Users/berkaycit/Documents/GitHub/zenban/zenban/Terminal/ZenbanTerminalView.swift`
- `/Users/berkaycit/Documents/GitHub/zenban/zenban/Terminal/TerminalConfiguration.swift`

### Xcode References to Remove
- GhosttySwift package dependency
- GhosttyKit package dependency
- SwiftTerm package dependency

---

## Phase 10: Update Xcode Project

### 10.1 Add New Files to Project
- `Vendor/` folder reference
- All `GhosttyTerminal/*.swift` files (14 files)
- `Services/TmuxSessionManager.swift`
- `Utilities/GhosttyThemeParser.swift`
- `ghostty-bridging-header.h`

### 10.2 Update Build Settings
Apply settings from Phase 2.2

### 10.3 Add Resources
Ensure `Resources/ghostty/themes/` is in Copy Bundle Resources build phase

### 10.4 Remove Old References
Remove LocalPackages package dependencies and file references

---

## Implementation Checklist

```
[ ] 1. Create git branch for backup
[ ] 2. Create Vendor/libghostty/ directory structure
[ ] 3. Move libghostty-fat.a to Vendor/libghostty/lib/libghostty.a
[ ] 4. Copy ghostty.h to Vendor/libghostty/include/
[ ] 5. Copy module.modulemap from Aizen
[ ] 6. Create ghostty-bridging-header.h
[ ] 7. Update Xcode build settings
[ ] 8. Copy 13 GhosttyTerminal Swift files from Aizen (excluding GhosttyIMEHandler.swift)
[ ] 9. Remove IME references from GhosttyTerminalView.swift and GhosttyInputHandler.swift
[ ] 10. Adapt GhosttyTerminalView (add cardID, state machine, callbacks)
[ ] 11. Copy and adapt TmuxSessionManager
[ ] 12. Create Utilities/ directory if needed
[ ] 13. Copy and simplify GhosttyThemeParser
[ ] 14. Copy Clipboard.swift
[ ] 15. Copy theme files (442 files)
[ ] 16. Update TerminalManager.swift
[ ] 17. Update TerminalContainerView.swift (remove import, add TerminalScrollView integration)
[ ] 18. Adapt Ghostty.App.swift (bundle ID, singleton, hardcoded settings)
[ ] 19. Delete old LocalPackages directories (GhosttySwift, GhosttyKit, ghostty, SwiftTerm)
[ ] 20. Delete unused terminal files (ZenbanTerminalView.swift, TerminalConfiguration.swift)
[ ] 21. Update Xcode project (add new files, remove old references)
[ ] 22. Build and test
```

---

## Critical Files Reference

| File | Action | Notes |
|------|--------|-------|
| `zenban/Terminal/TerminalManager.swift` | Modify | Remove GhosttySwift import, update API calls |
| `zenban/Terminal/TerminalContainerView.swift` | Modify | Remove import GhosttySwift |
| `zenban/Terminal/GhosttyTerminal/GhosttyTerminalView.swift` | Copy + Adapt | Add cardID, boardID, state machine, callbacks |
| `zenban/Terminal/GhosttyTerminal/Ghostty.App.swift` | Copy + Adapt | Change bundle ID to com.berkaycit.zenban |
| `zenban/Services/TmuxSessionManager.swift` | Copy + Adapt | Change prefix to "zenban-", path to ~/.zenban/ |
| `zenban/Utilities/GhosttyThemeParser.swift` | Copy + Simplify | Remove CodeEditSourceEditor dependency |
| `zenban/Utilities/Clipboard.swift` | Copy | Required by Ghostty.App.swift |
| `zenban.xcodeproj/project.pbxproj` | Modify | Build settings, file references |
| `zenban/ghostty-bridging-header.h` | Create | New file |

---

## Aizen Source Files Reference

All source files to copy from Aizen are located at:
`/Users/berkaycit/Documents/GitHub/aizen/aizen/`

- `GhosttyTerminal/*.swift` (14 files)
- `Services/Terminal/TmuxSessionManager.swift`
- `Utilities/GhosttyThemeParser.swift`
- `Utilities/Clipboard.swift`
- `Resources/ghostty/themes/*` (442 files)
- `Vendor/libghostty/include/module.modulemap`

---

## Known Limitations & Future Enhancements

### Not Included in This Migration

| Feature | Reason | Future Work |
|---------|--------|-------------|
| **IME support** | Not needed for Zenban | Can add later if needed |
| **TerminalSessionManager** | Zenban uses simpler TerminalManager pattern | Not needed |
| **TerminalViewWrapper** | Zenban's TerminalContainerView is sufficient | Keep current |
| **Per-appearance themes** | No Settings UI in Zenban | Add Settings UI first |
| **Font/size customization** | Hardcoded defaults used | Add Settings UI later |

### What Works After Migration

- Terminal rendering (Metal)
- Keyboard/mouse input
- Native macOS scrollbar (TerminalScrollView)
- tmux session persistence
- Agent state machine (task completed/resumed)
- Shell integration (OSC 133)
- Theme support (single theme)
