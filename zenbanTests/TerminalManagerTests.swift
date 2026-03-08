import Testing
@testable import zenban

@MainActor
struct TerminalManagerTests {
    @Test
    func workspaceRecordUsesCardIdentityForWorkspace() {
        let terminalManager = TerminalManager()
        let cardID = UUID()
        let boardID = UUID()

        let record = terminalManager.workspaceRecord(
            for: cardID,
            boardID: boardID,
            cardTitle: "Card Alpha"
        )

        #expect(record.cardID == cardID)
        #expect(record.boardID == boardID)
        #expect(record.workspace.id == cardID)
        #expect(record.cardTitle == "Card Alpha")
        #expect(record.tabManager === terminalManager.boardWindowTabManager)
        #expect(terminalManager.boardWindowTabManager.tabs.map(\.id) == [cardID])

        let renamed = terminalManager.workspaceRecord(
            for: cardID,
            boardID: boardID,
            cardTitle: "Card Beta"
        )
        #expect(renamed.cardTitle == "Card Beta")
        #expect(terminalManager.record(forWorkspaceID: cardID)?.cardTitle == "Card Beta")
    }

    @Test
    func moveWorkspaceBetweenBoardAndDetachedManagersUpdatesOwnership() {
        let terminalManager = TerminalManager()
        let cardID = UUID()
        let boardID = UUID()
        _ = terminalManager.workspaceRecord(for: cardID, boardID: boardID, cardTitle: "Detached Card")

        let detachedManager = TabManager(
            createsInitialWorkspace: false,
            keepsBootstrapWorkspaceWhenEmpty: false
        )
        let detachedWindowID = UUID()

        let moved = terminalManager.moveWorkspace(
            cardID: cardID,
            to: detachedManager,
            detachedWindowID: detachedWindowID
        )

        #expect(moved)
        #expect(terminalManager.record(forWorkspaceID: cardID)?.tabManager === detachedManager)
        #expect(terminalManager.record(forWorkspaceID: cardID)?.detachedWindowID == detachedWindowID)
        #expect(detachedManager.tabs.map(\.id) == [cardID])
        #expect(terminalManager.boardWindowTabManager.tabs.isEmpty)

        let reattached = terminalManager.attachWorkspaceToBoard(cardID: cardID, focus: false)

        #expect(reattached)
        #expect(terminalManager.record(forWorkspaceID: cardID)?.tabManager === terminalManager.boardWindowTabManager)
        #expect(terminalManager.record(forWorkspaceID: cardID)?.detachedWindowID == nil)
        #expect(terminalManager.boardWindowTabManager.tabs.map(\.id) == [cardID])
        #expect(detachedManager.tabs.isEmpty)
    }
}
