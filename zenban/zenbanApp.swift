//
//  zenbanApp.swift
//  zenban
//
//  Created by Berkay Çit on 25.12.2025.
//

import AppKit
import Bonsplit
import SwiftUI

private enum CmuxEmbeddedBootstrap {
    static func prepareEnvironment() {
        setenv("CMUX_DISABLE_SESSION_RESTORE", "1", 1)
        configureGhosttyEnvironment()
        migrateSocketControlDefaults()
    }

    private static func migrateSocketControlDefaults() {
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: SocketControlSettings.appStorageKey) {
            let migrated = SocketControlSettings.migrateMode(stored)
            if migrated.rawValue != stored {
                defaults.set(migrated.rawValue, forKey: SocketControlSettings.appStorageKey)
            }
        } else if let legacy = defaults.object(forKey: SocketControlSettings.legacyEnabledKey) as? Bool {
            defaults.set(
                legacy ? SocketControlMode.cmuxOnly.rawValue : SocketControlMode.off.rawValue,
                forKey: SocketControlSettings.appStorageKey
            )
        }
    }

    private static func configureGhosttyEnvironment() {
        let fileManager = FileManager.default
        let ghosttyAppResources = "/Applications/Ghostty.app/Contents/Resources/ghostty"
        let bundledGhosttyURL = Bundle.main.resourceURL?.appendingPathComponent("ghostty")
        var resolvedResourcesDir: String?

        if getenv("GHOSTTY_RESOURCES_DIR") == nil {
            if let bundledGhosttyURL,
               fileManager.fileExists(atPath: bundledGhosttyURL.path),
               fileManager.fileExists(atPath: bundledGhosttyURL.appendingPathComponent("themes").path) {
                resolvedResourcesDir = bundledGhosttyURL.path
            } else if fileManager.fileExists(atPath: ghosttyAppResources) {
                resolvedResourcesDir = ghosttyAppResources
            } else if let bundledGhosttyURL, fileManager.fileExists(atPath: bundledGhosttyURL.path) {
                resolvedResourcesDir = bundledGhosttyURL.path
            }

            if let resolvedResourcesDir {
                setenv("GHOSTTY_RESOURCES_DIR", resolvedResourcesDir, 1)
            }
        }

        if getenv("TERM") == nil {
            setenv("TERM", "xterm-ghostty", 1)
        }

        if getenv("TERM_PROGRAM") == nil {
            setenv("TERM_PROGRAM", "ghostty", 1)
        }

        if let resourcesDir = getenv("GHOSTTY_RESOURCES_DIR").flatMap({ String(cString: $0) }) {
            let resourcesURL = URL(fileURLWithPath: resourcesDir)
            let resourcesParent = resourcesURL.deletingLastPathComponent()
            appendEnvPathIfMissing(
                "XDG_DATA_DIRS",
                path: resourcesParent.path,
                defaultValue: "/usr/local/share:/usr/share"
            )
            appendEnvPathIfMissing(
                "MANPATH",
                path: resourcesParent.appendingPathComponent("man").path
            )
        }
    }

    private static func appendEnvPathIfMissing(_ key: String, path: String, defaultValue: String? = nil) {
        if path.isEmpty { return }

        var currentValue = getenv(key).flatMap { String(cString: $0) } ?? ""
        if currentValue.isEmpty, let defaultValue {
            currentValue = defaultValue
        }
        if currentValue.split(separator: ":").contains(Substring(path)) {
            return
        }

        let nextValue = currentValue.isEmpty ? path : "\(path):\(currentValue)"
        setenv(key, nextValue, 1)
    }
}

private enum ArrowKey {
    case up, down, left, right

    init?(keyCode: UInt16) {
        switch keyCode {
        case 126: self = .up
        case 125: self = .down
        case 123: self = .left
        case 124: self = .right
        default: return nil
        }
    }
}

private func responderChainContains(_ start: NSResponder?, target: NSResponder) -> Bool {
    var responder = start
    var hops = 0
    while let current = responder, hops < 64 {
        if current === target { return true }
        responder = current.nextResponder
        hops += 1
    }
    return false
}

private let previewConsoleShortcut = StoredShortcut(
    key: "c",
    command: true,
    shift: true,
    option: false,
    control: false
)

@MainActor
func shortcutEventWindow(for event: NSEvent) -> NSWindow? {
    event.window ?? NSApp.keyWindow ?? NSApp.mainWindow
}

@MainActor
func isShortcutBlockedByPresentedSheet(event: NSEvent) -> Bool {
    shortcutBlockedByPresentedSheet(
        modalWindow: NSApp.modalWindow,
        candidateWindows: [
            event.window,
            NSApp.keyWindow,
            NSApp.mainWindow,
        ].compactMap { $0 },
        allWindows: NSApp.windows
    )
}

func shortcutBlockedByPresentedSheet(
    modalWindow: NSWindow?,
    candidateWindows: [NSWindow],
    allWindows: [NSWindow]
) -> Bool {
    if modalWindow != nil {
        return true
    }

    if candidateWindows.contains(where: { $0.attachedSheet != nil || $0.sheetParent != nil }) {
        return true
    }

    return allWindows.contains { $0.attachedSheet != nil || $0.sheetParent != nil }
}

