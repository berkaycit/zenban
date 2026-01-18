//
//  ContentView.swift
//  zenban
//
//  Created by Berkay Cit on 25.12.2025.
//

import SwiftUI

struct ContentView: View {
    @Environment(BoardStore.self) private var store
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var store = store

        NavigationSplitView(columnVisibility: $columnVisibility) {
            // Sidebar
            BoardListView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 220)
        } content: {
            // Board content, Dev server, or Git changes
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
                } else if store.showGitChanges, let card = store.gitChangesCard, let board = store.selectedBoard {
                    GitChangesView(
                        card: card,
                        boardID: board.id,
                        onDismiss: store.stopGitChanges
                    )
                    .id(card.id)
                } else if store.showFileBrowser, let card = store.fileBrowserCard, let board = store.selectedBoard {
                    FileBrowserOverlayView(card: card, boardID: board.id)
                        .id(card.id)
                } else if let board = store.selectedBoard {
                    BoardView(board: board)
                } else {
                    EmptyStateView(
                        icon: "square.stack.3d.up",
                        title: "No Board Selected",
                        subtitle: "Select a board from the sidebar or create a new one"
                    )
                }
            }
            .navigationSplitViewColumnWidth(min: 600, ideal: 800, max: 1000)
        } detail: {
            // Card detail
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
        .onChange(of: store.selectedBoardID) {
            store.selectedCardID = nil
            store.draggedCardID = nil
            store.stopOverlays()
        }
        .frame(minWidth: 1200, minHeight: 600)
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
        .sheet(isPresented: $store.showKeyboardShortcuts) {
            KeyboardShortcutsView()
        }
        .overlay {
            if store.showDeleteConfirmation, let card = store.selectedCard {
                ZStack {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                        .onTapGesture { store.cancelDeleteSelectedCard() }

                    DeleteConfirmationView(
                        cardTitle: card.title,
                        onDelete: store.confirmDeleteSelectedCard,
                        onCancel: store.cancelDeleteSelectedCard
                    )
                }
            }
        }
        .overlay {
            if store.showDependencySetup {
                ZStack {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()

                    DependencySetupView()
                }
            }
        }
    }
}

#Preview {
    ContentView()
        .environment(BoardStore())
}
