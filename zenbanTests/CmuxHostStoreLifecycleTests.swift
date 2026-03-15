import AppKit
import Bonsplit
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
    func notificationMovesMappedTodoCardToInReview() throws {
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
            title: "Build finished",
            subtitle: "Completed in cc-42",
            body: "Done"
        )

        let notification = try #require(notificationStore.notifications.first)
        #expect(notification.title == card.title)
        #expect(notification.subtitle == "Completed in cc-42")
        #expect(boardStore.card(id: card.id)?.column == .inProgress)
    }

    @Test
    func notificationLeavesMappedInReviewCardUntouched() throws {
        let notificationStore = TerminalNotificationStore.shared
        notificationStore.configureNotificationDeliveryHandlerForTesting { _, _ in }
        notificationStore.replaceNotificationsForTesting([])
        defer {
            notificationStore.replaceNotificationsForTesting([])
            notificationStore.resetNotificationDeliveryHandlerForTesting()
        }

        let appDelegate = AppDelegate()
        let (boardStore, board, card) = makeBoardFixture(column: .inProgress)
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
            title: "Build finished",
            subtitle: "Workspace notification",
            body: "Done"
        )

        #expect(boardStore.card(id: card.id)?.column == .inProgress)
    }

    @Test
    func notificationLeavesMappedDoneCardUntouched() throws {
        let notificationStore = TerminalNotificationStore.shared
        notificationStore.configureNotificationDeliveryHandlerForTesting { _, _ in }
        notificationStore.replaceNotificationsForTesting([])
        defer {
            notificationStore.replaceNotificationsForTesting([])
            notificationStore.resetNotificationDeliveryHandlerForTesting()
        }

        let appDelegate = AppDelegate()
        let (boardStore, board, card) = makeBoardFixture(column: .done)
        let (hostStore, window) = makeHostStore(boardStore: boardStore)
        defer {
            window.close()
            _ = appDelegate
        }

        hostStore.openTerminal(for: card, boardID: board.id)
        let workspace = try #require(hostStore.workspace(for: card.id))

        notificationStore.addNotification(
            tabId: workspace.id,
            surfaceId: workspace.focusedPanelId,
            title: "Build finished",
            subtitle: "Workspace notification",
            body: "Done"
        )

        #expect(boardStore.card(id: card.id)?.column == .done)
    }

    @Test
    func syncSelectionDoesNotCreateWorkspaceForDoneCard() {
        let appDelegate = AppDelegate()
        let (boardStore, board, card) = makeBoardFixture(column: .done)
        let (hostStore, window) = makeHostStore(boardStore: boardStore)
        defer {
            window.close()
            _ = appDelegate
        }

        hostStore.syncSelection(card: card, boardID: board.id)

        #expect(hostStore.workspace(for: card.id) == nil)
    }

    @Test
    func openTerminalCreatesWorkspaceForDoneCard() throws {
        let appDelegate = AppDelegate()
        let (boardStore, board, card) = makeBoardFixture(column: .done)
        let (hostStore, window) = makeHostStore(boardStore: boardStore)
        defer {
            window.close()
            _ = appDelegate
        }

        hostStore.openTerminal(for: card, boardID: board.id)

        let workspace = try #require(hostStore.workspace(for: card.id))
        #expect(workspace.focusedTerminalPanel != nil)
    }

    @Test
    func ensureBrowserSurfaceKeepsTerminalFocused() throws {
        let appDelegate = AppDelegate()
        let (boardStore, board, card) = makeBoardFixture()
        let (hostStore, window) = makeHostStore(boardStore: boardStore)
        defer {
            window.close()
            _ = appDelegate
        }

        hostStore.syncSelection(card: card, boardID: board.id)

        let workspace = try #require(hostStore.workspace(for: card.id))
        let focusedPaneId = try #require(workspace.bonsplitController.focusedPaneId)
        let terminalPanelId = try #require(workspace.focusedPanelId)
        let terminalTabId = try #require(workspace.surfaceIdFromPanelId(terminalPanelId))
        let previewURL = URL(string: "http://localhost:5173")!

        hostStore.ensureBrowserSurface(
            for: card,
            boardID: board.id,
            url: previewURL
        )

        let browserContext = try #require(hostStore.browserSurface(for: card.id))

        #expect(browserContext.panel.id != terminalPanelId)
        #expect(workspace.focusedPanelId == terminalPanelId)
        #expect(workspace.bonsplitController.selectedTab(inPane: focusedPaneId)?.id == terminalTabId)
        #expect(!workspace.panels.values.contains { $0.panelType == .browser })
    }

    @Test
    func manualDoneWorkspaceClosesWhenSelectionLeavesCardAndDoesNotReopenOnReturn() throws {
        let appDelegate = AppDelegate()
        let doneCard = Card(title: "done", column: .done, orderIndex: 0, agent: .claude, worktreePath: "/tmp/done")
        let todoCard = Card(title: "todo", column: .todo, orderIndex: 0, agent: .claude, worktreePath: "/tmp/todo")
        let board = Board(name: "Done Selection", cards: [doneCard, todoCard], repositoryPath: "/tmp/repo", agent: .claude)
        let boardStore = makeBoardStore(board: board, selectedCardID: doneCard.id)
        let (hostStore, window) = makeHostStore(boardStore: boardStore)
        defer {
            window.close()
            _ = appDelegate
        }

        hostStore.openTerminal(for: doneCard, boardID: board.id)
        #expect(hostStore.workspace(for: doneCard.id) != nil)

        hostStore.syncSelection(card: todoCard, boardID: board.id)

        #expect(hostStore.workspace(for: doneCard.id) == nil)
        #expect(hostStore.workspace(for: todoCard.id) != nil)

        hostStore.syncSelection(card: doneCard, boardID: board.id)

        #expect(hostStore.workspace(for: doneCard.id) == nil)
    }

    @Test
    func notificationForUnmappedWorkspaceDoesNothing() {
        let notificationStore = TerminalNotificationStore.shared
        notificationStore.configureNotificationDeliveryHandlerForTesting { _, _ in }
        notificationStore.replaceNotificationsForTesting([])
        defer {
            notificationStore.replaceNotificationsForTesting([])
            notificationStore.resetNotificationDeliveryHandlerForTesting()
        }

        let appDelegate = AppDelegate()
        let (boardStore, _, card) = makeBoardFixture()
        let (hostStore, window) = makeHostStore(boardStore: boardStore)
        defer {
            window.close()
            _ = appDelegate
            _ = hostStore
        }

        notificationStore.addNotification(
            tabId: UUID(),
            surfaceId: nil,
            title: "Build finished",
            subtitle: "Workspace notification",
            body: "Done"
        )

        #expect(boardStore.card(id: card.id)?.column == .todo)
    }

    @Test
    func notificationUsesWorkspaceTitleForNonCardWorkspace() throws {
        let notificationStore = TerminalNotificationStore.shared
        notificationStore.configureNotificationDeliveryHandlerForTesting { _, _ in }
        notificationStore.replaceNotificationsForTesting([])
        defer {
            notificationStore.replaceNotificationsForTesting([])
            notificationStore.resetNotificationDeliveryHandlerForTesting()
        }

        let appDelegate = AppDelegate()
        let boardStore = BoardStore()
        let (hostStore, window) = makeHostStore(boardStore: boardStore)
        defer {
            window.close()
            _ = appDelegate
        }

        let workspace = hostStore.tabManager.addWorkspace(select: false)
        workspace.setCustomTitle("Infra")

        notificationStore.addNotification(
            tabId: workspace.id,
            surfaceId: workspace.focusedPanelId,
            title: "Build finished",
            subtitle: "Workspace notification",
            body: "Done"
        )

        let notification = try #require(notificationStore.notifications.first)
        #expect(notification.title == "Infra")
        #expect(notification.subtitle == "Workspace notification")
    }

    @Test
    func notificationFallsBackToCallerTitleWhenWorkspaceTitleIsUnavailable() throws {
        let notificationStore = TerminalNotificationStore.shared
        notificationStore.configureNotificationDeliveryHandlerForTesting { _, _ in }
        notificationStore.replaceNotificationsForTesting([])
        defer {
            notificationStore.replaceNotificationsForTesting([])
            notificationStore.resetNotificationDeliveryHandlerForTesting()
        }

        let title = "Build finished"
        notificationStore.addNotification(
            tabId: UUID(),
            surfaceId: nil,
            title: title,
            subtitle: "Workspace notification",
            body: "Done"
        )

        let notification = try #require(notificationStore.notifications.first)
        #expect(notification.title == title)
        #expect(notification.subtitle == "Workspace notification")
    }

    @Test
    func suppressedNotificationStillMovesMappedTodoCardToInReview() throws {
        let notificationStore = TerminalNotificationStore.shared
        var deliveryCount = 0
        notificationStore.configureNotificationDeliveryHandlerForTesting { _, _ in
            deliveryCount += 1
        }
        notificationStore.replaceNotificationsForTesting([])
        AppFocusState.overrideIsFocused = true
        defer {
            AppFocusState.overrideIsFocused = nil
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
            title: "Build finished",
            subtitle: "Workspace notification",
            body: "Done"
        )

        let notification = try #require(notificationStore.notifications.first)
        #expect(deliveryCount == 0)
        #expect(notification.title == card.title)
        #expect(notification.subtitle == "Workspace notification")
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
    func movingCardToDoneClosesWorkspace() throws {
        let appDelegate = AppDelegate()
        let (boardStore, board, card) = makeBoardFixture()
        let (hostStore, window) = makeHostStore(boardStore: boardStore)
        defer {
            window.close()
            _ = appDelegate
        }

        hostStore.syncSelection(card: card, boardID: board.id)
        #expect(hostStore.workspace(for: card.id) != nil)

        #expect(boardStore.moveCard(card.id, to: .done, in: board.id))

        #expect(boardStore.card(id: card.id)?.column == .done)
        #expect(hostStore.workspace(for: card.id) == nil)
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

    private func makeBoardFixture(column: Column = .todo) -> (BoardStore, Board, Card) {
        let card = Card(title: "cc-42", column: column, agent: .claude, worktreePath: "/tmp/cc-42")
        let board = Board(
            name: "Workspace Ownership",
            cards: [card],
            repositoryPath: "/tmp/repo",
            agent: .claude
        )
        let boardStore = makeBoardStore(board: board, selectedCardID: card.id)
        return (boardStore, board, card)
    }

    private func makeBoardStore(board: Board, selectedCardID: UUID?) -> BoardStore {
        let boardStore = BoardStore()
        boardStore.boards = [board]
        boardStore.selectedBoardID = board.id
        boardStore.selectedCardID = selectedCardID
        return boardStore
    }

    private func makeHostStore(boardStore: BoardStore) -> (CmuxHostStore, NSWindow) {
        let hostStore = CmuxHostStore()
        boardStore.cmuxHost = hostStore
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
