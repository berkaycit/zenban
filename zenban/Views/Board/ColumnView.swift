import SwiftUI
import UniformTypeIdentifiers

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
                            .opacity(store.draggedCardID == card.id ? 0 : 1)
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                            .onDrag {
                                store.draggedCardID = card.id
                                store.selectedCardID = card.id
                                let data = try? JSONEncoder().encode(card)
                                let provider = NSItemProvider()
                                provider.registerDataRepresentation(
                                    forTypeIdentifier: UTType.card.identifier,
                                    visibility: .all
                                ) { completion in
                                    completion(data, nil)
                                    return nil
                                }
                                return provider
                            } preview: {
                                CardView(card: card, boardID: boardID)
                                    .frame(width: 256)
                                    .onDisappear {
                                        if store.draggedCardID == card.id {
                                            store.draggedCardID = nil
                                        }
                                    }
                            }
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
        .dropDestination(for: Card.self) { _, _ in
            guard let cardID = store.draggedCardID else { return false }
            withAnimation(.spring(duration: 0.25, bounce: 0.2)) {
                store.moveCard(cardID, to: column, in: boardID)
                store.draggedCardID = nil
            }
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
    }
}
