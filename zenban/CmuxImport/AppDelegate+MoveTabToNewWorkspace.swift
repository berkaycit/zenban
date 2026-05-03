import Foundation
import Bonsplit

struct SurfaceNewWorkspaceMoveResult {
    let sourceWindowId: UUID
    let sourceWorkspaceId: UUID
    let destinationWindowId: UUID?
    let destinationWorkspaceId: UUID
    let surfaceId: UUID
    let paneId: UUID?
}

@MainActor
extension AppDelegate {
    @discardableResult
    func moveSurfaceToNewWorkspace(
        panelId: UUID,
        destinationManager: TabManager? = nil,
        title: String? = nil,
        focus: Bool = true,
        focusWindow: Bool = true
    ) -> SurfaceNewWorkspaceMoveResult? {
        guard let source = locateSurface(surfaceId: panelId),
              let sourceWorkspace = source.tabManager.tabs.first(where: { $0.id == source.workspaceId }),
              let sourcePanel = sourceWorkspace.panels[panelId],
              sourceWorkspace.panels.count > 1 else {
            return nil
        }

        let targetManager = destinationManager ?? source.tabManager
        let destinationWorkspace = targetManager.addWorkspace(select: false)
        let bootstrapPanelId = destinationWorkspace.focusedPanelId
        targetManager.setCustomTitle(
            tabId: destinationWorkspace.id,
            title: titleForDetachedWorkspace(title: title, workspace: sourceWorkspace, panelId: panelId, panel: sourcePanel)
        )

        guard moveSurface(
            panelId: panelId,
            toWorkspace: destinationWorkspace.id,
            targetIndex: 0,
            focus: focus,
            focusWindow: focusWindow
        ) else {
            if targetManager.tabs.contains(where: { $0.id == destinationWorkspace.id }) {
                targetManager.closeWorkspace(destinationWorkspace)
            }
            return nil
        }

        if let bootstrapPanelId,
           bootstrapPanelId != panelId,
           destinationWorkspace.panels.count > 1 {
            _ = destinationWorkspace.closePanel(bootstrapPanelId, force: true)
        }

        return SurfaceNewWorkspaceMoveResult(
            sourceWindowId: source.windowId,
            sourceWorkspaceId: source.workspaceId,
            destinationWindowId: windowId(for: targetManager),
            destinationWorkspaceId: destinationWorkspace.id,
            surfaceId: panelId,
            paneId: destinationWorkspace.paneId(forPanelId: panelId)?.id
        )
    }

    private func titleForDetachedWorkspace(
        title explicitTitle: String?,
        workspace: Workspace,
        panelId: UUID,
        panel: any Panel
    ) -> String {
        let trimmedTitle = explicitTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedTitle, !trimmedTitle.isEmpty {
            return trimmedTitle
        }

        let fallback = workspace.panelTitle(panelId: panelId) ?? panel.displayTitle
        let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedFallback.isEmpty {
            return trimmedFallback
        }

        return String(localized: "commandPalette.subtitle.tabFallback", defaultValue: "Tab")
    }
}
