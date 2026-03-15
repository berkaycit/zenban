import Foundation
import Testing
import Bonsplit
@testable import zenban

@MainActor
struct WorkspaceSurfaceFocusTests {
    @Test
    func newBrowserSurfaceWithoutFocusKeepsCurrentSelection() throws {
        let (workspace, paneId, selectedPanelId, selectedTabID) = try makeWorkspaceSelectionFixture()
        let previewURL = URL(string: "http://localhost:5173")!

        let browserPanel = try #require(
            workspace.newBrowserSurface(
                inPane: paneId,
                url: previewURL,
                focus: false
            )
        )

        #expect(browserPanel.id != selectedPanelId)
        #expect(workspace.focusedPanelId == selectedPanelId)
        #expect(workspace.bonsplitController.selectedTab(inPane: paneId)?.id.uuid == selectedTabID)
    }

    @Test
    func newTerminalSurfaceWithoutFocusKeepsCurrentSelection() throws {
        let (workspace, paneId, selectedPanelId, selectedTabID) = try makeWorkspaceSelectionFixture()

        let terminalPanel = try #require(
            workspace.newTerminalSurface(
                inPane: paneId,
                focus: false
            )
        )

        #expect(terminalPanel.id != selectedPanelId)
        #expect(workspace.focusedPanelId == selectedPanelId)
        #expect(workspace.bonsplitController.selectedTab(inPane: paneId)?.id.uuid == selectedTabID)
    }

    @Test
    func newMarkdownSurfaceWithoutFocusKeepsCurrentSelection() throws {
        let (workspace, paneId, selectedPanelId, selectedTabID) = try makeWorkspaceSelectionFixture()
        let markdownURL = try makeMarkdownFixtureFile()
        defer {
            try? FileManager.default.removeItem(at: markdownURL)
        }

        let markdownPanel = try #require(
            workspace.newMarkdownSurface(
                inPane: paneId,
                filePath: markdownURL.path,
                focus: false
            )
        )

        #expect(markdownPanel.id != selectedPanelId)
        #expect(workspace.focusedPanelId == selectedPanelId)
        #expect(workspace.bonsplitController.selectedTab(inPane: paneId)?.id.uuid == selectedTabID)
    }

    private func makeWorkspaceSelectionFixture() throws -> (Workspace, PaneID, UUID, UUID) {
        let tabManager = TabManager()
        let workspace = tabManager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let selectedPanelId = try #require(workspace.focusedPanelId)
        let selectedTab = try #require(workspace.bonsplitController.selectedTab(inPane: paneId))
        return (workspace, paneId, selectedPanelId, selectedTab.id.uuid)
    }

    private func makeMarkdownFixtureFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-surface-focus-\(UUID().uuidString)")
            .appendingPathExtension("md")
        try "# Surface Focus\n".write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
