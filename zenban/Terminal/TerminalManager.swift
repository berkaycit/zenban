import Foundation
import SwiftTerm
import AppKit

@Observable
final class TerminalManager {

    private var terminalViews: [UUID: ZenbanTerminalView] = [:]
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
        startShell(terminalView: terminalView, directory: startDirectory(for: boardID), agentCommand: agent?.launchCommand)

        terminalViews[cardID] = terminalView
        return terminalView
    }

    func killSessionForCard(_ cardID: UUID) async {
        if let terminalView = terminalViews.removeValue(forKey: cardID) {
            terminalView.process.terminate()
        }
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

    func terminateAllSessions() {
        for terminalView in terminalViews.values {
            terminalView.process.terminate()
        }
        terminalViews.removeAll()
    }

    // MARK: - Private Helpers

    private func createTerminalView(cardID: UUID, boardID: UUID, cardTitle: String) -> ZenbanTerminalView {
        let config = TerminalConfiguration()
        let frame = NSRect(x: 0, y: 0, width: 600, height: 400)

        let terminalView = ZenbanTerminalView(frame: frame)
        terminalView.cardID = cardID
        terminalView.boardID = boardID
        terminalView.cardTitle = cardTitle

        terminalView.font = config.font
        terminalView.nativeBackgroundColor = config.backgroundColor
        terminalView.nativeForegroundColor = config.foregroundColor

        return terminalView
    }

    private func startShell(terminalView: LocalProcessTerminalView, directory: String?, agentCommand: String?) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        terminalView.startProcess(
            executable: shell,
            args: ["--login"],
            environment: nil,
            execName: nil,
            currentDirectory: directory
        )

        if let command = agentCommand {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                terminalView.send(txt: command + "\n")
            }
        }
    }

    private func startDirectory(for boardID: UUID) -> String? {
        if let board = boardStore?.board(for: boardID),
           let repoPath = board.repositoryPath,
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
