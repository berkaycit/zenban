import SwiftUI

struct CardView: View {
    let card: Card
    let boardID: UUID
    @Environment(BoardStore.self) private var store
    @State private var isHovering = false

    private var isSelected: Bool {
        store.selectedCardID == card.id
    }

    var body: some View {
        HStack {
            Text(card.title)
                .font(.body)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isHovering {
                Button(action: { store.deleteCard(card.id, from: boardID) }) {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture {
            store.selectedCardID = card.id
            store.focusRegion = .cards
        }
    }
}
