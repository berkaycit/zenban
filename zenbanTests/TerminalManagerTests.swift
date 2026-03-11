import Testing
@testable import zenban

private actor LaunchRecorder {
    private(set) var plans: [AgentLaunchPlan] = []
    private(set) var sessionIDs: [String] = []

    func record(plan: AgentLaunchPlan, sessionID: String) {
        plans.append(plan)
        sessionIDs.append(sessionID)
    }
}

private func makeGitRepository() throws -> String {
    let baseURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("zenban-terminal-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git", "init", "-q", baseURL.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        struct GitInitFailed: Error {}
        throw GitInitFailed()
    }

    return baseURL.path
}

@MainActor
struct TerminalManagerTests {
    @Test
    func gitBoardLaunchesFromRepositoryBeforeWorktreeReady() async throws {
        let terminalManager = TerminalManager()
        let store = BoardStore()
        let recorder = LaunchRecorder()
        let cardID = UUID()
        let boardID = UUID()
        let repositoryPath = try makeGitRepository()
        let card = Card(id: cardID, title: "Git Card", orderIndex: 0, agent: .claude)
        let board = Board(
            id: boardID,
            name: "Repo Board",
            cards: [card],
            repositoryPath: repositoryPath,
            agent: .claude
        )

        store.boards = [board]
        store.selectedBoardID = boardID
        store.selectedCardID = cardID
        terminalManager.boardStore = store

        terminalManager.autoLaunchDebounce = .milliseconds(20)
        terminalManager.launchExecutor = { plan, sessionID in
            await recorder.record(plan: plan, sessionID: sessionID)
            return true
        }

        _ = terminalManager.workspaceRecord(for: cardID, boardID: boardID, cardTitle: "Git Card")
        terminalManager.activateWorkspace(for: cardID)

        try? await Task.sleep(for: .milliseconds(80))

        let plans = await recorder.plans
        #expect(plans.count == 1)
        #expect(plans.first?.reason == .initialLaunch)
        #expect(plans.first?.workingDirectory == repositoryPath)
        #expect(plans.first?.interruptExisting == false)
    }

    @Test
    func worktreeReadyRelaunchesRepositoryLaunchInWorktree() async throws {
        let terminalManager = TerminalManager()
        let store = BoardStore()
        let recorder = LaunchRecorder()
        let cardID = UUID()
        let boardID = UUID()
        let repositoryPath = try makeGitRepository()
        let worktreePath = "/tmp/zenban-worktree-\(UUID().uuidString)"
        let card = Card(id: cardID, title: "Git Card", orderIndex: 0, agent: .claude)
        let board = Board(
            id: boardID,
            name: "Repo Board",
            cards: [card],
            repositoryPath: repositoryPath,
            agent: .claude
        )

        store.boards = [board]
        store.selectedBoardID = boardID
        store.selectedCardID = cardID
        terminalManager.boardStore = store

        terminalManager.autoLaunchDebounce = .milliseconds(20)
        terminalManager.launchExecutor = { plan, sessionID in
            await recorder.record(plan: plan, sessionID: sessionID)
            return true
        }

        _ = terminalManager.workspaceRecord(for: cardID, boardID: boardID, cardTitle: "Git Card")
        terminalManager.activateWorkspace(for: cardID)
        try? await Task.sleep(for: .milliseconds(80))

        terminalManager.worktreeReady(cardID: cardID, worktreePath: worktreePath, agent: .claude)
        try? await Task.sleep(for: .milliseconds(80))

        let plans = await recorder.plans
        #expect(plans.count == 2)
        #expect(plans.first?.reason == .initialLaunch)
        #expect(plans.first?.workingDirectory == repositoryPath)
        #expect(plans.last?.reason == .worktreeReady)
        #expect(plans.last?.workingDirectory == worktreePath)
        #expect(plans.last?.interruptExisting == true)
    }

