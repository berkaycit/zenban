//
//  zenbanApp.swift
//  zenban
//
//  Created by Berkay Çit on 25.12.2025.
//

import SwiftUI
import AppKit

@main
struct zenbanApp: App {
    @State private var store = BoardStore()
    @State private var terminalManager = TerminalManager()

    init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [terminalManager] _ in
            terminalManager.terminateAllSessions()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(terminalManager)
                .onAppear {
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
        store.onCardDeleted = { [terminalManager] cardID in
            Task {
                await terminalManager.killSessionForCard(cardID)
            }
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
