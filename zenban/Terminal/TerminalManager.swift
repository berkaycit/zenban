import Foundation
import SwiftTerm
import AppKit

@Observable
final class TerminalManager {

    private var terminalViews: [UUID: ZenbanTerminalView] = [:]
    private var agentLaunchedForCard: Set<UUID> = []
    weak var boardStore: BoardStore?

    var isTerminalAvailable: Bool { true }

    func terminalView(for cardID: UUID, boardID: UUID, cardTitle: String) async throws -> ZenbanTerminalView {
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

        startShell(terminalView: terminalView, directory: startDirectory(for: cardID, boardID: boardID), agentCommand: agentToLaunch?.launchCommand)

        if agentToLaunch != nil {
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
            terminalView.process.terminate()
        }
        agentLaunchedForCard.remove(cardID)
    }

    func switchAgent(for cardID: UUID, to agent: Agent) {
        guard let terminalView = terminalViews[cardID] else { return }

        // Send Ctrl+C twice to exit agent
        terminalView.send(txt: "\u{03}")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            terminalView.send(txt: "\u{03}")
        }

        // Clear terminal
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            terminalView.send(txt: "clear\n")
        }

        // Launch new agent
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            terminalView.send(txt: agent.launchCommand + "\n")
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
            terminalView.process.terminate()
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

    private func createTerminalView(cardID: UUID, boardID: UUID, cardTitle: String) -> ZenbanTerminalView {
        let frame = NSRect(x: 0, y: 0, width: 600, height: 400)

        let terminalView = ZenbanTerminalView(frame: frame)
        terminalView.cardID = cardID
        terminalView.boardID = boardID
        terminalView.cardTitle = cardTitle

        // Font
        terminalView.font = TerminalConfiguration.font

        // Colors
        terminalView.nativeBackgroundColor = TerminalConfiguration.backgroundColor
        terminalView.nativeForegroundColor = TerminalConfiguration.foregroundColor
        terminalView.caretColor = TerminalConfiguration.cursorColor
        terminalView.selectedTextBackgroundColor = TerminalConfiguration.selectionColor

        // ANSI color palette
        terminalView.installColors(TerminalConfiguration.ansiColors)

        return terminalView
    }

    private func startShell(terminalView: ZenbanTerminalView, directory: String?, agentCommand: String?) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        terminalView.startProcess(
            executable: shell,
            args: ["--login"],
            environment: nil,
            execName: nil,
            currentDirectory: directory
        )

        if let command = agentCommand {
            terminalView.sendWhenReady(command + "\n")
        }
    }

    private func startDirectory(for cardID: UUID, boardID: UUID) -> String? {
        guard let board = boardStore?.board(for: boardID) else {
            return defaultStartDirectory()
        }

        if let card = board.cards.first(where: { $0.id == cardID }),
           let worktreePath = card.worktreePath,
           FileManager.default.fileExists(atPath: worktreePath) {
            return worktreePath
        }

        if let repoPath = board.repositoryPath,
           FileManager.default.fileExists(atPath: repoPath) {
            return repoPath
        }

        return defaultStartDirectory()
    }

    private func defaultStartDirectory() -> String? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path

        for folder in ["Documents", "Desktop"] {
            let path = home + "/" + folder
            if fileManager.isReadableFile(atPath: path) {
                return path
            }
        }
        return nil
    }
}
