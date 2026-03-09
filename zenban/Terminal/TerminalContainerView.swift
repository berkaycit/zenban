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
        // Use read-only lookup to avoid mutating @Observable state during body evaluation.
        // The record is guaranteed to exist because CardWorkspaceDeckView creates it
        // in onAppear/onChange before this view is mounted.
        if let record = terminalManager.existingWorkspaceRecord(for: cardID) {
            WorkspaceContentView(
                workspace: record.workspace,
                isWorkspaceVisible: isWorkspaceVisible,
                isWorkspaceInputActive: isWorkspaceInputActive,
                workspacePortalPriority: workspacePortalPriority,
                onThemeRefreshRequest: nil
            )
        }
    }
}
