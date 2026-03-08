import SwiftUI

struct BoardListView: View {
    @Environment(BoardStore.self) private var store
    @State private var isAddingBoard = false

    var body: some View {
        List {
            ForEach(store.sortedBoards) { board in
                BoardRowView(board: board)
                    .listRowSeparator(.visible, edges: .bottom)
                    .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .navigationTitle(" ")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: { isAddingBoard = true }) {
                    Image(systemName: "folder.badge.plus")
                }
                .controlSize(.large)
                .help("New Board")

                Button(action: { NotificationCenter.default.post(name: .newCard, object: nil) }) {
                    Image(systemName: "square.and.pencil")
                }
                .controlSize(.large)
                .help("New Task")

                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .controlSize(.large)
                .help("Settings")
            }
        }
        .sheet(isPresented: $isAddingBoard) {
            AddBoardSheet(isPresented: $isAddingBoard)
        }
        .onReceive(NotificationCenter.default.publisher(for: .newBoard)) { _ in
            isAddingBoard = true
        }
        .onChange(of: store.selectedBoardID) {
            store.focusRegion = .sidebar
        }
    }
}

