import Foundation
import Testing
@testable import zenban

@MainActor
struct CmuxHostStoreLaunchTests {
    private enum WaitError: Error {
        case timedOut
    }

    @Test
    func claudeLaunchSendsFlagOnlyCommandOnlyOncePerWorkspace() async throws {
        let tempDirectory = try makeTemporaryDirectory()
        let (boardStore, board, card) = makeBoardFixture(agent: .claude, worktreePath: tempDirectory.path)
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

        #expect(commands == [expectedClaudeLaunchCommand()])
        #expect(!FileManager.default.fileExists(atPath: promptFileURL(in: tempDirectory).path))

        hostStore.syncSelection(card: card, boardID: board.id)
        try await Task.sleep(for: .milliseconds(500))
        #expect(commands.count == 1)
    }

    @Test
    func claudeLaunchRelaunchesWhenWorkspaceIsRecreated() async throws {
        let tempDirectory = try makeTemporaryDirectory()
        let (boardStore, board, card) = makeBoardFixture(agent: .claude, worktreePath: tempDirectory.path)
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

        hostStore.removeWorkspace(for: card.id)

        var renamedCard = card
        renamedCard.title = "cc-84"
        hostStore.syncSelection(card: renamedCard, boardID: board.id)
        try markWorkspacePromptIdle(hostStore: hostStore, cardID: card.id)
        try await waitUntil { commands.count == 2 }

        #expect(commands == [expectedClaudeLaunchCommand(), expectedClaudeLaunchCommand()])
        #expect(!FileManager.default.fileExists(atPath: promptFileURL(in: tempDirectory).path))
    }

    @Test
    func changingAgentFromCodexToClaudeRelaunchesWithClaudeCommand() async throws {
        let tempDirectory = try makeTemporaryDirectory()
        let (boardStore, board, card) = makeBoardFixture(agent: .codex, worktreePath: tempDirectory.path)
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
        #expect(commands[0] == "codex")
        #expect(!FileManager.default.fileExists(atPath: promptFileURL(in: tempDirectory).path))

        var claudeCard = card
        claudeCard.agent = .claude
        hostStore.updateAgentLaunch(for: claudeCard, boardID: board.id)
        try markWorkspacePromptIdle(hostStore: hostStore, cardID: card.id)
        try await waitUntil { commands.count == 2 }

        #expect(commands[1] == expectedClaudeLaunchCommand())
        #expect(!FileManager.default.fileExists(atPath: promptFileURL(in: tempDirectory).path))
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
        var commands: [String] = []
        hostStore.configureClaudeLaunchHooksForTesting(launchCommandHandler: { _, command in
            commands.append(command)
        })
        defer {
            hostStore.resetClaudeLaunchHooksForTesting()
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        hostStore.syncSelection(card: card, boardID: board.id)
        try await Task.sleep(for: .milliseconds(500))
        #expect(hostStore.workspace(for: card.id) == nil)
        #expect(commands.isEmpty)

        hostStore.openTerminal(for: card, boardID: board.id)
        try markWorkspacePromptIdle(hostStore: hostStore, cardID: card.id)
        try await waitUntil { commands.count == 1 }

        #expect(commands == [expectedClaudeLaunchCommand()])
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
        let workspace = try #require(hostStore.workspace(for: cardID))
        let terminalPanel = try #require(workspace.focusedTerminalPanel)
        workspace.updatePanelShellActivityState(panelId: terminalPanel.id, state: .promptIdle)
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

    private func promptFileURL(in directory: URL) -> URL {
        directory
            .appendingPathComponent(".zenban", isDirectory: true)
            .appendingPathComponent("claude-task.md", isDirectory: false)
    }

    private func expectedClaudeLaunchCommand() -> String {
        "\(shellQuotedForTesting(bundledClaudePathForTesting() ?? "claude")) --dangerously-skip-permissions"
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
