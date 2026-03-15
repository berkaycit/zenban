import SwiftUI

struct CardView: View {
    let card: Card
    let boardID: UUID
    @Environment(BoardStore.self) private var store
    @Environment(CmuxHostStore.self) private var cmuxHost
    @State private var isHovering = false

    private var isSelected: Bool {
        store.selectedCardID == card.id
    }

    private var agentSummary: String? {
        cmuxHost.agentSummary(for: card.id)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                Text(card.title)
                    .font(.body)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let agentSummary {
                    Text(agentSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if isHovering {
                Button(action: { store.deleteCard(card.id, from: boardID) }) {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete card")
                .padding(.top, 2)
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
