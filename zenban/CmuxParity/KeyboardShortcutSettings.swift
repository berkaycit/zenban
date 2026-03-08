import AppKit
import SwiftUI

/// Stores customizable keyboard shortcuts (definitions + persistence).
enum KeyboardShortcutSettings {
    enum Action: String, CaseIterable, Identifiable {
        // Titlebar / primary UI
        case toggleSidebar
        case newTab
        case newWindow
        case closeWindow
        case openFolder
        case sendFeedback
        case showNotifications
        case jumpToUnread
        case triggerFlash

        // Navigation
        case nextSurface
        case prevSurface
        case nextSidebarTab
        case prevSidebarTab
        case renameTab
        case renameWorkspace
        case closeWorkspace
        case newSurface
        case toggleTerminalCopyMode

        // Panes / splits
        case focusLeft
        case focusRight
        case focusUp
        case focusDown
        case splitRight
        case splitDown
        case toggleSplitZoom

        // Panels
        case toggleBrowserDeveloperTools
        case showBrowserJavaScriptConsole

        var id: String { rawValue }

        var label: String {
            switch self {
            case .toggleSidebar: return String(localized: "shortcut.toggleSidebar.label", defaultValue: "Toggle Sidebar")
            case .newTab: return String(localized: "shortcut.newWorkspace.label", defaultValue: "New Workspace")
            case .newWindow: return String(localized: "shortcut.newWindow.label", defaultValue: "New Window")
            case .closeWindow: return String(localized: "shortcut.closeWindow.label", defaultValue: "Close Window")
            case .openFolder: return String(localized: "shortcut.openFolder.label", defaultValue: "Open Folder")
            case .sendFeedback: return String(localized: "sidebar.help.sendFeedback", defaultValue: "Send Feedback")
            case .showNotifications: return String(localized: "shortcut.showNotifications.label", defaultValue: "Show Notifications")
            case .jumpToUnread: return String(localized: "shortcut.jumpToUnread.label", defaultValue: "Jump to Latest Unread")
            case .triggerFlash: return String(localized: "shortcut.flashFocusedPanel.label", defaultValue: "Flash Focused Panel")
            case .nextSurface: return String(localized: "shortcut.nextSurface.label", defaultValue: "Next Surface")
            case .prevSurface: return String(localized: "shortcut.previousSurface.label", defaultValue: "Previous Surface")
            case .nextSidebarTab: return String(localized: "shortcut.nextWorkspace.label", defaultValue: "Next Workspace")
            case .prevSidebarTab: return String(localized: "shortcut.previousWorkspace.label", defaultValue: "Previous Workspace")
            case .renameTab: return String(localized: "shortcut.renameTab.label", defaultValue: "Rename Tab")
            case .renameWorkspace: return String(localized: "shortcut.renameWorkspace.label", defaultValue: "Rename Workspace")
            case .closeWorkspace: return String(localized: "shortcut.closeWorkspace.label", defaultValue: "Close Workspace")
            case .newSurface: return String(localized: "shortcut.newSurface.label", defaultValue: "New Surface")
            case .toggleTerminalCopyMode: return String(localized: "shortcut.toggleTerminalCopyMode.label", defaultValue: "Toggle Terminal Copy Mode")
            case .focusLeft: return String(localized: "shortcut.focusPaneLeft.label", defaultValue: "Focus Pane Left")
            case .focusRight: return String(localized: "shortcut.focusPaneRight.label", defaultValue: "Focus Pane Right")
            case .focusUp: return String(localized: "shortcut.focusPaneUp.label", defaultValue: "Focus Pane Up")
            case .focusDown: return String(localized: "shortcut.focusPaneDown.label", defaultValue: "Focus Pane Down")
            case .splitRight: return String(localized: "shortcut.splitRight.label", defaultValue: "Split Right")
            case .splitDown: return String(localized: "shortcut.splitDown.label", defaultValue: "Split Down")
            case .toggleSplitZoom: return String(localized: "shortcut.togglePaneZoom.label", defaultValue: "Toggle Pane Zoom")
            case .toggleBrowserDeveloperTools: return String(localized: "shortcut.toggleBrowserDevTools.label", defaultValue: "Toggle Browser Developer Tools")
            case .showBrowserJavaScriptConsole: return String(localized: "shortcut.showBrowserJSConsole.label", defaultValue: "Show Browser JavaScript Console")
            }
        }

