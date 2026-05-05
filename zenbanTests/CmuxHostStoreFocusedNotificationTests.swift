import AppKit
import Foundation
import Testing
@testable import zenban

@Suite(.serialized)
@MainActor
struct CmuxHostStoreFocusedNotificationTests {
    @Test
    func focusedTerminalNotificationSuppressesExternalDeliveryAndKeepsVisibleIndicator() throws {
        let notificationStore = TerminalNotificationStore.shared
        var deliveryCount = 0
        var suppressedFeedbackCount = 0
        notificationStore.configureNotificationDeliveryHandlerForTesting { _, _ in
            deliveryCount += 1
        }
        notificationStore.configureSuppressedNotificationFeedbackHandlerForTesting { _, _ in
            suppressedFeedbackCount += 1
        }
        notificationStore.replaceNotificationsForTesting([])
        let previousShared = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppFocusState.overrideIsFocused = true
        let (boardStore, board, card, hostStore, window) = try makeHostFixture()
        defer {
            AppFocusState.overrideIsFocused = nil
            appDelegate.clearNotificationFirstResponderOwnerPanelIdOverrideForTesting()
            appDelegate.unregisterMainWindowForTesting(window)
            window.orderOut(nil)
            AppDelegate.shared = previousShared
            notificationStore.replaceNotificationsForTesting([])
            notificationStore.resetSuppressedNotificationFeedbackHandlerForTesting()
            notificationStore.resetNotificationDeliveryHandlerForTesting()
            _ = appDelegate
        }

        hostStore.syncSelection(card: card, boardID: board.id)
        let workspace = try #require(hostStore.workspace(for: card.id))
        appDelegate.setNotificationFirstResponderOwnerPanelIdForTesting(workspace.focusedPanelId)

        notificationStore.addNotification(
            tabId: workspace.id,
            surfaceId: workspace.focusedPanelId,
            title: "Build finished",
            subtitle: "Workspace notification",
            body: "Done"
        )

        let notification = try #require(notificationStore.notifications.first)
        #expect(deliveryCount == 0)
        #expect(suppressedFeedbackCount == 1)
        #expect(!notification.isRead)
        #expect(notificationStore.hasUnreadNotification(forTabId: workspace.id, surfaceId: workspace.focusedPanelId))
        #expect(notificationStore.hasVisibleNotificationIndicator(forTabId: workspace.id, surfaceId: workspace.focusedPanelId))
        #expect(notificationStore.focusedReadIndicatorSurfaceId(forTabId: workspace.id) == workspace.focusedPanelId)
        #expect(boardStore.card(id: card.id)?.column == .inProgress)
    }

    @Test
    func cardReadMarksNotificationReadAndClearsVisibleIndicator() throws {
        let notificationStore = TerminalNotificationStore.shared
        var deliveryCount = 0
        notificationStore.configureNotificationDeliveryHandlerForTesting { _, _ in
            deliveryCount += 1
        }
        notificationStore.replaceNotificationsForTesting([])
        AppFocusState.overrideIsFocused = false
        let previousShared = AppDelegate.shared
        let appDelegate = AppDelegate()
        let (boardStore, board, card, hostStore, window) = try makeHostFixture()
        defer {
            AppFocusState.overrideIsFocused = nil
            appDelegate.unregisterMainWindowForTesting(window)
            window.orderOut(nil)
            AppDelegate.shared = previousShared
            notificationStore.replaceNotificationsForTesting([])
            notificationStore.resetNotificationDeliveryHandlerForTesting()
            _ = appDelegate
            _ = boardStore
        }

        hostStore.syncSelection(card: card, boardID: board.id)
        let workspace = try #require(hostStore.workspace(for: card.id))
        let body = "Finished the focused notification fix"

        notificationStore.addNotification(
            tabId: workspace.id,
            surfaceId: workspace.focusedPanelId,
            title: "Claude Code",
            subtitle: "Waiting",
            body: body
        )
        let firstNotification = try #require(notificationStore.notifications.first)
        #expect(deliveryCount == 1)
        #expect(!firstNotification.isRead)

        hostStore.markTerminalNotificationsRead(for: card.id)
        #expect(notificationStore.notifications.first?.isRead == true)
        #expect(!notificationStore.hasVisibleNotificationIndicator(forTabId: workspace.id, surfaceId: workspace.focusedPanelId))
        #expect(notificationStore.focusedReadIndicatorSurfaceId(forTabId: workspace.id) == nil)
    }

    private func makeHostFixture() throws -> (BoardStore, Board, Card, CmuxHostStore, NSWindow) {
        let worktreeURL = makeWorktreePath()
        let card = Card(
            title: "cc-42",
            column: .todo,
            agent: .claude,
            worktreePath: worktreeURL.path
        )
        let board = Board(
            name: "Focused Notification Tests",
            cards: [card],
            repositoryPath: worktreeURL.deletingLastPathComponent().path,
            agent: .claude
        )
        let boardStore = BoardStore(initialBoards: [board], persistenceEnabled: false)
        boardStore.selectedBoardID = board.id
        boardStore.selectedCardID = card.id

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
        return (boardStore, board, card, hostStore, window)
    }

    private func makeWorktreePath() -> URL {
        let basePath = ProcessInfo.processInfo.environment["CMUX_UI_TEST_BOARD_STORAGE_DIRECTORY"]
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches/Zenban/focused-notification-tests")
                .path
        return URL(fileURLWithPath: basePath, isDirectory: true)
            .appendingPathComponent("worktrees", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
