import Foundation
import SwiftTerm
import AppKit

@Observable
final class TerminalManager {

    private var tmuxController: TmuxSessionController?
    private var activeTerminalView: LocalProcessTerminalView?
    private var currentCardID: UUID?
    private var initializationTask: Task<Void, Never>?
    private var currentLoadingTask: Task<LocalProcessTerminalView, Error>?

    var isLoading: Bool = false
    var error: String?
    var isTmuxAvailable: Bool = false

    init() {
        initializationTask = Task { [weak self] in
            await self?.initialize()
        }
    }

    deinit {
        initializationTask?.cancel()
    }

    private func initialize() async {
        do {
            tmuxController = try await TmuxSessionController()
            isTmuxAvailable = true
            error = nil
        } catch TmuxSessionController.TmuxError.tmuxNotInstalled {
            self.error = "tmux not found. Install with: brew install tmux"
            isTmuxAvailable = false
        } catch {
            self.error = "Terminal initialization failed: \(error.localizedDescription)"
            isTmuxAvailable = false
        }
    }

    // MARK: - Public API

    func terminalView(for cardID: UUID) async throws -> LocalProcessTerminalView {
        await initializationTask?.value

        if currentCardID == cardID, let existingView = activeTerminalView {
            return existingView
        }

        currentLoadingTask?.cancel()

        let task = Task<LocalProcessTerminalView, Error> {
            try await loadTerminal(for: cardID)
        }
        currentLoadingTask = task
        defer { currentLoadingTask = nil }

        return try await task.value
    }

    private func loadTerminal(for cardID: UUID) async throws -> LocalProcessTerminalView {
        isLoading = true
        error = nil

        defer {
            isLoading = false
        }

        // Properly detach current terminal
        detachCurrentTerminal()

        guard let controller = tmuxController else {
            throw TerminalError.tmuxNotAvailable
        }

        // Check if task was cancelled (card changed while loading)
        try Task.checkCancellation()

        let sessionName: String
        do {
            sessionName = try await controller.ensureSession(forCardID: cardID)
        } catch {
            self.error = "Failed to create terminal session"
            throw TerminalError.sessionCreationFailed
        }

        // Check again after async operation
        try Task.checkCancellation()

        let terminalView = createTerminalView()
        startTmuxAttach(terminalView: terminalView, sessionName: sessionName)

        activeTerminalView = terminalView
        currentCardID = cardID

        return terminalView
    }

    func detachCurrentTerminal() {
        guard let view = activeTerminalView else { return }

        // Send tmux detach command - this detaches the client but keeps the session running
        view.send(txt: "\u{02}d")  // Ctrl+B, d

        activeTerminalView = nil
        currentCardID = nil
    }

    func killSessionForCard(_ cardID: UUID) async {
        guard let controller = tmuxController else { return }

        // If this is the active card, detach first
        if currentCardID == cardID {
            detachCurrentTerminal()
        }

        let sessionName = "zenban_card_\(cardID.uuidString)"
        do {
            try await controller.killSession(sessionName)
        } catch {
            // Session might not exist, ignore error
        }
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

    private func startTmuxAttach(terminalView: LocalProcessTerminalView, sessionName: String) {
        guard let tmuxPath = TmuxSessionController.findTmuxPath() else { return }

        terminalView.startProcess(
            executable: tmuxPath,
            args: ["attach", "-t", sessionName],
            environment: nil,
            execName: nil
        )
    }
}

enum TerminalError: LocalizedError {
    case tmuxNotAvailable
    case sessionCreationFailed

    var errorDescription: String? {
        switch self {
        case .tmuxNotAvailable:
            return "tmux is not available"
        case .sessionCreationFailed:
            return "Failed to create terminal session"
        }
    }
}
