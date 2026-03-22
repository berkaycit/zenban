import Foundation
import Testing
@testable import zenban

@MainActor
struct CmuxHostStoreLaunchTests {
    private enum WaitError: Error {
        case timedOut
    }

    private struct LaunchRequestRecord: Equatable {
        let url: URL
        let token: String
        let command: String
    }

    @Test
    func claudeLaunchRemainsQueuedUntilAcknowledged() async throws {
        let tempDirectory = try makeTemporaryDirectory()
        let prompt = "Investigate the failing login tests"
        let seededCard = Card(
            title: "cc-42",
            lastSubmittedPrompt: prompt,
            pendingLaunchPrompt: prompt,
            column: .todo,
            orderIndex: 0,
            agent: .claude,
            worktreePath: tempDirectory.path
        )
        let board = Board(
            name: "Workspace Ownership",
            cards: [seededCard],
            repositoryPath: "/tmp/repo",
            agent: .claude
        )
        let boardStore = BoardStore(initialBoards: [board], persistenceEnabled: false)
        boardStore.selectedBoardID = board.id
        boardStore.selectedCardID = seededCard.id
        let hostStore = makeHostStore(boardStore: boardStore)
        hostStore.configureClaudeLaunchHooksForTesting { _, _ in }
        defer {
            hostStore.resetClaudeLaunchHooksForTesting()
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        hostStore.syncSelection(card: seededCard, boardID: board.id)
        try markWorkspacePromptIdle(hostStore: hostStore, cardID: seededCard.id)

        try await waitUntil {
            launchRequestRecord(hostStore: hostStore, cardID: seededCard.id) != nil
        }

        let request = try #require(launchRequestRecord(hostStore: hostStore, cardID: seededCard.id))
        let workspace = try #require(hostStore.workspace(for: seededCard.id))
        let startupEnvironment = try ZellijSessionManager.shared.startupEnvironment(for: workspace.id)
        #expect(boardStore.card(id: seededCard.id)?.pendingLaunchPrompt == prompt)
        #expect(request.command == expectedClaudeLaunchCommand(prompt: prompt))
        #expect(startupEnvironment["CMUX_ZELLIJ_LAUNCH_FILE"] == request.url.path)
        #expect(startupEnvironment["CMUX_ZELLIJ_SHELL"] == (ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"))

        #expect(
            hostStore.acknowledgePendingLaunchForTesting(cardID: seededCard.id)
        )

        try await waitUntil {
            boardStore.card(id: seededCard.id)?.pendingLaunchPrompt == nil
        }
    }

    @Test
    func claudePendingPromptIsConsumedOnlyAfterAcknowledgement() async throws {
        let tempDirectory = try makeTemporaryDirectory()
        let prompt = "Investigate the failing login tests"
        let seededCard = Card(
            title: "cc-42",
            lastSubmittedPrompt: prompt,
            pendingLaunchPrompt: prompt,
            column: .todo,
            orderIndex: 0,
            agent: .claude,
            worktreePath: tempDirectory.path
        )
        let board = Board(
            name: "Workspace Ownership",
            cards: [seededCard],
            repositoryPath: "/tmp/repo",
            agent: .claude
        )
        let boardStore = BoardStore(initialBoards: [board], persistenceEnabled: false)
        boardStore.selectedBoardID = board.id
        boardStore.selectedCardID = seededCard.id
        let hostStore = makeHostStore(boardStore: boardStore)
        hostStore.configureClaudeLaunchHooksForTesting { _, _ in }
        defer {
            hostStore.resetClaudeLaunchHooksForTesting()
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        hostStore.syncSelection(card: seededCard, boardID: board.id)
        try markWorkspacePromptIdle(hostStore: hostStore, cardID: seededCard.id)

        try await waitUntil { launchRequestRecord(hostStore: hostStore, cardID: seededCard.id) != nil }
        let request = try #require(launchRequestRecord(hostStore: hostStore, cardID: seededCard.id))
        #expect(request.command == expectedClaudeLaunchCommand(prompt: prompt))
        #expect(boardStore.card(id: seededCard.id)?.pendingLaunchPrompt == prompt)

        #expect(
            hostStore.acknowledgePendingLaunchForTesting(cardID: seededCard.id)
        )

        try await waitUntil { boardStore.card(id: seededCard.id)?.pendingLaunchPrompt == nil }
    }