    @Test
    func identicalWorktreeReadySignalDoesNotRelaunchTwice() async throws {
        let terminalManager = TerminalManager()
        let store = BoardStore()
        let recorder = LaunchRecorder()
        let cardID = UUID()
        let boardID = UUID()
        let repositoryPath = try makeGitRepository()
        let worktreePath = "/tmp/zenban-worktree-\(UUID().uuidString)"
        let card = Card(id: cardID, title: "Git Card", orderIndex: 0, agent: .claude)
        let board = Board(
            id: boardID,
            name: "Repo Board",
            cards: [card],
            repositoryPath: repositoryPath,
            agent: .claude
        )

        store.boards = [board]
        store.selectedBoardID = boardID
        store.selectedCardID = cardID
        terminalManager.boardStore = store

        terminalManager.autoLaunchDebounce = .milliseconds(20)
        terminalManager.launchExecutor = { plan, sessionID in
            await recorder.record(plan: plan, sessionID: sessionID)
            return true
        }

        _ = terminalManager.workspaceRecord(for: cardID, boardID: boardID, cardTitle: "Git Card")
        terminalManager.activateWorkspace(for: cardID)
        try? await Task.sleep(for: .milliseconds(80))

        terminalManager.worktreeReady(cardID: cardID, worktreePath: worktreePath, agent: .claude)
        try? await Task.sleep(for: .milliseconds(80))
        terminalManager.worktreeReady(cardID: cardID, worktreePath: worktreePath, agent: .claude)
        try? await Task.sleep(for: .milliseconds(80))

        let plans = await recorder.plans
        #expect(plans.count == 2)
        #expect(plans.last?.workingDirectory == worktreePath)
    }

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

    @Test
    func worktreeReadyQueuesInactivePendingLaunchWithoutScheduling() {
        let terminalManager = TerminalManager()
        let cardID = UUID()
        let boardID = UUID()
        _ = terminalManager.workspaceRecord(for: cardID, boardID: boardID, cardTitle: "Queued Card")

        terminalManager.worktreeReady(cardID: cardID, worktreePath: "/tmp/worktree-a", agent: .claude)

        let pending = terminalManager.pendingAgentLaunchSnapshot(for: cardID)
        #expect(pending?.cardID == cardID)
        #expect(pending?.agent == .claude)
        #expect(pending?.workingDirectory == "/tmp/worktree-a")
        #expect(pending?.reason == .worktreeReady)
        #expect(pending?.hasScheduledTask == false)
        #expect(!terminalManager.hasLaunchedAgent(for: cardID))
    }

    @Test
    func selectedCardLaunchesAfterDebounce() async {
        let terminalManager = TerminalManager()
        let recorder = LaunchRecorder()
        let cardID = UUID()
        let boardID = UUID()

        terminalManager.autoLaunchDebounce = .milliseconds(20)
        terminalManager.launchExecutor = { plan, sessionID in
            await recorder.record(plan: plan, sessionID: sessionID)
            return true
        }

        _ = terminalManager.workspaceRecord(for: cardID, boardID: boardID, cardTitle: "Launch Card")
        terminalManager.worktreeReady(cardID: cardID, worktreePath: "/tmp/worktree-b", agent: .claude)
        terminalManager.activateWorkspace(for: cardID)

        try? await Task.sleep(for: .milliseconds(80))

        let plans = await recorder.plans
        #expect(plans.count == 1)
        #expect(plans.first?.reason == .worktreeReady)
        #expect(plans.first?.command == "claude --dangerously-skip-permissions")
        #expect(terminalManager.pendingAgentLaunchSnapshot(for: cardID) == nil)
        #expect(terminalManager.hasLaunchedAgent(for: cardID))
    }

    @Test
    func rapidCardSwitchCancelsIntermediateLaunches() async {
        let terminalManager = TerminalManager()
        let recorder = LaunchRecorder()
        let boardID = UUID()
        let cardA = UUID()
        let cardB = UUID()
        let cardC = UUID()

        terminalManager.autoLaunchDebounce = .milliseconds(40)
        terminalManager.launchExecutor = { plan, sessionID in
            await recorder.record(plan: plan, sessionID: sessionID)
            return true
        }

        _ = terminalManager.workspaceRecord(for: cardA, boardID: boardID, cardTitle: "A")
        _ = terminalManager.workspaceRecord(for: cardB, boardID: boardID, cardTitle: "B")
        _ = terminalManager.workspaceRecord(for: cardC, boardID: boardID, cardTitle: "C")

        terminalManager.worktreeReady(cardID: cardA, worktreePath: "/tmp/worktree-c1", agent: .claude)
        terminalManager.worktreeReady(cardID: cardB, worktreePath: "/tmp/worktree-c2", agent: .claude)
        terminalManager.worktreeReady(cardID: cardC, worktreePath: "/tmp/worktree-c3", agent: .codex)

        terminalManager.activateWorkspace(for: cardA)
        terminalManager.startCardHandoff(from: cardA, to: cardB)
        terminalManager.startCardHandoff(from: cardB, to: cardC)

        try? await Task.sleep(for: .milliseconds(140))

        let plans = await recorder.plans
        #expect(plans.count == 1)
        #expect(plans.first?.environment["CMUX_WORKSPACE_ID"] == cardC.uuidString)
        #expect(plans.first?.command == "codex --yolo")
        #expect(!terminalManager.hasLaunchedAgent(for: cardA))
        #expect(!terminalManager.hasLaunchedAgent(for: cardB))
        #expect(terminalManager.hasLaunchedAgent(for: cardC))
    }

