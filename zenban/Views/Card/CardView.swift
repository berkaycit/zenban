import SwiftUI

struct CardView: View {
    let card: Card
    let boardID: UUID
    @Environment(BoardStore.self) private var store
    @State private var isEditing = false
    @State private var isHovering = false

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
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(isHovering ? 0.1 : 0.05), radius: isHovering ? 4 : 2, y: 1)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .onTapGesture(count: 2) {
            isEditing = true
        }
        .sheet(isPresented: $isEditing) {
            CardEditorView(boardID: boardID, card: card, isPresented: $isEditing)
        }
    }
}
