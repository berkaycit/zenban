import Foundation
import SwiftTerm
import AppKit

@Observable
final class TerminalManager {

    private var terminalViews: [UUID: LocalProcessTerminalView] = [:]

    var isTerminalAvailable: Bool { true }

    func terminalView(for cardID: UUID) async throws -> LocalProcessTerminalView {
        if let existingView = terminalViews[cardID] {
            return existingView
        }

        let terminalView = createTerminalView()
        startShell(terminalView: terminalView)

        terminalViews[cardID] = terminalView
        return terminalView
    }

    func killSessionForCard(_ cardID: UUID) async {
        terminalViews.removeValue(forKey: cardID)
    }

    // MARK: - Private Helpers

    private func createTerminalView() -> LocalProcessTerminalView {
        let config = TerminalConfiguration()
        let frame = NSRect(x: 0, y: 0, width: 600, height: 400)

        let terminalView = LocalProcessTerminalView(frame: frame)

        terminalView.font = config.font
        terminalView.nativeBackgroundColor = config.backgroundColor
        terminalView.nativeForegroundColor = config.foregroundColor

        return terminalView
    }

    private func startShell(terminalView: LocalProcessTerminalView) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        terminalView.startProcess(
            executable: shell,
            args: ["--login"],
            environment: nil,
            execName: nil
        )
    }
}
