import SwiftUI

struct TerminalContainerView: View {
    let cardID: UUID
    let boardID: UUID
    let cardTitle: String

    @Environment(BoardStore.self) private var boardStore
    @Environment(TerminalManager.self) private var terminalManager

    var body: some View {
        let record = terminalManager.workspaceRecord(for: cardID, boardID: boardID, cardTitle: cardTitle)
        let isActiveCard = boardStore.selectedCardID == cardID

        WorkspaceContentView(
            workspace: record.workspace,
            isWorkspaceVisible: isActiveCard,
            isWorkspaceInputActive: isActiveCard && NSApp.isActive,
            workspacePortalPriority: isActiveCard ? 100 : 0,
            onThemeRefreshRequest: nil
        )
        .environmentObject(TerminalNotificationStore.shared)
        .onAppear {
            terminalManager.activateWorkspace(for: cardID)
        }
        .onDisappear {
            terminalManager.deactivateWorkspace(for: cardID)
        }
        .onChange(of: boardStore.selectedCardID) { _, newValue in
            guard let newValue else { return }
            if newValue == cardID {
                terminalManager.activateWorkspace(for: cardID)
            }
        }
    }
}
