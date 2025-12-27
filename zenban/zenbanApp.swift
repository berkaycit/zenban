//
//  zenbanApp.swift
//  zenban
//
//  Created by Berkay Çit on 25.12.2025.
//

import SwiftUI

@main
struct zenbanApp: App {
    @State private var store = BoardStore()
    @State private var terminalManager = TerminalManager()

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
    }
}