@MainActor
func isPreviewWebViewFocused(
    event: NSEvent,
    context: CmuxHostStore.BrowserSurfaceContext
) -> Bool {
    let candidateWindow =
        shortcutEventWindow(for: event)
        ?? context.panel.webView.window
    let responderFocused = candidateWindow.map {
        responderChainContains($0.firstResponder, target: context.panel.webView)
    } ?? false
    let portalFocused = candidateWindow.flatMap {
        BrowserWindowPortalRegistry.webViewAtWindowPoint($0.mouseLocationOutsideOfEventStream, in: $0)
    } === context.panel.webView
    return responderFocused || portalFocused
}

@MainActor
func handleZenbanShortcutOverride(
    event: NSEvent,
    store: BoardStore,
    cmuxHost: CmuxHostStore,
    appDelegate: AppDelegate
) -> Bool {
    if isShortcutBlockedByPresentedSheet(event: event) {
        return false
    }

    if appDelegate.matchesShortcut(
        event: event,
        shortcut: KeyboardShortcutSettings.shortcut(for: .renameWorkspace)
    ) {
        guard let card = store.devServerCard else { return false }
        _ = cmuxHost.reloadBrowserSurface(for: card.id)
        return true
    }

    guard appDelegate.matchesShortcut(event: event, shortcut: previewConsoleShortcut) else {
        return false
    }
    guard let card = store.devServerCard,
          let context = cmuxHost.browserSurface(for: card.id),
          isPreviewWebViewFocused(event: event, context: context),
          let tabManager = appDelegate.tabManager else {
        return false
    }

    cmuxHost.focusBrowserSurface(for: card.id)
    if context.panel.isDeveloperToolsVisible() {
        _ = tabManager.toggleDeveloperToolsFocusedBrowser()
        return true
    }
    _ = tabManager.showJavaScriptConsoleFocusedBrowser()
    return true
}

@main
struct zenbanApp: App {
    @State private var store: BoardStore
    @State private var devServerManager: DevServerManager
    @State private var cmuxHost: CmuxHostStore
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var cmuxAppDelegate

    init() {
        CmuxEmbeddedBootstrap.prepareEnvironment()
        ZenbanSentry.startAppIfNeeded()

        let store = BoardStore()
        let devServerManager = DevServerManager()
        let cmuxHost = CmuxHostStore()
        _store = State(initialValue: store)
        _devServerManager = State(initialValue: devServerManager)
        _cmuxHost = State(initialValue: cmuxHost)

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [devServerManager] _ in
            MainActor.assumeIsolated {
                devServerManager.shutdownForAppTermination()
            }
        }

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [store] event in
            if NSApp.keyWindow?.sheetParent != nil {
                return event
            }
            if store.deleteConfirmationRequest != nil || store.showDependencySetup {
                return event
            }

            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if modifiers == [.command],
               event.charactersIgnoringModifiers?.lowercased() == "w" {
                if store.showFileBrowser {
                    NotificationCenter.default.post(name: .closeFileBrowserTab, object: nil)
                }
                return nil
            }

            if let firstResponder = NSApp.keyWindow?.firstResponder,
               firstResponder is NSTextView {
                return event
            }

            let navModifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            guard navModifiers == [.command, .shift] else { return event }

            guard let key = ArrowKey(keyCode: event.keyCode) else {
                return event
            }

            switch key {
            case .up:
                if store.focusRegion == .sidebar {
                    store.selectPreviousBoard()
                } else {
                    store.selectPreviousCard()
                }
            case .down:
                if store.focusRegion == .sidebar {
                    store.selectNextBoard()
                } else {
                    store.selectNextCard()
                }
            case .left:
                guard store.focusRegion == .cards else { return event }
                store.selectCardInPreviousColumn()
            case .right:
                if store.focusRegion == .sidebar {
                    store.enterCardsFromSidebar()
                } else {
                    store.selectCardInNextColumn()
                }
            }
            return nil
        }
    }

    var body: some Scene {
        WindowGroup {
            ZenbanRootView()
                .environment(store)
                .environment(devServerManager)
                .environment(cmuxHost)
                .navigationTitle("")
                .onAppear {
                    _ = cmuxAppDelegate
                    cmuxAppDelegate.zenbanShortcutOverrideHandler = { [store, cmuxHost] event in
                        handleZenbanShortcutOverride(
                            event: event,
                            store: store,
                            cmuxHost: cmuxHost,
                            appDelegate: cmuxAppDelegate
                        )
                    }
                    store.onCardDeleted = { [devServerManager] cardID in
                        devServerManager.stopServer(for: cardID)
                    }
                    store.cmuxHost = cmuxHost
                    cmuxHost.attach(boardStore: store)
                }
        }
        .commands {
            BoardCommands(store: store, cmuxHost: cmuxHost)
        }

        Settings {
            ZenbanSettingsView()
                .environment(store)
        }
    }
}
