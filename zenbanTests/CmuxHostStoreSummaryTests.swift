import Foundation
import Testing
@testable import zenban

@MainActor
struct CmuxHostStoreSummaryTests {
    @Test
    func claudeNotificationMovesTodoCardAndCachesMeaningfulSummary() throws {
        let notificationStore = TerminalNotificationStore.shared
        notificationStore.configureNotificationDeliveryHandlerForTesting { _, _ in }
        notificationStore.replaceNotificationsForTesting([])
        defer {
            notificationStore.replaceNotificationsForTesting([])
            notificationStore.resetNotificationDeliveryHandlerForTesting()
        }

        let (boardStore, board, card, hostStore) = makeHostFixture()
        hostStore.syncSelection(card: card, boardID: board.id)
        let workspace = try #require(hostStore.workspace(for: card.id))
        let summary = "Investigating the login redirect mismatch"

        notificationStore.addNotification(
            tabId: workspace.id,
            surfaceId: workspace.focusedPanelId,
            title: "Claude Code",
            subtitle: "Waiting",
            body: summary
        )

        #expect(boardStore.card(id: card.id)?.column == .inProgress)
        #expect(boardStore.card(id: card.id)?.agentSummary == summary)
        #expect(hostStore.agentSummary(for: card.id) == summary)

        notificationStore.clearNotifications(forTabId: workspace.id)

        #expect(hostStore.agentSummary(for: card.id) == summary)
    }

    @Test
    func agentSummaryPrefersMeaningfulStatusOverNotificationAndIgnoresGenericStatus() async throws {
        let notificationStore = TerminalNotificationStore.shared
        notificationStore.configureNotificationDeliveryHandlerForTesting { _, _ in }
        notificationStore.replaceNotificationsForTesting([])
        defer {
            notificationStore.replaceNotificationsForTesting([])
            notificationStore.resetNotificationDeliveryHandlerForTesting()
        }

        let (boardStore, board, card, hostStore) = makeHostFixture()
        _ = boardStore
        hostStore.syncSelection(card: card, boardID: board.id)
        let workspace = try #require(hostStore.workspace(for: card.id))
        let notificationSummary = "Preparing the migration patch"
        let statusSummary = "Reading migration.sql"

        notificationStore.addNotification(
            tabId: workspace.id,
            surfaceId: workspace.focusedPanelId,
            title: "Claude Code",
            subtitle: "Waiting",
            body: notificationSummary
        )

        workspace.statusEntries["claude_code"] = SidebarStatusEntry(
            key: "claude_code",
            value: statusSummary
        )
        #expect(hostStore.agentSummary(for: card.id) == statusSummary)
        try await waitUntil {
            boardStore.card(id: card.id)?.agentSummary == statusSummary
        }
        #expect(boardStore.card(id: card.id)?.agentSummary == statusSummary)

        workspace.statusEntries["claude_code"] = SidebarStatusEntry(
            key: "claude_code",
            value: "Running"
        )
        #expect(hostStore.agentSummary(for: card.id) == notificationSummary)
    }

    @Test
    func persistedClaudeSummarySurvivesFreshHostStoreAfterRestart() throws {
        let notificationStore = TerminalNotificationStore.shared
        notificationStore.configureNotificationDeliveryHandlerForTesting { _, _ in }
        notificationStore.replaceNotificationsForTesting([])
        defer {
            notificationStore.replaceNotificationsForTesting([])
            notificationStore.resetNotificationDeliveryHandlerForTesting()
        }

        let (boardStore, board, card, hostStore) = makeHostFixture()
        hostStore.syncSelection(card: card, boardID: board.id)
        let workspace = try #require(hostStore.workspace(for: card.id))
        let summary = "Finishing the caching fix for board reloads"

        notificationStore.addNotification(
            tabId: workspace.id,
            surfaceId: workspace.focusedPanelId,
            title: "Claude Code",
            subtitle: "Waiting",
            body: summary
        )

        #expect(boardStore.card(id: card.id)?.agentSummary == summary)

        let relaunchedHostStore = CmuxHostStore()
        boardStore.cmuxHost = relaunchedHostStore
        relaunchedHostStore.attach(boardStore: boardStore)

        #expect(relaunchedHostStore.agentSummary(for: card.id) == summary)
    }

