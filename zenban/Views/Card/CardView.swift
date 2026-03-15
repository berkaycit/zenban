import SwiftUI

struct CardView: View {
    let card: Card
    let boardID: UUID
    @Environment(BoardStore.self) private var store
    @Environment(CmuxHostStore.self) private var cmuxHost

    private var isSelected: Bool {
        store.selectedCardID == card.id
    }

    private var agentSummary: String? {
        cmuxHost.agentSummary(for: card.id) ?? card.agentSummary
    }

    var body: some View {
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
        .padding(12)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
        .onTapGesture {
            store.selectedCardID = card.id
            store.focusRegion = .cards
        }
    }
}
