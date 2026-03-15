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
    func agentSummaryPrefersMeaningfulStatusOverNotificationAndIgnoresGenericStatus() throws {
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
}
