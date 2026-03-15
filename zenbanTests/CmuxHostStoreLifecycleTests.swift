import AppKit
import Foundation
import Testing
@testable import zenban

@MainActor
struct CmuxHostStoreLifecycleTests {
    @Test
    func syncSelectionReusesWorkspaceOwnedByAnotherTabManager() throws {
        let appDelegate = AppDelegate()
        let (boardStore, board, card) = makeBoardFixture()
        let (primaryStore, primaryWindow) = makeHostStore(boardStore: boardStore)
        let (secondaryStore, secondaryWindow) = makeHostStore(boardStore: boardStore)
        defer {
            primaryWindow.close()
            secondaryWindow.close()
            _ = appDelegate
        }

        primaryStore.syncSelection(card: card, boardID: board.id)
        let originalWorkspace = try #require(primaryStore.workspace(for: card.id))

        #expect(
            appDelegate.moveWorkspaceToWindow(
                workspaceId: originalWorkspace.id,
                windowId: secondaryStore.primaryWindowId,
                focus: false
            )
        )

        let movedWorkspaceCount = secondaryStore.tabManager.tabs.count

        primaryStore.syncSelection(card: card, boardID: board.id)
        let reusedWorkspace = try #require(primaryStore.workspace(for: card.id))

        #expect(reusedWorkspace.id == originalWorkspace.id)
        #expect(!primaryStore.tabManager.tabs.contains(where: { $0.id == originalWorkspace.id }))
        #expect(secondaryStore.tabManager.tabs.contains(where: { $0.id == originalWorkspace.id }))
        #expect(secondaryStore.tabManager.tabs.count == movedWorkspaceCount)
        #expect(secondaryStore.tabManager.selectedTabId == originalWorkspace.id)
    }

    @Test
    func claudeCompletionNotificationMovesCardToInReview() throws {
        let notificationStore = TerminalNotificationStore.shared
        notificationStore.configureNotificationDeliveryHandlerForTesting { _, _ in }
        notificationStore.replaceNotificationsForTesting([])
        defer {
            notificationStore.replaceNotificationsForTesting([])
            notificationStore.resetNotificationDeliveryHandlerForTesting()
        }

        let appDelegate = AppDelegate()
        let (boardStore, board, card) = makeBoardFixture()
        let (hostStore, window) = makeHostStore(boardStore: boardStore)
        defer {
            window.close()
            _ = appDelegate
        }

        hostStore.syncSelection(card: card, boardID: board.id)
        let workspace = try #require(hostStore.workspace(for: card.id))

        notificationStore.addNotification(
            tabId: workspace.id,
            surfaceId: workspace.focusedPanelId,
            title: Agent.claude.rawValue,
            subtitle: "Completed in \(card.title)",
            body: "Done"
        )

        #expect(boardStore.card(id: card.id)?.column == .inProgress)
    }

    @Test
    func restoreTerminalFocusTargetsOwningTabManager() throws {
        let appDelegate = AppDelegate()
        let (boardStore, board, card) = makeBoardFixture()
        let (primaryStore, primaryWindow) = makeHostStore(boardStore: boardStore)
        let (secondaryStore, secondaryWindow) = makeHostStore(boardStore: boardStore)
        defer {
            primaryWindow.close()
            secondaryWindow.close()
            _ = appDelegate
        }

        primaryStore.syncSelection(card: card, boardID: board.id)
        let originalWorkspace = try #require(primaryStore.workspace(for: card.id))

        #expect(
            appDelegate.moveWorkspaceToWindow(
                workspaceId: originalWorkspace.id,
                windowId: secondaryStore.primaryWindowId,
                focus: false
            )
        )

        secondaryStore.tabManager.selectedTabId = secondaryStore.tabManager.tabs.first(where: { $0.id != originalWorkspace.id })?.id
        primaryStore.restoreTerminalFocus(for: card.id)

        #expect(secondaryStore.tabManager.selectedTabId == originalWorkspace.id)
        #expect(!primaryStore.tabManager.tabs.contains(where: { $0.id == originalWorkspace.id }))
    }

    @Test
    func removeWorkspaceClosesWorkspaceThroughOwningTabManager() throws {
        let appDelegate = AppDelegate()
        let (boardStore, board, card) = makeBoardFixture()
        let (primaryStore, primaryWindow) = makeHostStore(boardStore: boardStore)
        let (secondaryStore, secondaryWindow) = makeHostStore(boardStore: boardStore)
        defer {
            primaryWindow.close()
            secondaryWindow.close()
            _ = appDelegate
        }

        primaryStore.syncSelection(card: card, boardID: board.id)
        let originalWorkspace = try #require(primaryStore.workspace(for: card.id))

        #expect(
            appDelegate.moveWorkspaceToWindow(
                workspaceId: originalWorkspace.id,
                windowId: secondaryStore.primaryWindowId,
                focus: false
            )
        )

        primaryStore.removeWorkspace(for: card.id)

        #expect(primaryStore.workspace(for: card.id) == nil)
        #expect(!secondaryStore.tabManager.tabs.contains(where: { $0.id == originalWorkspace.id }))
        #expect(appDelegate.tabManagerFor(tabId: originalWorkspace.id) == nil)
    }

    @Test
    func childExitOnLastPanelClosesWorkspaceAgain() throws {
        let tabManager = TabManager()
        let workspace = tabManager.addWorkspace(select: false)
        let terminalPanelId = try #require(workspace.focusedPanelId)

        #expect(tabManager.tabs.contains(where: { $0.id == workspace.id }))

        tabManager.closePanelAfterChildExited(tabId: workspace.id, surfaceId: terminalPanelId)

        #expect(!tabManager.tabs.contains(where: { $0.id == workspace.id }))
    }

    private func makeBoardFixture() -> (BoardStore, Board, Card) {
        let card = Card(title: "cc-42", agent: .claude, worktreePath: "/tmp/cc-42")
        let board = Board(
            name: "Workspace Ownership",
            cards: [card],
            repositoryPath: "/tmp/repo",
            agent: .claude
        )
        let boardStore = BoardStore()
        boardStore.boards = [board]
        boardStore.selectedBoardID = board.id
        boardStore.selectedCardID = card.id
        return (boardStore, board, card)
    }

    private func makeHostStore(boardStore: BoardStore) -> (CmuxHostStore, NSWindow) {
        let hostStore = CmuxHostStore()
        hostStore.attach(boardStore: boardStore)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        hostStore.registerMainWindow(window)
        return (hostStore, window)
    }
}
