import AppKit
import Foundation

@MainActor
@Observable
final class TerminalManager {
    struct WorkspaceRecord {
        let cardID: UUID
        let boardID: UUID
        let tabManager: TabManager
        let workspace: Workspace
        let primaryTerminalPanelID: UUID
        var cardTitle: String
        var workingDirectory: String?
    }

    enum TerminalManagerError: Error {
        case workspaceUnavailable
    }

    private var records: [UUID: WorkspaceRecord] = [:]
    private var agentLaunchedForCard: Set<UUID> = []
    private var pendingWorktreeReady: [UUID: (worktreePath: String, agent: Agent)] = [:]

    weak var boardStore: BoardStore?

    var isTerminalAvailable: Bool {
        GhosttyApp.shared.app != nil
    }

    init() {
        _ = GhosttyApp.shared
    }

    func workspaceRecord(for cardID: UUID, boardID: UUID, cardTitle: String) -> WorkspaceRecord {
        if var record = records[cardID] {
            if record.cardTitle != cardTitle {
                record.cardTitle = cardTitle
                record.workspace.setCustomTitle(cardTitle)
                records[cardID] = record
            }
            return record
        }

        let board = boardStore?.board(for: boardID)
        let card = board?.cards.first { $0.id == cardID }
        let agent = card?.agent ?? board?.agent
        let workingDirectory = card?.worktreePath ?? board?.repositoryPath
        let tabManager = TabManager(
            initialWorkingDirectory: workingDirectory,
            initialWorkspaceID: cardID,
            initialWorkspaceTitle: cardTitle
        )

        guard let workspace = tabManager.tabs.first(where: { $0.id == cardID }) else {
            fatalError("cmux parity workspace was not created for card \(cardID)")
        }

        workspace.setCustomTitle(cardTitle)

        let primaryTerminalPanelID =
            workspace.focusedTerminalPanel?.id
            ?? workspace.focusedPanelId
            ?? workspace.panels.keys.first
            ?? UUID()

        var record = WorkspaceRecord(
            cardID: cardID,
            boardID: boardID,
            tabManager: tabManager,
            workspace: workspace,
            primaryTerminalPanelID: primaryTerminalPanelID,
            cardTitle: cardTitle,
            workingDirectory: workingDirectory
        )
        records[cardID] = record
        AppDelegate.shared?.register(tabManager: tabManager, for: cardID, boardID: boardID)

        let isGitRepo = board?.repositoryPath.map { GitService.isGitRepository(path: $0) } ?? false
        if let agent, !isGitRepo {
            launchAgentIfNeeded(agent, in: record)
        } else if let pending = pendingWorktreeReady[cardID] {
            worktreeReady(cardID: cardID, worktreePath: pending.worktreePath, agent: pending.agent)
        } else if isGitRepo,
                  let worktreePath = card?.worktreePath,
                  let agent {
            worktreeReady(cardID: cardID, worktreePath: worktreePath, agent: agent)
        }

        if let updated = records[cardID] {
            record = updated
        }
        return record
    }

    func activateWorkspace(for cardID: UUID) {
        guard records[cardID] != nil else { return }
        AppDelegate.shared?.activateCard(cardID)
    }

    func deactivateWorkspace(for cardID: UUID) {
        AppDelegate.shared?.deactivateCard(cardID)
    }

    func killSessionForCard(_ cardID: UUID) {
        resetWorkspace(for: cardID)
        agentLaunchedForCard.remove(cardID)
        pendingWorktreeReady.removeValue(forKey: cardID)
    }

    func resetWorkspace(for cardID: UUID) {
        guard let record = records.removeValue(forKey: cardID) else { return }
        AppDelegate.shared?.unregister(cardID: cardID)
        record.workspace.teardownAllPanels()
    }

    func switchAgent(for cardID: UUID, to agent: Agent) {
        guard let panel = targetTerminalPanel(for: cardID) else { return }
        panel.sendText("\u{03}")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            panel.sendText("\u{03}")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            panel.sendText(agent.launchCommand + "\n")
        }
    }

    func worktreeReady(cardID: UUID, worktreePath: String, agent: Agent) {
        guard !agentLaunchedForCard.contains(cardID) else {
            pendingWorktreeReady.removeValue(forKey: cardID)
            return
        }

        guard let panel = targetTerminalPanel(for: cardID) else {
            pendingWorktreeReady[cardID] = (worktreePath, agent)
            return
        }

        pendingWorktreeReady.removeValue(forKey: cardID)
        agentLaunchedForCard.insert(cardID)
        panel.sendText("cd \"\(worktreePath)\" && \(agent.launchCommand)\n")
    }

    func terminateAllSessions() {
        let cardIDs = Array(records.keys)
        for cardID in cardIDs {
            resetWorkspace(for: cardID)
        }
        agentLaunchedForCard.removeAll()
        pendingWorktreeReady.removeAll()
    }

    func suspendAllTerminals() {}

    func resumeAllTerminals() {}

    func focusTerminal(for cardID: UUID) {
        activateWorkspace(for: cardID)
        targetTerminalPanel(for: cardID)?.focus()
    }

    func isTerminalFocused(for cardID: UUID) -> Bool {
        targetTerminalPanel(for: cardID)?.hostedView.isSurfaceViewFirstResponder() ?? false
    }

    func record(forWorkspaceID workspaceID: UUID) -> WorkspaceRecord? {
        records[workspaceID]
    }

    func allRecords() -> [WorkspaceRecord] {
        Array(records.values)
    }

    private func targetTerminalPanel(for cardID: UUID) -> TerminalPanel? {
        guard let record = records[cardID] else { return nil }
        if let focused = record.workspace.focusedTerminalPanel {
            return focused
        }
        if let primary = record.workspace.terminalPanel(for: record.primaryTerminalPanelID) {
            return primary
        }
        for panel in record.workspace.panels.values {
            if let terminalPanel = panel as? TerminalPanel {
                return terminalPanel
            }
        }
        return nil
    }

    private func launchAgentIfNeeded(_ agent: Agent, in record: WorkspaceRecord) {
        guard !agentLaunchedForCard.contains(record.cardID) else { return }
        guard let panel = targetTerminalPanel(for: record.cardID) else { return }
        agentLaunchedForCard.insert(record.cardID)
        panel.sendText(agent.launchCommand + "\n")
    }
}
