import SwiftUI

struct CardView: View {
    let card: Card
    let boardID: UUID
    @Environment(BoardStore.self) private var store
    @Environment(CmuxHostStore.self) private var cmuxHost
    @ObservedObject private var notificationStore = TerminalNotificationStore.shared
    @AppStorage(NotificationPaneRingSettings.enabledKey)
    private var notificationPaneRingEnabled = NotificationPaneRingSettings.defaultEnabled

    private var isSelected: Bool {
        store.selectedCardID == card.id
    }

    private var showsUnreadOutline: Bool {
        guard !isSelected,
              notificationPaneRingEnabled,
              card.column == .inProgress else {
            return false
        }

        return cmuxHost.hasUnreadTerminalNotification(for: card.id)
    }

    private var outlineColor: Color {
        if isSelected {
            return .accentColor
        }

        if showsUnreadOutline {
            return card.column.accentColor
        }

        return .clear
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
                .stroke(outlineColor, lineWidth: 2)
        )
        .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
        .onTapGesture {
            store.selectedCardID = card.id
            store.focusRegion = .cards
        }
    }
}
