import Foundation
import AppKit

@Observable
final class TerminalManager {
    enum TerminalManagerError: Error {
        case ghosttyUnavailable
    }

    private var terminalViews: [UUID: GhosttyTerminalView] = [:]
    private var scrollViews: [UUID: TerminalScrollView] = [:]
    private var accessOrder: [UUID] = []
    private let maxTerminals = 50
    private var agentLaunchedForCard: Set<UUID> = []
    private var pendingWorktreeReady: [UUID: (worktreePath: String, agent: Agent)] = [:]
    private var hibernatedCards: Set<UUID> = []
    /// Terminals pending cleanup - kept alive until surface is freed
    private var pendingCleanup: [UUID: GhosttyTerminalView] = [:]
    weak var boardStore: BoardStore?

    var isTerminalAvailable: Bool { Ghostty.App.shared?.readiness == .ready }

    init() {
        _ = Ghostty.App.shared
    }

    func terminalView(for cardID: UUID, boardID: UUID, cardTitle: String) async throws -> GhosttyTerminalView {
        // Check if terminal exists in active cache
        if let existingView = terminalViews[cardID] {
            existingView.cardTitle = cardTitle
            touch(cardID)
            return existingView
        }

        // Clear pending state if user switched back quickly
        pendingCleanup.removeValue(forKey: cardID)
        hibernatedCards.remove(cardID)

        let isRestoringTmuxSession = TmuxSessionManager.shared.isTmuxAvailable()
            && TmuxSessionManager.shared.sessionExistsSync(paneId: cardID.uuidString)
        if isRestoringTmuxSession {
            agentLaunchedForCard.insert(cardID)
        }

        let board = boardStore?.board(for: boardID)
        let card = board?.cards.first { $0.id == cardID }
        let agent = card?.agent ?? board?.agent

        // Determine initial working directory: worktree path > repository path > none
        let workingDirectory = card?.worktreePath ?? board?.repositoryPath
        let terminalView = try createTerminalView(cardID: cardID, boardID: boardID, cardTitle: cardTitle, workingDirectory: workingDirectory)

        // For git repos, agent is launched via worktreeReady (after worktree is created)
        // For non-git repos or empty boards, launch agent directly
        let isGitRepo = board?.repositoryPath.map { GitService.isGitRepository(path: $0) } ?? false
        let agentToLaunch = isGitRepo ? nil : agent

        // Note: Ghostty handles shell startup internally via surface creation
        // We just need to send the agent command when ready
        // Skip if agent was already launched (e.g., waking from hibernation or restoring tmux)
        if let agentCommand = agentToLaunch?.launchCommand,
           !agentLaunchedForCard.contains(cardID) {
            terminalView.sendWhenReady(agentCommand + "\n")
            terminalView.notifyAgentLaunched()
            agentLaunchedForCard.insert(cardID)
        }

        setTerminal(terminalView, for: cardID)

        // Check if there's a pending worktree ready call (only for git repos)
        if let pending = pendingWorktreeReady[cardID] {
            worktreeReady(cardID: cardID, worktreePath: pending.worktreePath, agent: pending.agent)
        }
        // For existing cards that already have worktreePath but agent not yet launched
        else if isGitRepo,
                let worktreePath = card?.worktreePath,
                let agent = agent,
                !agentLaunchedForCard.contains(cardID) {
            worktreeReady(cardID: cardID, worktreePath: worktreePath, agent: agent)
        }

        return terminalView
    }

    func scrollView(for cardID: UUID) -> TerminalScrollView? {
        guard let scrollView = scrollViews[cardID] else { return nil }
        touch(cardID)
        return scrollView
    }

    func setScrollView(_ scrollView: TerminalScrollView, for cardID: UUID) {
        scrollViews[cardID] = scrollView
        touch(cardID)
        evictIfNeeded()
    }

    func killSessionForCard(_ cardID: UUID) async {
        if let terminalView = terminalViews[cardID] {
            terminalView.terminate()
        }
        removeTerminal(for: cardID)
        agentLaunchedForCard.remove(cardID)
        pendingWorktreeReady.removeValue(forKey: cardID)
        hibernatedCards.remove(cardID)
        // Note: Do NOT remove from pendingCleanup here - the terminal must stay
        // alive temporarily to prevent dangling pointer crash from Ghostty callbacks

        // Kill associated tmux session
        await TmuxSessionManager.shared.killSession(paneId: cardID.uuidString)
    }

    func switchAgent(for cardID: UUID, to agent: Agent) {
        guard let terminalView = terminalViews[cardID] else { return }

        // Send Ctrl+C twice to exit agent
        terminalView.send(text: "\u{03}")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            terminalView.send(text: "\u{03}")
        }