    @Test
    func selectingCardMarksWorkspaceNotificationReadWithoutDroppingSummary() throws {
        let notificationStore = TerminalNotificationStore.shared
        notificationStore.configureNotificationDeliveryHandlerForTesting { _, _ in }
        notificationStore.replaceNotificationsForTesting([])
        AppFocusState.overrideIsFocused = false
        defer {
            AppFocusState.overrideIsFocused = nil
            notificationStore.replaceNotificationsForTesting([])
            notificationStore.resetNotificationDeliveryHandlerForTesting()
        }

        let (boardStore, board, card, hostStore) = makeHostFixture()
        hostStore.syncSelection(card: card, boardID: board.id)
        let workspace = try #require(hostStore.workspace(for: card.id))
        let summary = "Completed the focused notification fix"

        notificationStore.addNotification(
            tabId: workspace.id,
            surfaceId: workspace.focusedPanelId,
            title: "Claude Code",
            subtitle: "Waiting",
            body: summary
        )

        let notification = try #require(notificationStore.notifications.first)
        #expect(!notification.isRead)
        #expect(notificationStore.hasUnreadNotification(forTabId: workspace.id, surfaceId: workspace.focusedPanelId))

        hostStore.syncSelection(card: card, boardID: board.id)

        #expect(notificationStore.notifications.first?.id == notification.id)
        #expect(notificationStore.notifications.first?.isRead == true)
        #expect(!notificationStore.hasUnreadNotification(forTabId: workspace.id, surfaceId: workspace.focusedPanelId))
        #expect(boardStore.card(id: card.id)?.agentSummary == summary)
        #expect(hostStore.agentSummary(for: card.id) == summary)
    }

    @Test
    func nonClaudeCardDoesNotExposeClaudeSummary() throws {
        let notificationStore = TerminalNotificationStore.shared
        notificationStore.configureNotificationDeliveryHandlerForTesting { _, _ in }
        notificationStore.replaceNotificationsForTesting([])
        defer {
            notificationStore.replaceNotificationsForTesting([])
            notificationStore.resetNotificationDeliveryHandlerForTesting()
        }

        let (boardStore, board, card, hostStore) = makeHostFixture(agent: .codex, cardAgent: .codex)
        _ = boardStore
        hostStore.syncSelection(card: card, boardID: board.id)
        let workspace = try #require(hostStore.workspace(for: card.id))

        notificationStore.addNotification(
            tabId: workspace.id,
            surfaceId: workspace.focusedPanelId,
            title: "Codex",
            subtitle: "Attention",
            body: "Reviewing the API boundary"
        )

        #expect(hostStore.agentSummary(for: card.id) == nil)
    }

    @Test
    func genericClaudeNotificationDoesNotPopulateSummary() throws {
        let notificationStore = TerminalNotificationStore.shared
        notificationStore.configureNotificationDeliveryHandlerForTesting { _, _ in }
        notificationStore.replaceNotificationsForTesting([])
        defer {
            notificationStore.replaceNotificationsForTesting([])
            notificationStore.resetNotificationDeliveryHandlerForTesting()
        }

        let (boardStore, board, card, hostStore) = makeHostFixture()
        _ = boardStore
        hostStore.syncSelection(card: card, boardID: board.id)
        let workspace = try #require(hostStore.workspace(for: card.id))

        notificationStore.addNotification(
            tabId: workspace.id,
            surfaceId: workspace.focusedPanelId,
            title: "Claude Code",
            subtitle: "Attention",
            body: "Claude needs your attention"
        )

        #expect(hostStore.agentSummary(for: card.id) == nil)
    }

    private func makeHostFixture(
        column: Column = .todo,
        agent: Agent = .claude,
        cardAgent: Agent? = .claude
    ) -> (BoardStore, Board, Card, CmuxHostStore) {
        let prefix = agent == .claude ? "cc" : agent.runtimeID
        let card = Card(
            title: "\(prefix)-42",
            column: column,
            agent: cardAgent,
            worktreePath: "/tmp/\(prefix)-42"
        )
        let board = Board(
            name: "Summary Tests",
            cards: [card],
            repositoryPath: "/tmp/repo",
            agent: agent
        )
        let boardStore = BoardStore(initialBoards: [board], persistenceEnabled: false)
        boardStore.selectedBoardID = board.id
        boardStore.selectedCardID = card.id

        let hostStore = CmuxHostStore()
        boardStore.cmuxHost = hostStore
        hostStore.attach(boardStore: boardStore)
        return (boardStore, board, card, hostStore)
    }

    private func waitUntil(
        timeout: Duration = .seconds(3),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        throw WaitError.timedOut
    }

    private enum WaitError: Error {
        case timedOut
    }
}
