//
//  ContentView.swift
//  zenban
//
//  Created by Berkay Cit on 25.12.2025.
//

import SwiftUI

struct ContentView: View {
    @Environment(BoardStore.self) private var store

    var body: some View {
        @Bindable var store = store

        HSplitView {
            // Sidebar
            NavigationStack {
                BoardListView()
            }
            .frame(minWidth: 160, idealWidth: 160, maxWidth: 260)

            // Content + Detail
            HSplitView {
                // Board content or Dev server
                Group {
                    if store.showDevServer, let card = store.devServerCard {
                        DevServerView(
                            card: card,
                            setupCommand: store.devServerSetupCommand,
                            devCommand: store.devServerDevCommand,
                            onDismiss: store.stopDevServer,
                            onReconfigure: store.openReconfigure
                        )
                        .id(card.id)
                    } else {
                        NavigationStack {
                            if let board = store.selectedBoard {
                                BoardView(board: board)
                            } else {
                                EmptyStateView(
                                    icon: "square.stack.3d.up",
                                    title: "No Board Selected",
                                    subtitle: "Select a board from the sidebar or create a new one"
                                )
                            }
                        }
                    }
                }
                .frame(minWidth: 900, maxWidth: 950)

                // Card detail
                Group {
                    if let board = store.selectedBoard, let card = store.selectedCard {
                        CardDetailView(card: card, boardID: board.id)
                    } else {
                        EmptyStateView(
                            icon: "rectangle.on.rectangle",
                            title: "No Card Selected",
                            subtitle: "Select a card to view its details"
                        )
                    }
                }
                .frame(minWidth: 400, idealWidth: 500, maxWidth: .infinity)
            }
        }
        .onChange(of: store.selectedBoardID) {
            store.selectedCardID = nil
            store.draggedCardID = nil
            store.stopDevServer()
        }
        .frame(minWidth: 1500, minHeight: 600)
        .sheet(isPresented: $store.showDevServerConfig) {
            if let card = store.devServerCard,
               let worktreePath = card.worktreePath,
               let board = store.selectedBoard {
                DevServerCommandSheet(
                    worktreePath: worktreePath,
                    boardID: board.id,
                    isPresented: $store.showDevServerConfig,
                    onStart: store.confirmDevServerConfig
                )
            }
        }
    }
}

#Preview {
    ContentView()
        .environment(BoardStore())
}