        // Clear terminal
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            terminalView.send(text: "clear\n")
        }

        // Launch new agent
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            terminalView.send(text: agent.launchCommand + "\n")
            terminalView.notifyAgentLaunched()
        }
    }

    func worktreeReady(cardID: UUID, worktreePath: String, agent: Agent) {
        // Prevent duplicate agent launches
        guard !agentLaunchedForCard.contains(cardID) else {
            pendingWorktreeReady.removeValue(forKey: cardID)
            return
        }

        // If terminal doesn't exist yet, store for later
        guard let terminalView = terminalViews[cardID] else {
            pendingWorktreeReady[cardID] = (worktreePath, agent)
            return
        }

        agentLaunchedForCard.insert(cardID)
        pendingWorktreeReady.removeValue(forKey: cardID)

        let command = "cd \"\(worktreePath)\" && \(agent.launchCommand)\n"
        terminalView.sendWhenReady(command)
        terminalView.notifyAgentLaunched()
    }

    func terminateAllSessions() {
        for terminalView in terminalViews.values {
            terminalView.terminate()
        }
        terminalViews.removeAll()
        scrollViews.removeAll()
        accessOrder.removeAll()
        agentLaunchedForCard.removeAll()
        pendingWorktreeReady.removeAll()
        hibernatedCards.removeAll()
        pendingCleanup.removeAll()
    }

    func focusTerminal(for cardID: UUID) {
        guard let terminalView = terminalViews[cardID] else { return }
        terminalView.window?.makeFirstResponder(terminalView)
    }

    func isTerminalFocused(for cardID: UUID) -> Bool {
        guard let terminalView = terminalViews[cardID] else { return false }
        return terminalView.window?.firstResponder === terminalView
    }

    // MARK: - Hibernation

    /// Hibernate a terminal to save memory.
    /// The tmux session is preserved, allowing restoration when switching back.
    func hibernateTerminal(for cardID: UUID) {
        guard let terminalView = terminalViews[cardID] else { return }

        terminalView.terminate()
        cleanupTerminal(terminalView)
        scheduleCleanup(terminalView, for: cardID)

        terminalViews.removeValue(forKey: cardID)
        scrollViews.removeValue(forKey: cardID)
        accessOrder.removeAll { $0 == cardID }

        hibernatedCards.insert(cardID)
    }

    // MARK: - Private Helpers

    private func createTerminalView(cardID: UUID, boardID: UUID, cardTitle: String, workingDirectory: String?) throws -> GhosttyTerminalView {
        let frame = NSRect(x: 0, y: 0, width: 600, height: 400)

        guard let ghosttyAppWrapper = Ghostty.App.shared,
              let ghosttyApp = ghosttyAppWrapper.app else {
            throw TerminalManagerError.ghosttyUnavailable
        }

        let worktreePath = workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path
        let terminalView = GhosttyTerminalView(
            frame: frame,
            worktreePath: worktreePath,
            ghosttyApp: ghosttyApp,
            appWrapper: ghosttyAppWrapper,
            paneId: cardID.uuidString,
            command: nil
        )
        terminalView.cardID = cardID
        terminalView.boardID = boardID
        terminalView.cardTitle = cardTitle

        // Wire up task completion callbacks to NotificationService
        terminalView.onTaskCompleted = { cardID, boardID in
            NotificationService.shared.triggerTaskCompleted(cardID: cardID, boardID: boardID)
        }

        terminalView.onAgentResumed = { cardID, boardID in
            NotificationService.shared.triggerAgentResumed(cardID: cardID, boardID: boardID)
        }

        return terminalView
    }

    private func setTerminal(_ terminal: GhosttyTerminalView, for cardID: UUID) {
        terminalViews[cardID] = terminal
        touch(cardID)
        evictIfNeeded()
    }

    private func touch(_ cardID: UUID) {
        accessOrder.removeAll { $0 == cardID }
        accessOrder.append(cardID)
    }

    private func evictIfNeeded() {
        while terminalViews.count > maxTerminals, let oldest = accessOrder.first {
            accessOrder.removeFirst()
            if let terminal = terminalViews.removeValue(forKey: oldest) {
                terminal.terminate()
                cleanupTerminal(terminal)
                scheduleCleanup(terminal, for: oldest)
            }
            scrollViews.removeValue(forKey: oldest)
            if !TmuxSessionManager.shared.isTmuxAvailable() {
                agentLaunchedForCard.remove(oldest)
            }
        }
    }

    private func removeTerminal(for cardID: UUID) {
        if let terminal = terminalViews.removeValue(forKey: cardID) {
            cleanupTerminal(terminal)
            scheduleCleanup(terminal, for: cardID)
        }
        scrollViews.removeValue(forKey: cardID)
        accessOrder.removeAll { $0 == cardID }
    }

    /// Keep terminal alive temporarily to prevent dangling pointer crash.
    /// The Ghostty surface may still send callbacks before it's fully freed.
    private func scheduleCleanup(_ terminal: GhosttyTerminalView, for cardID: UUID) {
        pendingCleanup[cardID] = terminal
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.pendingCleanup.removeValue(forKey: cardID)
        }
    }

    private func cleanupTerminal(_ terminal: GhosttyTerminalView) {
        // Unregister from callback safety registry before invalidation
        Ghostty.App.unregisterTerminalView(terminal)

        terminal.onProcessExit = nil
        terminal.onTitleChange = nil
        terminal.onReady = nil
        terminal.onProgressReport = nil
        terminal.onTaskCompleted = nil
        terminal.onAgentResumed = nil
    }
}