        var defaultsKey: String {
            switch self {
            case .toggleSidebar: return "shortcut.toggleSidebar"
            case .newTab: return "shortcut.newTab"
            case .newWindow: return "shortcut.newWindow"
            case .closeWindow: return "shortcut.closeWindow"
            case .openFolder: return "shortcut.openFolder"
            case .sendFeedback: return "shortcut.sendFeedback"
            case .showNotifications: return "shortcut.showNotifications"
            case .jumpToUnread: return "shortcut.jumpToUnread"
            case .triggerFlash: return "shortcut.triggerFlash"
            case .nextSidebarTab: return "shortcut.nextSidebarTab"
            case .prevSidebarTab: return "shortcut.prevSidebarTab"
            case .renameTab: return "shortcut.renameTab"
            case .renameWorkspace: return "shortcut.renameWorkspace"
            case .closeWorkspace: return "shortcut.closeWorkspace"
            case .focusLeft: return "shortcut.focusLeft"
            case .focusRight: return "shortcut.focusRight"
            case .focusUp: return "shortcut.focusUp"
            case .focusDown: return "shortcut.focusDown"
            case .splitRight: return "shortcut.splitRight"
            case .splitDown: return "shortcut.splitDown"
            case .toggleSplitZoom: return "shortcut.toggleSplitZoom"
            case .nextSurface: return "shortcut.nextSurface"
            case .prevSurface: return "shortcut.prevSurface"
            case .newSurface: return "shortcut.newSurface"
            case .toggleTerminalCopyMode: return "shortcut.toggleTerminalCopyMode"
            case .toggleBrowserDeveloperTools: return "shortcut.toggleBrowserDeveloperTools"
            case .showBrowserJavaScriptConsole: return "shortcut.showBrowserJavaScriptConsole"
            }
        }

        var defaultShortcut: StoredShortcut {
            switch self {
            case .toggleSidebar:
                return StoredShortcut(key: "b", command: true, shift: false, option: false, control: false)
            case .newTab:
                return StoredShortcut(key: "n", command: true, shift: false, option: false, control: false)
            case .newWindow:
                return StoredShortcut(key: "n", command: true, shift: true, option: false, control: false)
            case .closeWindow:
                return StoredShortcut(key: "w", command: true, shift: false, option: false, control: true)
            case .openFolder:
                return StoredShortcut(key: "o", command: true, shift: false, option: false, control: false)
            case .sendFeedback:
                return StoredShortcut(key: "f", command: true, shift: false, option: true, control: false)
            case .showNotifications:
                return StoredShortcut(key: "i", command: true, shift: false, option: false, control: false)
            case .jumpToUnread:
                return StoredShortcut(key: "u", command: true, shift: true, option: false, control: false)
            case .triggerFlash:
                return StoredShortcut(key: "h", command: true, shift: true, option: false, control: false)
            case .nextSidebarTab:
                return StoredShortcut(key: "]", command: true, shift: false, option: false, control: true)
            case .prevSidebarTab:
                return StoredShortcut(key: "[", command: true, shift: false, option: false, control: true)
            case .renameTab:
                return StoredShortcut(key: "r", command: true, shift: false, option: false, control: false)
            case .renameWorkspace:
                return StoredShortcut(key: "r", command: true, shift: true, option: false, control: false)
            case .closeWorkspace:
                return StoredShortcut(key: "w", command: true, shift: true, option: false, control: false)
            case .focusLeft:
                return StoredShortcut(key: "←", command: true, shift: false, option: true, control: false)
            case .focusRight:
                return StoredShortcut(key: "→", command: true, shift: false, option: true, control: false)
            case .focusUp:
                return StoredShortcut(key: "↑", command: true, shift: false, option: true, control: false)
            case .focusDown:
                return StoredShortcut(key: "↓", command: true, shift: false, option: true, control: false)
            case .splitRight:
                return StoredShortcut(key: "d", command: true, shift: false, option: false, control: false)
            case .splitDown:
                return StoredShortcut(key: "d", command: true, shift: true, option: false, control: false)
            case .toggleSplitZoom:
                return StoredShortcut(key: "\r", command: true, shift: true, option: false, control: false)
            case .nextSurface:
                return StoredShortcut(key: "]", command: true, shift: true, option: false, control: false)
            case .prevSurface:
                return StoredShortcut(key: "[", command: true, shift: true, option: false, control: false)
            case .newSurface:
                return StoredShortcut(key: "t", command: true, shift: false, option: false, control: false)
            case .toggleTerminalCopyMode:
                return StoredShortcut(key: "m", command: true, shift: true, option: false, control: false)
            case .toggleBrowserDeveloperTools:
                // Safari default: Show Web Inspector.
                return StoredShortcut(key: "i", command: true, shift: false, option: true, control: false)
            case .showBrowserJavaScriptConsole:
                // Safari default: Show JavaScript Console.
                return StoredShortcut(key: "c", command: true, shift: false, option: true, control: false)
            }
        }

        func tooltip(_ base: String) -> String {
            "\(base) (\(KeyboardShortcutSettings.shortcut(for: self).displayString))"
        }
    }

    static func shortcut(for action: Action) -> StoredShortcut {
        guard let data = UserDefaults.standard.data(forKey: action.defaultsKey),
              let shortcut = try? JSONDecoder().decode(StoredShortcut.self, from: data) else {
            return action.defaultShortcut
        }
        return shortcut
    }

