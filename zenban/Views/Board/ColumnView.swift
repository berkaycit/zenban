import SwiftUI

struct ColumnView: View {
    let column: Column
    let cards: [Card]
    let boardID: UUID
    @Environment(BoardStore.self) private var store
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ColumnHeaderView(column: column, count: cards.count)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(cards) { card in
                        CardView(card: card, boardID: boardID)
                            .draggable(card.id.uuidString)
                    }
                }
                .padding(12)
            }
        }
        .frame(width: 280)
        .background(Color.columnBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isTargeted ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .dropDestination(for: String.self) { items, _ in
            guard let cardIDString = items.first,
                  let cardID = UUID(uuidString: cardIDString) else { return false }
            store.moveCard(cardID, to: column, in: boardID)
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
    }
}
