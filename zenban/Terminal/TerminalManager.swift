import Foundation
import SwiftTerm
import GhosttySwift
import AppKit

@Observable
final class TerminalManager {

    private var terminalViews: [UUID: GhosttyTerminalView] = [:]
    private var agentLaunchedForCard: Set<UUID> = []
    weak var boardStore: BoardStore?

    var isTerminalAvailable: Bool { GhosttyApp.shared.isReady }

    init() {
        // Initialize GhosttyApp singleton
        _ = GhosttyApp.shared
    }

    func terminalView(for cardID: UUID, boardID: UUID, cardTitle: String) async throws -> GhosttyTerminalView {
        if let existingView = terminalViews[cardID] {
            existingView.cardTitle = cardTitle
            return existingView
        }

        let board = boardStore?.board(for: boardID)
        let card = board?.cards.first { $0.id == cardID }
        let agent = card?.agent ?? board?.agent

        let terminalView = createTerminalView(cardID: cardID, boardID: boardID, cardTitle: cardTitle)

        // For boards with repo, agent is launched via worktreeReady (not here)
        let boardHasRepo = board?.repositoryPath != nil
        let agentToLaunch = boardHasRepo ? nil : agent

        // Note: Ghostty handles shell startup internally via surface creation
        // We just need to send the agent command when ready
        if let agentCommand = agentToLaunch?.launchCommand {
            terminalView.sendWhenReady(agentCommand + "\n")
            agentLaunchedForCard.insert(cardID)
        }

        terminalViews[cardID] = terminalView

        // For existing cards that already have worktreePath, launch agent now
        if let worktreePath = card?.worktreePath, let agent = agent {
            worktreeReady(cardID: cardID, worktreePath: worktreePath, agent: agent)
        }

        return terminalView
    }

    func killSessionForCard(_ cardID: UUID) async {
        if let terminalView = terminalViews.removeValue(forKey: cardID) {
            terminalView.terminate()
        }
        agentLaunchedForCard.remove(cardID)
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
        }
    }

    func worktreeReady(cardID: UUID, worktreePath: String, agent: Agent) {
        guard let terminalView = terminalViews[cardID],
              !agentLaunchedForCard.contains(cardID) else { return }

        agentLaunchedForCard.insert(cardID)

        // Send command when shell is ready (detected via terminal output)
        let command = "cd \"\(worktreePath)\" && \(agent.launchCommand)\n"
        terminalView.sendWhenReady(command)
    }

    func terminateAllSessions() {
        for terminalView in terminalViews.values {
            terminalView.terminate()
        }
        terminalViews.removeAll()
        agentLaunchedForCard.removeAll()
    }

    func focusTerminal(for cardID: UUID) {
        guard let terminalView = terminalViews[cardID] else { return }
        terminalView.window?.makeFirstResponder(terminalView)
    }

    func isTerminalFocused(for cardID: UUID) -> Bool {
        guard let terminalView = terminalViews[cardID] else { return false }
        return terminalView.window?.firstResponder === terminalView
    }

    // MARK: - Private Helpers

    private func createTerminalView(cardID: UUID, boardID: UUID, cardTitle: String) -> GhosttyTerminalView {
        let frame = NSRect(x: 0, y: 0, width: 600, height: 400)

        let terminalView = GhosttyTerminalView(frame: frame)
        terminalView.cardID = cardID
        terminalView.boardID = boardID
        terminalView.cardTitle = cardTitle

        return terminalView
    }
}
