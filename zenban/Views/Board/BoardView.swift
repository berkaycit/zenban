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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.boardBackground)
        .dropDestination(for: Card.self) { _, _ in
            store.draggedCardID = nil
            return false
        }
        .sheet(isPresented: $isAddingCard) {
            CardEditorView(boardID: board.id, isPresented: $isAddingCard)
        }
        .onReceive(NotificationCenter.default.publisher(for: .newCard)) { _ in
            isAddingCard = true
        }
    }
}
