//
//  zenbanApp.swift
//  zenban
//
//  Created by Berkay Çit on 25.12.2025.
//

import SwiftUI
import AppKit

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

@main
struct zenbanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = BoardStore()
    @State private var terminalManager = TerminalManager()
    @State private var agentSessionMonitor = AgentSessionMonitor()
    @State private var devServerManager = DevServerManager()

    init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [agentSessionMonitor, terminalManager, devServerManager] _ in
            MainActor.assumeIsolated {
                agentSessionMonitor.stop()
                terminalManager.terminateAllSessions()
                devServerManager.stopAllServers()
                TmuxSessionManager.shared.killAllZenbanSessionsSync()
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeOcclusionStateNotification,
            object: nil,
            queue: .main
        ) { [terminalManager] _ in
            MainActor.assumeIsolated {
                if NSApplication.shared.occlusionState.contains(.visible) {
                    terminalManager.resumeAllTerminals()
                } else {
                    terminalManager.suspendAllTerminals()
                }
            }
        }

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [store, terminalManager] event in
            // Skip if inside a sheet, dialog, or text field
            if NSApp.keyWindow?.sheetParent != nil {
                return event
            }
            if store.showDeleteConfirmation || store.showDependencySetup {
                return event
            }

            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if modifiers == [.command],
               event.charactersIgnoringModifiers?.lowercased() == "w" {
                // When file browser is open, close the tab; otherwise just consume the event
                if store.showFileBrowser {
                    NotificationCenter.default.post(name: .closeFileBrowserTab, object: nil)
                }
                return nil
            }

            if let firstResponder = NSApp.keyWindow?.firstResponder,
               firstResponder is NSTextView {
                return event
            }

            // Cmd+Shift+Enter to focus terminal (only if terminal doesn't have focus)
            let enterModifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            if event.keyCode == 36,
               enterModifiers == [.command, .shift],
               let cardID = store.selectedCardID,
               !terminalManager.isTerminalFocused(for: cardID) {
                terminalManager.focusTerminal(for: cardID)
                return nil
            }

            let navModifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            guard navModifiers == [.command, .shift] else { return event }

            // Cmd+Shift+Arrow for navigation
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
            ContentView()
                .environment(store)
                .environment(terminalManager)
                .environment(devServerManager)
                .background(
                    WindowAccessor { window in
                        appDelegate.registerMainAppWindow(window)
                    }
                )
                .navigationTitle("")
                .onAppear {
                    setupCardDeletionHandler()
                    setupAgentMonitoring()
                    setupNotifications()
                    Task {
                        await TmuxSessionManager.shared.updateConfig()
                        await TmuxSessionManager.shared.killAllZenbanSessions()
                    }
                    store.checkDependencies()
                }
                .onReceive(NotificationCenter.default.publisher(for: .ghosttyConfigDidReload)) { _ in
                    Task {
                        await TmuxSessionManager.shared.updateConfig()
                    }
                }
        }
        .commands {
            BoardCommands(store: store)
        }

        Settings {
            SettingsView()
                .environment(store)
        }
    }

    private func setupCardDeletionHandler() {
        terminalManager.boardStore = store
        store.terminalManager = terminalManager
        appDelegate.terminalManager = terminalManager
        appDelegate.registerMainBoardTabManager(terminalManager.boardWindowTabManager)
        store.onCardDeleted = { [agentSessionMonitor, terminalManager, devServerManager] cardID in
            agentSessionMonitor.removeCard(cardID)
            terminalManager.killSessionForCard(cardID)
            devServerManager.stopServer(for: cardID)
        }
    }

    private func setupAgentMonitoring() {
        terminalManager.agentSessionMonitor = agentSessionMonitor
        agentSessionMonitor.connect(boardStore: store, terminalManager: terminalManager)
        agentSessionMonitor.start()
    }

    private func setupNotifications() {
        NotificationService.shared.requestAuthorization()
        NotificationService.shared.onNotificationClicked = { [store] boardID, cardID in
            store.selectedBoardID = boardID
            store.selectedCardID = cardID
        }
    }
}