    static func setShortcut(_ shortcut: StoredShortcut, for action: Action) {
        if let data = try? JSONEncoder().encode(shortcut) {
            UserDefaults.standard.set(data, forKey: action.defaultsKey)
        }
    }

    static func resetShortcut(for action: Action) {
        UserDefaults.standard.removeObject(forKey: action.defaultsKey)
    }

    static func resetAll() {
        for action in Action.allCases {
            resetShortcut(for: action)
        }
    }
}

/// A keyboard shortcut that can be stored in UserDefaults
struct StoredShortcut: Codable, Equatable {
    var key: String
    var command: Bool
    var shift: Bool
    var option: Bool
    var control: Bool

    var displayString: String {
        var parts: [String] = []
        if control { parts.append("⌃") }
        if option { parts.append("⌥") }
        if shift { parts.append("⇧") }
        if command { parts.append("⌘") }
        let keyText: String
        switch key {
        case "\t":
            keyText = "TAB"
        case "\r":
            keyText = "↩"
        default:
            keyText = key.uppercased()
        }
        parts.append(keyText)
        return parts.joined()
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if command { flags.insert(.command) }
        if shift { flags.insert(.shift) }
        if option { flags.insert(.option) }
        if control { flags.insert(.control) }
        return flags
    }

    var keyEquivalent: KeyEquivalent? {
        switch key {
        case "←":
            return .leftArrow
        case "→":
            return .rightArrow
        case "↑":
            return .upArrow
        case "↓":
            return .downArrow
        case "\t":
            return .tab
        case "\r":
            return KeyEquivalent(Character("\r"))
        default:
            let lowered = key.lowercased()
            guard lowered.count == 1, let character = lowered.first else { return nil }
            return KeyEquivalent(character)
        }
    }

    var eventModifiers: EventModifiers {
        var modifiers: EventModifiers = []
        if command {
            modifiers.insert(.command)
        }
        if shift {
            modifiers.insert(.shift)
        }
        if option {
            modifiers.insert(.option)
        }
        if control {
            modifiers.insert(.control)
        }
        return modifiers
    }

    var menuItemKeyEquivalent: String? {
        switch key {
        case "←":
            guard let scalar = UnicodeScalar(NSLeftArrowFunctionKey) else { return nil }
            return String(Character(scalar))
        case "→":
            guard let scalar = UnicodeScalar(NSRightArrowFunctionKey) else { return nil }
            return String(Character(scalar))
        case "↑":
            guard let scalar = UnicodeScalar(NSUpArrowFunctionKey) else { return nil }
            return String(Character(scalar))
        case "↓":
            guard let scalar = UnicodeScalar(NSDownArrowFunctionKey) else { return nil }
            return String(Character(scalar))
        case "\t":
            return "\t"
        case "\r":
            return "\r"
        default:
            let lowered = key.lowercased()
            guard lowered.count == 1 else { return nil }
            return lowered
        }
    }

    static func from(event: NSEvent) -> StoredShortcut? {
        guard let key = storedKey(from: event) else { return nil }

        // Some keys include extra flags depending on the responder chain.
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function])

        let shortcut = StoredShortcut(
            key: key,
            command: flags.contains(.command),
            shift: flags.contains(.shift),
            option: flags.contains(.option),
            control: flags.contains(.control)
        )

        // Avoid recording plain typing; require at least one modifier.
        if !shortcut.command && !shortcut.shift && !shortcut.option && !shortcut.control {
            return nil
        }
        return shortcut
    }

    private static func storedKey(from event: NSEvent) -> String? {
        // Prefer keyCode mapping so shifted symbol keys (e.g. "}") record as "]".
        switch event.keyCode {
        case 123: return "←" // left arrow
        case 124: return "→" // right arrow
        case 125: return "↓" // down arrow
        case 126: return "↑" // up arrow
        case 48: return "\t" // tab
        case 36, 76: return "\r" // return, keypad enter
        case 33: return "["  // kVK_ANSI_LeftBracket
        case 30: return "]"  // kVK_ANSI_RightBracket
        case 27: return "-"  // kVK_ANSI_Minus
        case 24: return "="  // kVK_ANSI_Equal
        case 43: return ","  // kVK_ANSI_Comma
        case 47: return "."  // kVK_ANSI_Period
        case 44: return "/"  // kVK_ANSI_Slash
        case 41: return ";"  // kVK_ANSI_Semicolon
        case 39: return "'"  // kVK_ANSI_Quote
        case 50: return "`"  // kVK_ANSI_Grave
        case 42: return "\\" // kVK_ANSI_Backslash
        default:
            break
        }

        guard let chars = event.charactersIgnoringModifiers?.lowercased(),
              let char = chars.first else {
            return nil
        }

        // Allow letters/numbers; everything else should be handled by keyCode mapping above.
        if char.isLetter || char.isNumber {
            return String(char)
        }
        return nil
    }
}
