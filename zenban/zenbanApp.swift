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

final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: BoardStore?
    var terminalManager: TerminalManager?
    var devServerManager: DevServerManager?
    private var eventMonitor: Any?

    func setupEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event) ?? event
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard let store, let terminalManager else { return event }

        if NSApp.keyWindow?.sheetParent != nil { return event }
        if store.showDeleteConfirmation { return event }
        if let firstResponder = NSApp.keyWindow?.firstResponder,
           firstResponder is NSTextView {
            return event
        }

        // Enter to focus terminal
        if event.keyCode == 36,
           !event.modifierFlags.contains(.shift),
           let cardID = store.selectedCardID,
           !terminalManager.isTerminalFocused(for: cardID) {
            terminalManager.focusTerminal(for: cardID)
            return nil
        }

        guard event.modifierFlags.contains(.shift),
              let key = ArrowKey(keyCode: event.keyCode) else {
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

    func applicationWillTerminate(_ notification: Notification) {
        terminalManager?.terminateAllSessions()
        devServerManager?.stopAllServers()
    }
}

@main
struct zenbanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = BoardStore()
    @State private var terminalManager = TerminalManager()
    @State private var devServerManager = DevServerManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(terminalManager)
                .environment(devServerManager)
                .onAppear {
                    appDelegate.store = store
                    appDelegate.terminalManager = terminalManager
                    appDelegate.devServerManager = devServerManager
                    appDelegate.setupEventMonitor()
                    setupCardDeletionHandler()
                    setupNotifications()
                }
        }
        .commands {
            BoardCommands(store: store)
        }
    }

    private func setupCardDeletionHandler() {
        terminalManager.boardStore = store
        store.terminalManager = terminalManager
        store.onCardDeleted = { [terminalManager, devServerManager] cardID in
            Task {
                await terminalManager.killSessionForCard(cardID)
            }
            devServerManager.stopServer(for: cardID)
        }
    }

    private func setupNotifications() {
        NotificationService.shared.requestAuthorization()
        NotificationService.shared.onNotificationClicked = { [store] boardID, cardID in
            store.selectedBoardID = boardID
            store.selectedCardID = cardID
        }
        NotificationService.shared.onTaskCompleted = { [store] cardID, boardID in
            store.moveCard(cardID, to: .inProgress, in: boardID)
        }
        NotificationService.shared.onAgentResumed = { [store] cardID, boardID in
            store.moveCard(cardID, to: .todo, in: boardID)
        }
    }
}