    @Test
    func claudeLaunchAcknowledgementIgnoresWrongPanelOrToken() async throws {
        let tempDirectory = try makeTemporaryDirectory()
        let prompt = "Investigate the failing login tests"
        let seededCard = Card(
            title: "cc-42",
            lastSubmittedPrompt: prompt,
            pendingLaunchPrompt: prompt,
            column: .todo,
            orderIndex: 0,
            agent: .claude,
            worktreePath: tempDirectory.path
        )
        let board = Board(
            name: "Workspace Ownership",
            cards: [seededCard],
            repositoryPath: "/tmp/repo",
            agent: .claude
        )
        let boardStore = BoardStore(initialBoards: [board], persistenceEnabled: false)
        boardStore.selectedBoardID = board.id
        boardStore.selectedCardID = seededCard.id
        let hostStore = makeHostStore(boardStore: boardStore)
        let appDelegate = AppDelegate()
        hostStore.configureClaudeLaunchHooksForTesting { _, _ in }
        defer {
            hostStore.resetClaudeLaunchHooksForTesting()
            try? FileManager.default.removeItem(at: tempDirectory)
            _ = appDelegate
        }

        hostStore.syncSelection(card: seededCard, boardID: board.id)

        try await waitUntil {
            launchRequestRecord(hostStore: hostStore, cardID: seededCard.id) != nil
        }

        let request = try #require(launchRequestRecord(hostStore: hostStore, cardID: seededCard.id))
        let workspace = try #require(hostStore.workspace(for: seededCard.id))
        let handler = try #require(AppDelegate.shared?.zenbanLaunchRequestStartedHandler)
        let correctPanelID = try #require(ZellijSessionManager.shared.sessionPanelId(for: workspace.id))

        handler(workspace.id, UUID(), request.token)
        #expect(boardStore.card(id: seededCard.id)?.pendingLaunchPrompt == prompt)
        #expect(launchRequestRecord(hostStore: hostStore, cardID: seededCard.id)?.token == request.token)

        handler(workspace.id, correctPanelID, UUID().uuidString.lowercased())
        #expect(boardStore.card(id: seededCard.id)?.pendingLaunchPrompt == prompt)
        #expect(launchRequestRecord(hostStore: hostStore, cardID: seededCard.id)?.token == request.token)

        handler(workspace.id, correctPanelID, request.token)
        try await waitUntil { boardStore.card(id: seededCard.id)?.pendingLaunchPrompt == nil }
    }

