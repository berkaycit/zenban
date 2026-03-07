import Foundation
import AppKit

@Observable
final class TerminalManager {
    enum TerminalManagerError: Error {
        case ghosttyUnavailable
    }

    private var terminalViews: [UUID: GhosttyTerminalView] = [:]
    private var scrollViews: [UUID: TerminalScrollView] = [:]
    private var accessTimestamps: [UUID: CFAbsoluteTime] = [:]
    private let maxTerminals = 50
    private var agentLaunchedForCard: Set<UUID> = []
    private var pendingWorktreeReady: [UUID: (worktreePath: String, agent: Agent)] = [:]
    /// Terminals pending cleanup - kept alive until surface is freed
    private var pendingCleanup: [UUID: GhosttyTerminalView] = [:]
    /// Tracks scheduled cleanup tasks for proper cancellation
    private var cleanupTasks: [UUID: Task<Void, Never>] = [:]
    /// Cached scroll state for suspended terminals (position + cell size for restoration)
    private var cachedScrollStates: [UUID: (scrollbar: Ghostty.Action.Scrollbar, cellSize: NSSize)] = [:]
    weak var boardStore: BoardStore?

    var isTerminalAvailable: Bool { Ghostty.App.shared?.readiness == .ready }

    init() {
        _ = Ghostty.App.shared
    }

    deinit {
        // Cancel all pending cleanup tasks to prevent leaks
        for task in cleanupTasks.values {
            task.cancel()
        }
    }

    func terminalView(for cardID: UUID, boardID: UUID, cardTitle: String) async throws -> GhosttyTerminalView {
        // Check if terminal exists in active cache (may be suspended)
        if let existingView = terminalViews[cardID] {
            existingView.cardTitle = cardTitle
            touch(cardID)
            existingView.resume()
            return existingView
        }

        // Clear pending state if user switched back quickly
        pendingCleanup.removeValue(forKey: cardID)

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
        // Skip if agent was already launched (e.g., waking from hibernation)
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

    func cachedScrollState(for cardID: UUID) -> (scrollbar: Ghostty.Action.Scrollbar, cellSize: NSSize)? {
        cachedScrollStates[cardID]
    }

    func killSessionForCard(_ cardID: UUID) {
        if let terminalView = terminalViews[cardID] {
            terminalView.terminate()
        }
        removeTerminal(for: cardID)
        agentLaunchedForCard.remove(cardID)
        pendingWorktreeReady.removeValue(forKey: cardID)
        cachedScrollStates.removeValue(forKey: cardID)
    }

    func switchAgent(for cardID: UUID, to agent: Agent) {
        guard let terminalView = terminalViews[cardID] else { return }

        // Send Ctrl+C twice directly via terminal surface
        terminalView.send(text: "\u{03}")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak terminalView] in
            terminalView?.send(text: "\u{03}")
        }

        terminalView.notifyAgentExited()

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak terminalView] in
            terminalView?.send(text: agent.launchCommand + "\n")
            terminalView?.notifyAgentLaunched()
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
        // Cancel all pending cleanup tasks
        for task in cleanupTasks.values {
            task.cancel()
        }
        terminalViews.removeAll()
        scrollViews.removeAll()
        accessTimestamps.removeAll()
        agentLaunchedForCard.removeAll()
        pendingWorktreeReady.removeAll()
        pendingCleanup.removeAll()
        cleanupTasks.removeAll()
        cachedScrollStates.removeAll()
    }

    func focusTerminal(for cardID: UUID) {
        guard let terminalView = terminalViews[cardID] else { return }
        terminalView.requestFocus()
    }

    func isTerminalFocused(for cardID: UUID) -> Bool {
        guard let terminalView = terminalViews[cardID] else { return false }
        return terminalView.window?.firstResponder === terminalView
    }

    // MARK: - Suspension

    /// Suspend a terminal when its card is deselected.
    /// The terminal process stays alive; rendering is paused via occlusion.
    func suspendTerminal(for cardID: UUID) {
        guard let terminalView = terminalViews[cardID] else { return }

        // Cache scroll state for potential restoration
        if let scrollbar = terminalView.scrollbar, terminalView.cellSize.height > 0 {
            cachedScrollStates[cardID] = (scrollbar, terminalView.cellSize)
        }

        terminalView.suspend()
    }

    func suspendAllTerminals() {
        for (_, terminalView) in terminalViews {
            terminalView.suspend()
        }
    }

    func resumeAllTerminals() {
        for (_, terminalView) in terminalViews {
            terminalView.resume()
        }
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
        accessTimestamps[cardID] = CFAbsoluteTimeGetCurrent()
    }

    private func evictIfNeeded() {
        while terminalViews.count > maxTerminals {
            guard let oldest = accessTimestamps.min(by: { $0.value < $1.value })?.key else { break }
            accessTimestamps.removeValue(forKey: oldest)
            if let terminal = terminalViews.removeValue(forKey: oldest) {
                terminal.terminate()
                cleanupTerminal(terminal)
                scheduleCleanup(terminal, for: oldest)
            }
            scrollViews.removeValue(forKey: oldest)
            agentLaunchedForCard.remove(oldest)
        }
    }

    private func removeTerminal(for cardID: UUID) {
        if let terminal = terminalViews.removeValue(forKey: cardID) {
            cleanupTerminal(terminal)
            scheduleCleanup(terminal, for: cardID)
        }
        scrollViews.removeValue(forKey: cardID)
        accessTimestamps.removeValue(forKey: cardID)
    }

    /// Keep terminal alive temporarily to prevent dangling pointer crash.
    /// The Ghostty surface may still send callbacks before it's fully freed.
    private func scheduleCleanup(_ terminal: GhosttyTerminalView, for cardID: UUID) {
        // Cancel any existing cleanup task for this card
        cleanupTasks[cardID]?.cancel()

        pendingCleanup[cardID] = terminal
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.pendingCleanup.removeValue(forKey: cardID)
            self?.cleanupTasks.removeValue(forKey: cardID)
        }
        cleanupTasks[cardID] = task
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
