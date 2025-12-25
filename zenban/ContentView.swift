//
//  ContentView.swift
//  zenban
//
//  Created by Berkay Çit on 25.12.2025.
//

import SwiftUI

struct ContentView: View {
    @Environment(BoardStore.self) private var store

    var body: some View {
        @Bindable var store = store

        NavigationSplitView {
            BoardListView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
        } content: {
            if let board = store.selectedBoard {
                BoardView(board: board)
            } else {
                EmptyStateView(
                    icon: "square.stack.3d.up",
                    title: "No Board Selected",
                    subtitle: "Select a board from the sidebar or create a new one"
                )
            }
        } detail: {
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
        }
        .frame(minWidth: 1100, minHeight: 600)
    }
}

#Preview {
    ContentView()
        .environment(BoardStore())
}