    @Test
    func claudeRepeatedSelectionSyncDoesNotDuplicatePendingLaunch() async throws {
        let tempDirectory = try makeTemporaryDirectory()
        let prompt = "Investigate the failing login tests"
        let seededCard = Card(
            title: "cc-42",
            lastSubmittedPrompt: prompt,
            pendingLaunchPrompt: prompt,
            column: .todo,
            orderIndex: 0,
            agent: .claude,
            worktreePath: tempDirectory.path
        )
        let board = Board(
            name: "Workspace Ownership",
            cards: [seededCard],
            repositoryPath: "/tmp/repo",
            agent: .claude
        )
        let boardStore = BoardStore(initialBoards: [board], persistenceEnabled: false)
        boardStore.selectedBoardID = board.id
        boardStore.selectedCardID = seededCard.id
        let hostStore = makeHostStore(boardStore: boardStore)
        hostStore.configureClaudeLaunchHooksForTesting { _, _ in }
        defer {
            hostStore.resetClaudeLaunchHooksForTesting()
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        hostStore.syncSelection(card: seededCard, boardID: board.id)
        try markWorkspacePromptIdle(hostStore: hostStore, cardID: seededCard.id)

        try await waitUntil {
            launchRequestRecord(hostStore: hostStore, cardID: seededCard.id) != nil
        }

        let initialRequests = launchRequestRecords(hostStore: hostStore, cardIDs: [seededCard.id])
        let initialToken = try #require(initialRequests.first).token
        #expect(initialRequests.count == 1)

        hostStore.syncSelection(card: seededCard, boardID: board.id)
        try markWorkspacePromptIdle(hostStore: hostStore, cardID: seededCard.id)
        try await Task.sleep(for: .milliseconds(300))

        let repeatedRequests = launchRequestRecords(hostStore: hostStore, cardIDs: [seededCard.id])
        #expect(repeatedRequests.count == 1)
        #expect(repeatedRequests.first?.token == initialToken)
        #expect(repeatedRequests.first?.command == expectedClaudeLaunchCommand(prompt: prompt))
        #expect(boardStore.card(id: seededCard.id)?.pendingLaunchPrompt == prompt)
    }

    @Test
    func claudeLaunchRetriesOnceAfterAckTimeoutThenWaitsForManualRetry() async throws {
        let tempDirectory = try makeTemporaryDirectory()
        let prompt = "Investigate the failing login tests"
        let seededCard = Card(
            title: "cc-42",
            lastSubmittedPrompt: prompt,
            pendingLaunchPrompt: prompt,
            column: .todo,
            orderIndex: 0,
            agent: .claude,
            worktreePath: tempDirectory.path
        )
        let board = Board(
            name: "Workspace Ownership",
            cards: [seededCard],
            repositoryPath: "/tmp/repo",
            agent: .claude
        )
        let boardStore = BoardStore(initialBoards: [board], persistenceEnabled: false)
        boardStore.selectedBoardID = board.id
        boardStore.selectedCardID = seededCard.id
        let hostStore = makeHostStore(boardStore: boardStore)
        hostStore.configureClaudeLaunchHooksForTesting { _, _ in }
        hostStore.setPendingLaunchAckTimeoutForTesting(0.05)
        defer {
            hostStore.resetClaudeLaunchHooksForTesting()
            hostStore.setPendingLaunchAckTimeoutForTesting(5)
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        hostStore.syncSelection(card: seededCard, boardID: board.id)
        try markWorkspacePromptIdle(hostStore: hostStore, cardID: seededCard.id)
        try await waitUntil {
            launchRequestRecord(hostStore: hostStore, cardID: seededCard.id) != nil
        }

        let initialRequest = try #require(
            launchRequestRecord(hostStore: hostStore, cardID: seededCard.id)
        )

        try await waitUntil {
            guard let retriedRequest = launchRequestRecord(hostStore: hostStore, cardID: seededCard.id) else {
                return false
            }
            return retriedRequest.token != initialRequest.token
        }

        let retriedRequest = try #require(
            launchRequestRecord(hostStore: hostStore, cardID: seededCard.id)
        )
        let retriedSnapshot = try #require(
            hostStore.pendingLaunchSnapshotForTesting(cardID: seededCard.id)
        )
        #expect(retriedRequest.url == initialRequest.url)
        #expect(retriedRequest.token != initialRequest.token)
        #expect(retriedSnapshot.retryCount == 1)
        #expect(!retriedSnapshot.needsRequeue)

        try await waitUntil {
            hostStore.pendingLaunchSnapshotForTesting(cardID: seededCard.id)?.needsRequeue == true
        }

