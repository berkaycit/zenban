import SwiftUI

struct BoardView: View {
    let board: Board
    @Environment(BoardStore.self) private var store
    @State private var isAddingCard = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(Column.allCases) { column in
                ColumnView(column: column, cards: board.cards(in: column), boardID: board.id)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.boardBackground)
        .navigationTitle(board.name)
        .toolbar {
            ToolbarItem {
                Button(action: { isAddingCard = true }) {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $isAddingCard) {
            CardEditorView(boardID: board.id, isPresented: $isAddingCard)
        }
        .onReceive(NotificationCenter.default.publisher(for: .newCard)) { _ in
            isAddingCard = true
        }
    }
}
