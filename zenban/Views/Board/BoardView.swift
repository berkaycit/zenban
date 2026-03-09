import SwiftUI

struct BoardView: View {
    let board: Board
    @Environment(BoardStore.self) private var store

    var body: some View {
        let cardsByColumn = Dictionary(
            grouping: board.cards.sorted { $0.orderIndex < $1.orderIndex },
            by: \.column
        )

        HStack(alignment: .top, spacing: 16) {
            ForEach(Column.allCases) { column in
                ColumnView(column: column, cards: cardsByColumn[column] ?? [], boardID: board.id)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.boardBackground)
        .dropDestination(for: Card.self) { _, _ in
            store.draggedCardID = nil
            return false
        }
        .onReceive(NotificationCenter.default.publisher(for: .newCard)) { _ in
            store.addCardWithAutoName(to: board.id)
        }
    }
}