        let manualRetrySnapshot = try #require(
            hostStore.pendingLaunchSnapshotForTesting(cardID: seededCard.id)
        )
        #expect(manualRetrySnapshot.retryCount == 0)
        #expect(manualRetrySnapshot.needsRequeue)
        #expect(manualRetrySnapshot.token != retriedRequest.token)
        #expect(boardStore.card(id: seededCard.id)?.pendingLaunchPrompt == prompt)
        #expect(!FileManager.default.fileExists(atPath: retriedRequest.url.path))

        hostStore.syncSelection(card: seededCard, boardID: board.id)
        try markWorkspacePromptIdle(hostStore: hostStore, cardID: seededCard.id)
        try await waitUntil {
            launchRequestRecord(hostStore: hostStore, cardID: seededCard.id)?.token == manualRetrySnapshot.token
        }

        #expect(hostStore.acknowledgePendingLaunchForTesting(cardID: seededCard.id))
        try await waitUntil { boardStore.card(id: seededCard.id)?.pendingLaunchPrompt == nil }
    }

    @Test
    func syncSelectionReusesAttachScriptAndStartupEnvironmentWhenUnchanged() async throws {
        let tempDirectory = try makeTemporaryDirectory()
        let (boardStore, board, card) = makeBoardFixture(agent: .claude, worktreePath: tempDirectory.path)
        let hostStore = makeHostStore(boardStore: boardStore)
        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        hostStore.syncSelection(card: card, boardID: board.id)

        let workspace = try #require(hostStore.workspace(for: card.id))
        let initialAttachCommand = try ZellijSessionManager.shared.attachCommand(for: workspace.id)
        let initialEnvironment = try ZellijSessionManager.shared.startupEnvironment(for: workspace.id)
        let initialModificationDate = try #require(
            try FileManager.default
                .attributesOfItem(atPath: initialAttachCommand)[.modificationDate] as? Date
        )

        try await Task.sleep(for: .milliseconds(1200))

        hostStore.syncSelection(card: card, boardID: board.id)

        let updatedAttachCommand = try ZellijSessionManager.shared.attachCommand(for: workspace.id)
        let updatedEnvironment = try ZellijSessionManager.shared.startupEnvironment(for: workspace.id)
        let updatedModificationDate = try #require(
            try FileManager.default
                .attributesOfItem(atPath: updatedAttachCommand)[.modificationDate] as? Date
        )

        #expect(updatedAttachCommand == initialAttachCommand)
        #expect(updatedEnvironment == initialEnvironment)
        #expect(updatedModificationDate == initialModificationDate)
    }

    @Test
    func claudeWorkspaceEnablesPromptCaptureWithoutAgentPid() async throws {
        let tempDirectory = try makeTemporaryDirectory()
        let (boardStore, board, card) = makeBoardFixture(agent: .claude, worktreePath: tempDirectory.path)
        let hostStore = makeHostStore(boardStore: boardStore)
        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        hostStore.syncSelection(card: card, boardID: board.id)

        let workspace = try #require(hostStore.workspace(for: card.id))
        let handler = try #require(AppDelegate.shared?.zenbanClaudePromptCaptureEnabledHandler)
        #expect(handler(workspace.id))
    }

    @Test
    func fanOutPrewarmsCloneWorkspacesWithoutChangingSelection() async throws {
        let tempDirectory = try makeTemporaryDirectory()
        let prompt = "Investigate the failing login tests"
        let sourceCard = Card(
            title: "cc-42",
            lastSubmittedPrompt: prompt,
            column: .todo,
            orderIndex: 0,
            agent: .claude,
            worktreePath: tempDirectory.path
        )
        let board = Board(
            name: "Fan Out",
            cards: [sourceCard],
            agent: .claude
        )
        let boardStore = BoardStore(initialBoards: [board], persistenceEnabled: false)
        boardStore.selectedBoardID = board.id
        boardStore.selectedCardID = sourceCard.id
        let hostStore = makeHostStore(boardStore: boardStore)
        hostStore.configureClaudeLaunchHooksForTesting { _, _ in }
        defer {
            hostStore.resetClaudeLaunchHooksForTesting()
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        boardStore.fanOutClaudePrompt(from: sourceCard.id, in: board.id, count: 2)

        let updatedBoard = try #require(boardStore.board(for: board.id))
        let cloneCards = updatedBoard.cards.filter { $0.id != sourceCard.id }
        #expect(cloneCards.count == 2)
        #expect(boardStore.selectedCardID == sourceCard.id)

        try await waitUntil {
            launchRequestRecords(hostStore: hostStore, cardIDs: cloneCards.map(\.id)).count == 2
        }

        let requests = launchRequestRecords(hostStore: hostStore, cardIDs: cloneCards.map(\.id))
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.command == expectedClaudeLaunchCommand(prompt: prompt) })
    }

    @Test
    func claudePendingLaunchSurvivesWorkspaceRecreationUntilAcknowledgement() async throws {
        let tempDirectory = try makeTemporaryDirectory()
        let (boardStore, board, card) = makeBoardFixture(agent: .claude, worktreePath: tempDirectory.path)
        let hostStore = makeHostStore(boardStore: boardStore)
        hostStore.configureClaudeLaunchHooksForTesting { _, _ in }
        defer {
            hostStore.resetClaudeLaunchHooksForTesting()
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        hostStore.syncSelection(card: card, boardID: board.id)
        try markWorkspacePromptIdle(hostStore: hostStore, cardID: card.id)
        try await waitUntil { launchRequestRecord(hostStore: hostStore, cardID: card.id) != nil }
        let initialRequest = try #require(launchRequestRecord(hostStore: hostStore, cardID: card.id))

        hostStore.removeWorkspace(for: card.id)

        let recreatedCard = card
        hostStore.syncSelection(card: recreatedCard, boardID: board.id)
        try markWorkspacePromptIdle(hostStore: hostStore, cardID: recreatedCard.id)
        try await waitUntil {
            launchRequestRecords(hostStore: hostStore, cardIDs: [recreatedCard.id]).contains { $0.token == initialRequest.token }
        }

        let recreatedRequest = try #require(
            launchRequestRecords(hostStore: hostStore, cardIDs: [recreatedCard.id]).first { $0.token == initialRequest.token }
        )
        #expect(recreatedRequest.token == initialRequest.token)
        #expect(recreatedRequest.command == initialRequest.command)

        #expect(
            hostStore.acknowledgePendingLaunchForTesting(cardID: recreatedCard.id)
        )
        try await waitUntil { boardStore.card(id: recreatedCard.id)?.pendingLaunchPrompt == nil }
    }

    @Test
    func changingAgentFromCodexToClaudeRelaunchesWithClaudeCommand() async throws {
        let tempDirectory = try makeTemporaryDirectory()
        let (boardStore, board, card) = makeBoardFixture(agent: .codex, worktreePath: tempDirectory.path)
        let hostStore = makeHostStore(boardStore: boardStore)
        hostStore.configureClaudeLaunchHooksForTesting { _, _ in }
        defer {
            hostStore.resetClaudeLaunchHooksForTesting()
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        hostStore.syncSelection(card: card, boardID: board.id)
        try markWorkspacePromptIdle(hostStore: hostStore, cardID: card.id)
        try await waitUntil {
            launchRequestRecords(hostStore: hostStore, cardIDs: [card.id]).contains { $0.command == "codex" }
        }
        let codexRequest = try #require(
            launchRequestRecords(hostStore: hostStore, cardIDs: [card.id]).first { $0.command == "codex" }
        )
        #expect(codexRequest.command == "codex")

        var claudeCard = card
        claudeCard.agent = .claude
        hostStore.updateAgentLaunch(for: claudeCard, boardID: board.id)
        try markWorkspacePromptIdle(hostStore: hostStore, cardID: card.id)
        try await waitUntil {
            launchRequestRecords(hostStore: hostStore, cardIDs: [card.id]).contains { $0.command == expectedClaudeLaunchCommand() }
        }
        let claudeRequest = try #require(
            launchRequestRecords(hostStore: hostStore, cardIDs: [card.id]).first { $0.command == expectedClaudeLaunchCommand() }
        )

        #expect(claudeRequest.command == expectedClaudeLaunchCommand())
    }

    @Test
    func nonClaudeLaunchRemainsUnchanged() async throws {
        let tempDirectory = try makeTemporaryDirectory()
        let (boardStore, board, card) = makeBoardFixture(agent: .gemini, worktreePath: tempDirectory.path)
        let hostStore = makeHostStore(boardStore: boardStore)
        var commands: [String] = []
        hostStore.configureClaudeLaunchHooksForTesting(launchCommandHandler: { _, command in
            commands.append(command)
        })
        defer {
            hostStore.resetClaudeLaunchHooksForTesting()
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        hostStore.syncSelection(card: card, boardID: board.id)
        try markWorkspacePromptIdle(hostStore: hostStore, cardID: card.id)
        try await waitUntil { commands.count == 1 }

        #expect(commands == ["gemini"])
        #expect(!FileManager.default.fileExists(atPath: promptFileURL(in: tempDirectory).path))
    }

    @Test
    func doneCardDoesNotAutoLaunchUntilTerminalIsOpened() async throws {
        let tempDirectory = try makeTemporaryDirectory()
        let (boardStore, board, card) = makeBoardFixture(agent: .claude, worktreePath: tempDirectory.path, column: .done)
        let hostStore = makeHostStore(boardStore: boardStore)
        hostStore.configureClaudeLaunchHooksForTesting { _, _ in }
        defer {
            hostStore.resetClaudeLaunchHooksForTesting()
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        hostStore.syncSelection(card: card, boardID: board.id)
        try await Task.sleep(for: .milliseconds(500))
        #expect(hostStore.workspace(for: card.id) == nil)
        #expect(launchRequestRecords(hostStore: hostStore, cardIDs: [card.id]).isEmpty)

        hostStore.openTerminal(for: card, boardID: board.id)
        try markWorkspacePromptIdle(hostStore: hostStore, cardID: card.id)
        try await waitUntil { launchRequestRecord(hostStore: hostStore, cardID: card.id) != nil }
        _ = try #require(launchRequestRecord(hostStore: hostStore, cardID: card.id))
        #expect(
            hostStore.acknowledgePendingLaunchForTesting(cardID: card.id)
        )
        try await waitUntil { boardStore.card(id: card.id)?.pendingLaunchPrompt == nil }
    }

    @Test
    func backgroundPrewarmIdleWorkspaceReclaimsAfterTimeoutWithoutChangingSelection() async throws {
        let tempDirectory = try makeTemporaryDirectory()
        let sourceCard = Card(title: "cc-42", column: .todo, agent: .claude, worktreePath: tempDirectory.path)
        let cloneCard = Card(title: "cc-43", column: .todo, agent: .claude, worktreePath: tempDirectory.path)
        let board = Board(
            name: "Background Reclaim",
            cards: [sourceCard, cloneCard],
            repositoryPath: "/tmp/repo",
            agent: .claude
        )
        let boardStore = BoardStore(initialBoards: [board], persistenceEnabled: false)
        boardStore.selectedBoardID = board.id
        boardStore.selectedCardID = sourceCard.id
        let hostStore = makeHostStore(boardStore: boardStore)
        var reclaimedCardIDs: [UUID] = []
        hostStore.configureBackgroundReclaimHookForTesting { cardID in
            reclaimedCardIDs.append(cardID)
        }
        defer {
            hostStore.configureBackgroundReclaimHookForTesting(nil)
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        hostStore.syncSelection(card: sourceCard, boardID: board.id)
        hostStore.prewarmWorkspaceForBackgroundLaunch(for: cloneCard, boardID: board.id)
        try markWorkspacePromptIdle(hostStore: hostStore, cardID: cloneCard.id)
        hostStore.cancelLaunchTaskForTesting(cardID: cloneCard.id)
        hostStore.markWorkspaceBackgroundPrewarmOnlyForTesting(cardID: cloneCard.id)
        hostStore.setWorkspaceObservedAgentActivityForTesting(cardID: cloneCard.id, date: nil)

        let evaluationTime = Date()
        hostStore.setWorkspaceHiddenSinceForTesting(
            cardID: cloneCard.id,
            date: evaluationTime.addingTimeInterval(-301)
        )

        hostStore.evaluateHiddenWorkspaceReclaimForTesting(now: evaluationTime)

        #expect(reclaimedCardIDs == [cloneCard.id])
        #expect(boardStore.selectedCardID == sourceCard.id)
        #expect(hostStore.workspace(for: cloneCard.id) != nil)
    }

    @Test
    func interactiveWorkspaceIsNotReclaimedWhileHidden() async throws {
        let tempDirectory = try makeTemporaryDirectory()
        let sourceCard = Card(title: "cc-42", column: .todo, agent: .claude, worktreePath: tempDirectory.path)
        let siblingCard = Card(title: "cc-43", column: .todo, agent: .claude, worktreePath: tempDirectory.path)
        let board = Board(
            name: "Interactive",
            cards: [sourceCard, siblingCard],
            repositoryPath: "/tmp/repo",
            agent: .claude
        )
        let boardStore = BoardStore(initialBoards: [board], persistenceEnabled: false)
        boardStore.selectedBoardID = board.id
        boardStore.selectedCardID = sourceCard.id
        let hostStore = makeHostStore(boardStore: boardStore)
        var reclaimedCardIDs: [UUID] = []
        hostStore.configureBackgroundReclaimHookForTesting { cardID in
            reclaimedCardIDs.append(cardID)
        }
        defer {
            hostStore.configureBackgroundReclaimHookForTesting(nil)
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        hostStore.syncSelection(card: sourceCard, boardID: board.id)
        hostStore.syncSelection(card: siblingCard, boardID: board.id)
        try markWorkspacePromptIdle(hostStore: hostStore, cardID: sourceCard.id)
        hostStore.cancelLaunchTaskForTesting(cardID: sourceCard.id)
        hostStore.markWorkspaceInteractiveForTesting(cardID: sourceCard.id)
        hostStore.setWorkspaceObservedAgentActivityForTesting(cardID: sourceCard.id, date: nil)

        let evaluationTime = Date()
        hostStore.setWorkspaceHiddenSinceForTesting(
            cardID: sourceCard.id,
            date: evaluationTime.addingTimeInterval(-301)
        )

        hostStore.evaluateHiddenWorkspaceReclaimForTesting(now: evaluationTime)

        #expect(reclaimedCardIDs.isEmpty)
    }

    @Test
    func backgroundPrewarmWorkspaceWithObservedActivityIsNotReclaimed() async throws {
        let tempDirectory = try makeTemporaryDirectory()
        let sourceCard = Card(title: "cc-42", column: .todo, agent: .claude, worktreePath: tempDirectory.path)
        let cloneCard = Card(title: "cc-43", column: .todo, agent: .claude, worktreePath: tempDirectory.path)
        let board = Board(
            name: "Observed Activity",
            cards: [sourceCard, cloneCard],
            repositoryPath: "/tmp/repo",
            agent: .claude
        )
        let boardStore = BoardStore(initialBoards: [board], persistenceEnabled: false)
        boardStore.selectedBoardID = board.id
        boardStore.selectedCardID = sourceCard.id
        let hostStore = makeHostStore(boardStore: boardStore)
        var reclaimedCardIDs: [UUID] = []
        hostStore.configureBackgroundReclaimHookForTesting { cardID in
            reclaimedCardIDs.append(cardID)
        }
        defer {
            hostStore.configureBackgroundReclaimHookForTesting(nil)
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        hostStore.syncSelection(card: sourceCard, boardID: board.id)
        hostStore.prewarmWorkspaceForBackgroundLaunch(for: cloneCard, boardID: board.id)
        try markWorkspacePromptIdle(hostStore: hostStore, cardID: cloneCard.id)
        hostStore.cancelLaunchTaskForTesting(cardID: cloneCard.id)
        hostStore.markWorkspaceBackgroundPrewarmOnlyForTesting(cardID: cloneCard.id)

        let evaluationTime = Date()
        hostStore.setWorkspaceHiddenSinceForTesting(
            cardID: cloneCard.id,
            date: evaluationTime.addingTimeInterval(-301)
        )
        hostStore.setWorkspaceObservedAgentActivityForTesting(
            cardID: cloneCard.id,
            date: evaluationTime.addingTimeInterval(-30)
        )

        hostStore.evaluateHiddenWorkspaceReclaimForTesting(now: evaluationTime)

        #expect(reclaimedCardIDs.isEmpty)
    }

    @Test
    func backgroundPrewarmWorkspaceRunningCommandIsNotReclaimed() async throws {
        let tempDirectory = try makeTemporaryDirectory()
        let sourceCard = Card(title: "cc-42", column: .todo, agent: .claude, worktreePath: tempDirectory.path)
        let cloneCard = Card(title: "cc-43", column: .todo, agent: .claude, worktreePath: tempDirectory.path)
        let board = Board(
            name: "Command Running",
            cards: [sourceCard, cloneCard],
            repositoryPath: "/tmp/repo",
            agent: .claude
        )
        let boardStore = BoardStore(initialBoards: [board], persistenceEnabled: false)
        boardStore.selectedBoardID = board.id
        boardStore.selectedCardID = sourceCard.id
        let hostStore = makeHostStore(boardStore: boardStore)
        var reclaimedCardIDs: [UUID] = []
        hostStore.configureBackgroundReclaimHookForTesting { cardID in
            reclaimedCardIDs.append(cardID)
        }
        defer {
            hostStore.configureBackgroundReclaimHookForTesting(nil)
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        hostStore.syncSelection(card: sourceCard, boardID: board.id)
        hostStore.prewarmWorkspaceForBackgroundLaunch(for: cloneCard, boardID: board.id)
        try setWorkspaceShellActivityState(
            hostStore: hostStore,
            cardID: cloneCard.id,
            state: .commandRunning
        )
        hostStore.cancelLaunchTaskForTesting(cardID: cloneCard.id)
        hostStore.markWorkspaceBackgroundPrewarmOnlyForTesting(cardID: cloneCard.id)
        hostStore.setWorkspaceObservedAgentActivityForTesting(cardID: cloneCard.id, date: nil)

        let evaluationTime = Date()
        hostStore.setWorkspaceHiddenSinceForTesting(
            cardID: cloneCard.id,
            date: evaluationTime.addingTimeInterval(-301)
        )

        hostStore.evaluateHiddenWorkspaceReclaimForTesting(now: evaluationTime)

        #expect(reclaimedCardIDs.isEmpty)
    }

    private func makeBoardFixture(
        agent: Agent,
        worktreePath: String,
        column: Column = .todo
    ) -> (BoardStore, Board, Card) {
        let card = Card(title: "cc-42", column: column, agent: agent, worktreePath: worktreePath)
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

    private func makeHostStore(boardStore: BoardStore) -> CmuxHostStore {
        let hostStore = CmuxHostStore()
        boardStore.cmuxHost = hostStore
        hostStore.attach(boardStore: boardStore)
        return hostStore
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func markWorkspacePromptIdle(hostStore: CmuxHostStore, cardID: UUID) throws {
        try setWorkspaceShellActivityState(hostStore: hostStore, cardID: cardID, state: .promptIdle)
    }

    private func setWorkspaceShellActivityState(
        hostStore: CmuxHostStore,
        cardID: UUID,
        state: Workspace.PanelShellActivityState
    ) throws {
        let workspace = try #require(hostStore.workspace(for: cardID))
        let terminalPanel = try #require(workspace.focusedTerminalPanel)
        workspace.updatePanelShellActivityState(panelId: terminalPanel.id, state: state)
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

    private func launchRequestRecords(hostStore: CmuxHostStore, cardIDs: [UUID]) -> [LaunchRequestRecord] {
        cardIDs.compactMap { launchRequestRecord(hostStore: hostStore, cardID: $0) }
            .sorted { lhs, rhs in lhs.url.path < rhs.url.path }
    }

    private func launchRequestRecord(hostStore: CmuxHostStore, cardID: UUID) -> LaunchRequestRecord? {
        guard let workspace = hostStore.workspace(for: cardID),
              let startupEnvironment = try? ZellijSessionManager.shared.startupEnvironment(for: workspace.id),
              let launchFilePath = startupEnvironment["CMUX_ZELLIJ_LAUNCH_FILE"],
              let contents = try? String(contentsOfFile: launchFilePath, encoding: .utf8) else {
            return nil
        }

        let lines = contents
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2 else { return nil }

        let command = lines[1]
        guard command.contains("--dangerously-skip-permissions") || command == "codex" || command == "gemini" else {
            return nil
        }

        return LaunchRequestRecord(
            url: URL(fileURLWithPath: launchFilePath),
            token: lines[0],
            command: command
        )
    }

    private func promptFileURL(in directory: URL) -> URL {
        directory
            .appendingPathComponent(".zenban", isDirectory: true)
            .appendingPathComponent("claude-task.md", isDirectory: false)
    }

    private func expectedClaudeLaunchCommand(prompt: String? = nil) -> String {
        var command = "\(shellQuotedForTesting(bundledClaudePathForTesting() ?? "claude")) --dangerously-skip-permissions"
        if let prompt, !prompt.isEmpty {
            command += " \(shellQuotedForTesting(prompt))"
        }
        return command
    }

    private func bundledClaudePathForTesting() -> String? {
        Bundle.main.resourceURL?
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("claude", isDirectory: false)
            .path
    }

    private func shellQuotedForTesting(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }
}