    @Test
    func detachedWorkspaceLaunchesImmediately() async {
        let terminalManager = TerminalManager()
        let recorder = LaunchRecorder()
        let cardID = UUID()
        let boardID = UUID()
        let detachedManager = TabManager(
            createsInitialWorkspace: false,
            keepsBootstrapWorkspaceWhenEmpty: false
        )

        terminalManager.autoLaunchDebounce = .seconds(1)
        terminalManager.launchExecutor = { plan, sessionID in
            await recorder.record(plan: plan, sessionID: sessionID)
            return true
        }

        _ = terminalManager.workspaceRecord(for: cardID, boardID: boardID, cardTitle: "Detached Launch")
        terminalManager.worktreeReady(cardID: cardID, worktreePath: "/tmp/worktree-detached", agent: .claude)
        _ = terminalManager.moveWorkspace(cardID: cardID, to: detachedManager, detachedWindowID: UUID())

        try? await Task.sleep(for: .milliseconds(80))

        let plans = await recorder.plans
        #expect(plans.count == 1)
        #expect(plans.first?.reason == .worktreeReady)
        #expect(terminalManager.pendingAgentLaunchSnapshot(for: cardID) == nil)
        #expect(terminalManager.hasLaunchedAgent(for: cardID))
    }

    @Test
    func switchAgentBypassesAutoLaunchGuard() async {
        let terminalManager = TerminalManager()
        let recorder = LaunchRecorder()
        let cardID = UUID()
        let boardID = UUID()

        terminalManager.autoLaunchDebounce = .milliseconds(20)
        terminalManager.launchExecutor = { plan, sessionID in
            await recorder.record(plan: plan, sessionID: sessionID)
            return true
        }

        _ = terminalManager.workspaceRecord(for: cardID, boardID: boardID, cardTitle: "Switch Card")
        terminalManager.worktreeReady(cardID: cardID, worktreePath: "/tmp/worktree-switch", agent: .claude)
        terminalManager.activateWorkspace(for: cardID)

        try? await Task.sleep(for: .milliseconds(80))
        terminalManager.switchAgent(for: cardID, to: .codex)
        try? await Task.sleep(for: .milliseconds(40))

        let plans = await recorder.plans
        #expect(plans.count == 2)
        #expect(plans.first?.command == "claude --dangerously-skip-permissions")
        #expect(plans.last?.reason == .agentSwitch)
        #expect(plans.last?.command == "codex --yolo")
    }

    @Test
    func launchedCardDoesNotAutoRelaunchOnReselect() async {
        let terminalManager = TerminalManager()
        let recorder = LaunchRecorder()
        let cardID = UUID()
        let boardID = UUID()

        terminalManager.autoLaunchDebounce = .milliseconds(20)
        terminalManager.launchExecutor = { plan, sessionID in
            await recorder.record(plan: plan, sessionID: sessionID)
            return true
        }

        _ = terminalManager.workspaceRecord(for: cardID, boardID: boardID, cardTitle: "Stable Card")
        terminalManager.worktreeReady(cardID: cardID, worktreePath: "/tmp/worktree-stable", agent: .claude)
        terminalManager.activateWorkspace(for: cardID)
        try? await Task.sleep(for: .milliseconds(80))

        terminalManager.deactivateWorkspace(for: cardID)
        terminalManager.activateWorkspace(for: cardID)
        terminalManager.worktreeReady(cardID: cardID, worktreePath: "/tmp/worktree-stable", agent: .claude)
        try? await Task.sleep(for: .milliseconds(80))

        let plans = await recorder.plans
        #expect(plans.count == 1)
        #expect(terminalManager.hasLaunchedAgent(for: cardID))
    }
}
