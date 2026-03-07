import SwiftUI

struct TerminalContainerView: View {
    let cardID: UUID
    let boardID: UUID
    let cardTitle: String
    let isWorkspaceVisible: Bool
    let isWorkspaceInputActive: Bool
    let workspacePortalPriority: Int

    @Environment(TerminalManager.self) private var terminalManager

    var body: some View {
        let record = terminalManager.workspaceRecord(for: cardID, boardID: boardID, cardTitle: cardTitle)

        WorkspaceContentView(
            workspace: record.workspace,
            isWorkspaceVisible: isWorkspaceVisible,
            isWorkspaceInputActive: isWorkspaceInputActive,
            workspacePortalPriority: workspacePortalPriority,
            onThemeRefreshRequest: nil
        )
        .environmentObject(TerminalNotificationStore.shared)
    }
}
