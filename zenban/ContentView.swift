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
        } detail: {
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
        .frame(minWidth: 900, minHeight: 600)
    }
}

#Preview {
    ContentView()
        .environment(BoardStore())
}
