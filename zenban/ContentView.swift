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
        HSplitView {
            // Sidebar
            NavigationStack {
                BoardListView()
            }
            .frame(minWidth: 160, idealWidth: 160, maxWidth: 260)

            // Content + Detail
            HSplitView {
                // Board content
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
        }
        .focusable()
        .onKeyPress(.upArrow) {
            if store.focusRegion == .sidebar {
                store.selectPreviousBoard()
            } else {
                store.selectPreviousCard()
            }
            return .handled
        }
        .onKeyPress(.downArrow) {
            if store.focusRegion == .sidebar {
                store.selectNextBoard()
            } else {
                store.selectNextCard()
            }
            return .handled
        }
        .onKeyPress(.leftArrow) {
            guard store.focusRegion == .cards else { return .ignored }
            store.selectCardInPreviousColumn()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            if store.focusRegion == .sidebar {
                store.enterCardsFromSidebar()
            } else {
                store.selectCardInNextColumn()
            }
            return .handled
        }
        .frame(minWidth: 1500, minHeight: 600)
    }
}

#Preview {
    ContentView()
        .environment(BoardStore())
}
