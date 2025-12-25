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
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.8).combined(with: .opacity),
                                removal: .scale(scale: 0.8).combined(with: .opacity)
                            ))
                            .draggable(card)
                    }
                }
                .padding(12)
            }
        }
        .frame(width: 280)
        .background(isTargeted ? Color.accentColor.opacity(0.1) : Color.columnBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isTargeted ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .animation(.easeInOut(duration: 0.2), value: isTargeted)
        .dropDestination(for: Card.self) { droppedCards, _ in
            guard let card = droppedCards.first else { return false }
            withAnimation(.spring(duration: 0.3, bounce: 0.2)) {
                store.moveCard(card.id, to: column, in: boardID)
            }
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
    }
}
