import AppKit
import Bonsplit
import Foundation
import Testing
@testable import zenban

@Suite(.serialized)
@MainActor
struct CmuxHostStoreLifecycleTests {
    private enum WaitError: Error {
        case timedOut
    }

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
            subtitle: "",
            body: "Done"
        )

        let notification = try #require(notificationStore.notifications.first)
        #expect(notification.title == card.title)
        #expect(notification.subtitle.isEmpty)
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
    func reloadBrowserSurfaceReturnsFalseWhenPreviewHasNotBeenCreated() {
        let appDelegate = AppDelegate()
        let (boardStore, board, card) = makeBoardFixture()
        let (hostStore, window) = makeHostStore(boardStore: boardStore)
        defer {
            window.close()
            _ = appDelegate
        }

        hostStore.syncSelection(card: card, boardID: board.id)

        #expect(!hostStore.reloadBrowserSurface(for: card.id))
    }

    @Test
    func reloadBrowserSurfaceReturnsTrueAndKeepsSameBrowserContext() throws {
        let appDelegate = AppDelegate()
        let (boardStore, board, card) = makeBoardFixture()
        let (hostStore, window) = makeHostStore(boardStore: boardStore)
        defer {
            window.close()
            _ = appDelegate
        }

        hostStore.syncSelection(card: card, boardID: board.id)
        hostStore.ensureBrowserSurface(
            for: card,
            boardID: board.id,
            url: URL(string: "http://localhost:5173")!
        )

        let originalContext = try #require(hostStore.browserSurface(for: card.id))

        #expect(hostStore.reloadBrowserSurface(for: card.id))

        let reloadedContext = try #require(hostStore.browserSurface(for: card.id))
        #expect(reloadedContext.panel === originalContext.panel)
        #expect(reloadedContext.panel.id == originalContext.panel.id)
        #expect(reloadedContext.paneId == originalContext.paneId)
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
        let doneWorkspace = try #require(hostStore.workspace(for: doneCard.id))
        #expect(ZellijSessionManager.shared.isManagedWorkspace(doneWorkspace.id))

        hostStore.syncSelection(card: todoCard, boardID: board.id)

        #expect(hostStore.workspace(for: doneCard.id) == nil)
        #expect(hostStore.workspace(for: todoCard.id) != nil)
        #expect(!ZellijSessionManager.shared.isManagedWorkspace(doneWorkspace.id))

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
    func standaloneHostSuppressedNotificationStillMovesMappedTodoCardToInReview() throws {
        let notificationStore = TerminalNotificationStore.shared
        var deliveryCount = 0
        notificationStore.configureNotificationDeliveryHandlerForTesting { _, _ in
            deliveryCount += 1
        }
        notificationStore.replaceNotificationsForTesting([])
        defer {
            notificationStore.replaceNotificationsForTesting([])
            notificationStore.resetNotificationDeliveryHandlerForTesting()
        }

        let appDelegate = AppDelegate()
        appDelegate.setHostBundleIdentifierForTesting("com.cmuxterm.app")
        AppFocusState.overrideIsFocused = true
        let (boardStore, board, card) = makeBoardFixture()
        let (hostStore, window) = makeHostStore(boardStore: boardStore)
        defer {
            AppFocusState.overrideIsFocused = nil
            appDelegate.clearNotificationFirstResponderOwnerPanelIdOverrideForTesting()
            appDelegate.setHostBundleIdentifierForTesting(nil)
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
    func zenbanHostDeliversNotificationWhenCardIsSelectedButNoPanelOwnsFirstResponder() throws {
        let notificationStore = TerminalNotificationStore.shared
        var deliveryCount = 0
        notificationStore.configureNotificationDeliveryHandlerForTesting { _, _ in
            deliveryCount += 1
        }
        notificationStore.replaceNotificationsForTesting([])
        defer {
            notificationStore.replaceNotificationsForTesting([])
            notificationStore.resetNotificationDeliveryHandlerForTesting()
        }

        let appDelegate = AppDelegate()
        AppFocusState.overrideIsFocused = true
        appDelegate.setNotificationFirstResponderOwnerPanelIdForTesting(nil)
        let (boardStore, board, card) = makeBoardFixture()
        let (hostStore, window) = makeHostStore(boardStore: boardStore)
        defer {
            AppFocusState.overrideIsFocused = nil
            appDelegate.clearNotificationFirstResponderOwnerPanelIdOverrideForTesting()
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
        #expect(deliveryCount == 1)
        #expect(notification.title == card.title)
        #expect(notification.subtitle == "Workspace notification")
        #expect(boardStore.card(id: card.id)?.column == .inProgress)
    }

    @Test
    func zenbanHostSuppressesNotificationWhenExactTerminalPanelOwnsFirstResponder() throws {
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
        defer {
            notificationStore.replaceNotificationsForTesting([])
            notificationStore.resetSuppressedNotificationFeedbackHandlerForTesting()
            notificationStore.resetNotificationDeliveryHandlerForTesting()
        }

        let appDelegate = AppDelegate()
        AppFocusState.overrideIsFocused = true
        let (boardStore, board, card) = makeBoardFixture()
        let (hostStore, window) = makeHostStore(boardStore: boardStore)
        defer {
            AppFocusState.overrideIsFocused = nil
            appDelegate.clearNotificationFirstResponderOwnerPanelIdOverrideForTesting()
            window.close()
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
        #expect(notification.title == card.title)
        #expect(notification.subtitle == "Workspace notification")
        #expect(!notification.isRead)
        #expect(notificationStore.hasUnreadNotification(forTabId: workspace.id, surfaceId: workspace.focusedPanelId))
        #expect(notificationStore.hasVisibleNotificationIndicator(forTabId: workspace.id, surfaceId: workspace.focusedPanelId))
        #expect(notificationStore.focusedReadIndicatorSurfaceId(forTabId: workspace.id) == workspace.focusedPanelId)
        #expect(boardStore.card(id: card.id)?.column == .inProgress)
    }

    @Test
    func zenbanHostSuppressesNotificationWhenExactBrowserPanelOwnsFirstResponder() throws {
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
        defer {
            notificationStore.replaceNotificationsForTesting([])
            notificationStore.resetSuppressedNotificationFeedbackHandlerForTesting()
            notificationStore.resetNotificationDeliveryHandlerForTesting()
        }

        let appDelegate = AppDelegate()
        AppFocusState.overrideIsFocused = true
        let (boardStore, board, card) = makeBoardFixture()
        let (hostStore, window) = makeHostStore(boardStore: boardStore)
        defer {
            AppFocusState.overrideIsFocused = nil
            appDelegate.clearNotificationFirstResponderOwnerPanelIdOverrideForTesting()
            window.close()
            _ = appDelegate
        }

        hostStore.syncSelection(card: card, boardID: board.id)
        _ = try #require(hostStore.workspace(for: card.id))
        hostStore.ensureBrowserSurface(
            for: card,
            boardID: board.id,
            url: URL(string: "http://localhost:5173")!
        )
        let browserContext = try #require(hostStore.browserSurface(for: card.id))
        hostStore.focusBrowserSurface(for: card.id)
        let browserWorkspace = try #require(
            hostStore.tabManager.tabs.first { $0.panels[browserContext.panel.id] != nil }
        )
        appDelegate.setNotificationFirstResponderOwnerPanelIdForTesting(browserContext.panel.id)

        notificationStore.addNotification(
            tabId: browserWorkspace.id,
            surfaceId: browserContext.panel.id,
            title: "Build finished",
            subtitle: "Workspace notification",
            body: "Done"
        )

        let notification = try #require(notificationStore.notifications.first)
        #expect(deliveryCount == 0)
        #expect(suppressedFeedbackCount == 1)
        #expect(notification.title == "\(card.title) Preview")
        #expect(notification.subtitle == "Workspace notification")
        #expect(!notification.isRead)
        #expect(notificationStore.hasVisibleNotificationIndicator(forTabId: browserWorkspace.id, surfaceId: browserContext.panel.id))
        #expect(notificationStore.focusedReadIndicatorSurfaceId(forTabId: browserWorkspace.id) == browserContext.panel.id)
        #expect(boardStore.card(id: card.id)?.column == .todo)
    }

    @Test
    func zenbanHostDeliversNotificationWhenAnotherWorkspaceIsSelected() throws {
        let notificationStore = TerminalNotificationStore.shared
        var deliveryCount = 0
        notificationStore.configureNotificationDeliveryHandlerForTesting { _, _ in
            deliveryCount += 1
        }
        notificationStore.replaceNotificationsForTesting([])
        defer {
            notificationStore.replaceNotificationsForTesting([])
            notificationStore.resetNotificationDeliveryHandlerForTesting()
        }

        let firstCard = Card(title: "cc-42", column: .todo, orderIndex: 0, agent: .claude, worktreePath: "/tmp/cc-42")
        let secondCard = Card(title: "cc-43", column: .todo, orderIndex: 1, agent: .claude, worktreePath: "/tmp/cc-43")
        let board = Board(
            name: "Workspace Ownership",
            cards: [firstCard, secondCard],
            repositoryPath: "/tmp/repo",
            agent: .claude
        )
        let boardStore = makeBoardStore(board: board, selectedCardID: firstCard.id)

        let appDelegate = AppDelegate()
        AppFocusState.overrideIsFocused = true
        let (hostStore, window) = makeHostStore(boardStore: boardStore)
        defer {
            AppFocusState.overrideIsFocused = nil
            appDelegate.clearNotificationFirstResponderOwnerPanelIdOverrideForTesting()
            window.close()
            _ = appDelegate
        }

        hostStore.syncSelection(card: firstCard, boardID: board.id)
        let firstWorkspace = try #require(hostStore.workspace(for: firstCard.id))
        hostStore.syncSelection(card: secondCard, boardID: board.id)
        _ = try #require(hostStore.workspace(for: secondCard.id))
        appDelegate.setNotificationFirstResponderOwnerPanelIdForTesting(firstWorkspace.focusedPanelId)

        notificationStore.addNotification(
            tabId: firstWorkspace.id,
            surfaceId: firstWorkspace.focusedPanelId,
            title: "Build finished",
            subtitle: "Workspace notification",
            body: "Done"
        )

        let notification = try #require(notificationStore.notifications.first)
        #expect(deliveryCount == 1)
        #expect(notification.title == firstCard.title)
        #expect(notification.subtitle == "Workspace notification")
        #expect(boardStore.card(id: firstCard.id)?.column == .inProgress)
        #expect(boardStore.card(id: secondCard.id)?.column == .todo)
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
    func movingRootTerminalBetweenWorkspacesKeepsOneDeterministicRootPerWorkspace() throws {
        let tabManager = TabManager()
        let sourceWorkspace = tabManager.addWorkspace(
            workingDirectory: "/tmp/source-root",
            select: false
        )
        let destinationWorkspace = tabManager.addWorkspace(
            workingDirectory: "/tmp/destination-root",
            select: false
        )

        let originalSourceRoot = try #require(sourceWorkspace.workspaceRootTerminalPanel())
        let remainingSourceTerminal = try #require(
            sourceWorkspace.newTerminalSurfaceInFocusedPane(focus: false)
        )
        let originalDestinationRoot = try #require(destinationWorkspace.workspaceRootTerminalPanel())
        let destinationPane = try #require(destinationWorkspace.bonsplitController.focusedPaneId)

        let detached = try #require(sourceWorkspace.detachSurface(panelId: originalSourceRoot.id))
        let attachedPanelId = try #require(
            destinationWorkspace.attachDetachedSurface(
                detached,
                inPane: destinationPane,
                focus: false
            )
        )

        #expect(attachedPanelId == detached.panelId)
        #expect(sourceWorkspace.workspaceRootTerminalPanel()?.id == remainingSourceTerminal.id)
        #expect(destinationWorkspace.workspaceRootTerminalPanel()?.id == originalDestinationRoot.id)
    }

    @Test
    func hiddenWorkspaceDetachCancelsWhenReselectedAndDetachesWhenStillHidden() async throws {
        let appDelegate = AppDelegate()
        let sourceCard = Card(title: "cc-42", column: .todo, orderIndex: 0, agent: .claude, worktreePath: "/tmp/cc-42")
        let siblingCard = Card(title: "cc-43", column: .todo, orderIndex: 1, agent: .claude, worktreePath: "/tmp/cc-43")
        let board = Board(
            name: "Hidden Detach",
            cards: [sourceCard, siblingCard],
            repositoryPath: "/tmp/repo",
            agent: .claude
        )
        let boardStore = makeBoardStore(board: board, selectedCardID: sourceCard.id)
        let (hostStore, window) = makeHostStore(boardStore: boardStore)
        hostStore.setHiddenWorkspaceDetachDelayForTesting(.milliseconds(150))
        defer {
            hostStore.setHiddenWorkspaceDetachDelayForTesting(.seconds(3))
            window.close()
            _ = appDelegate
        }

        hostStore.syncSelection(card: sourceCard, boardID: board.id)
        let sourceWorkspace = try #require(hostStore.workspace(for: sourceCard.id))
        try await waitUntil { sourceWorkspace.hasLoadedTerminalSurface() }

        hostStore.syncSelection(card: siblingCard, boardID: board.id)
        hostStore.cancelLaunchTaskForTesting(cardID: sourceCard.id)

        hostStore.syncSelection(card: sourceCard, boardID: board.id)
        try await Task.sleep(for: .milliseconds(250))
        #expect(sourceWorkspace.hasLoadedTerminalSurface())

        hostStore.syncSelection(card: siblingCard, boardID: board.id)
        hostStore.cancelLaunchTaskForTesting(cardID: sourceCard.id)
        try await waitUntil { !sourceWorkspace.hasLoadedTerminalSurface() }
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
        let startupEnvironment = try ZellijSessionManager.shared.startupEnvironment(for: originalWorkspace.id)
        let attachCommand = try ZellijSessionManager.shared.attachCommand(for: originalWorkspace.id)
        let launchFilePath = try #require(startupEnvironment["CMUX_ZELLIJ_LAUNCH_FILE"])

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
        #expect(!ZellijSessionManager.shared.isManagedWorkspace(originalWorkspace.id))
        #expect(!FileManager.default.fileExists(atPath: launchFilePath))
        #expect(!FileManager.default.fileExists(atPath: attachCommand))
        #expect((try? ZellijSessionManager.shared.startupEnvironment(for: originalWorkspace.id)) == nil)
        #expect((try? ZellijSessionManager.shared.attachCommand(for: originalWorkspace.id)) == nil)
    }

    @Test
    func applicationTerminationShutdownCleansUpManagedSessionArtifacts() async throws {
        let appDelegate = AppDelegate()
        let sessionManager = ZellijSessionManager.shared
        sessionManager.resetTestingHooks()
        sessionManager.killAllSessions()
        sessionManager.configureSessionNamesHookForTesting { [] }
        let (boardStore, board, card) = makeBoardFixture()
        let (hostStore, window) = makeHostStore(boardStore: boardStore)
        defer {
            sessionManager.resetTestingHooks()
            sessionManager.killAllSessions()
            window.close()
            _ = appDelegate
        }

        hostStore.syncSelection(card: card, boardID: board.id)

        let workspace = try #require(hostStore.workspace(for: card.id))
        let startupEnvironment = try ZellijSessionManager.shared.startupEnvironment(for: workspace.id)
        let attachCommand = try ZellijSessionManager.shared.attachCommand(for: workspace.id)
        let launchFilePath = try #require(startupEnvironment["CMUX_ZELLIJ_LAUNCH_FILE"])

        try await waitUntil {
            FileManager.default.fileExists(atPath: launchFilePath) &&
            FileManager.default.fileExists(atPath: attachCommand)
        }

        let shutdownResult = await hostStore.shutdownForApplicationTermination(timeout: 0.1)

        try await waitUntil {
            !ZellijSessionManager.shared.isManagedWorkspace(workspace.id) &&
            !FileManager.default.fileExists(atPath: launchFilePath) &&
            !FileManager.default.fileExists(atPath: attachCommand)
        }

        #expect(shutdownResult.completedBeforeTimeout)
        #expect(shutdownResult.remainingSessionNames.isEmpty)
        #expect(hostStore.pendingLaunchSnapshotForTesting(cardID: card.id) == nil)
        #expect((try? ZellijSessionManager.shared.startupEnvironment(for: workspace.id)) == nil)
        #expect((try? ZellijSessionManager.shared.attachCommand(for: workspace.id)) == nil)
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
        let workspace = try #require(hostStore.workspace(for: card.id))
        #expect(ZellijSessionManager.shared.isManagedWorkspace(workspace.id))

        #expect(boardStore.moveCard(card.id, to: .done, in: board.id))

        #expect(boardStore.card(id: card.id)?.column == .done)
        #expect(hostStore.workspace(for: card.id) == nil)
        #expect(!ZellijSessionManager.shared.isManagedWorkspace(workspace.id))
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
}
