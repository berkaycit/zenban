import Foundation
import SwiftTerm
import AppKit

@Observable
final class TerminalManager {

    private var terminalViews: [UUID: ZenbanTerminalView] = [:]

    var isTerminalAvailable: Bool { true }

    func terminalView(for cardID: UUID, boardID: UUID, cardTitle: String) async throws -> ZenbanTerminalView {
        if let existingView = terminalViews[cardID] {
            existingView.cardTitle = cardTitle
            return existingView
        }

        let terminalView = createTerminalView(cardID: cardID, boardID: boardID, cardTitle: cardTitle)
        startShell(terminalView: terminalView)

        terminalViews[cardID] = terminalView
        return terminalView
    }

    func killSessionForCard(_ cardID: UUID) async {
        if let terminalView = terminalViews.removeValue(forKey: cardID) {
            terminalView.process.terminate()
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

    private func startShell(terminalView: LocalProcessTerminalView) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let startDirectory = defaultStartDirectory()

        terminalView.startProcess(
            executable: shell,
            args: ["--login"],
            environment: nil,
            execName: nil,
            currentDirectory: startDirectory
        )
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
