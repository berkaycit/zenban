import AppKit
import Bonsplit
import Observation

@MainActor
@Observable
final class CmuxHostStore {
    struct BrowserSurfaceContext {
        let panel: BrowserPanel
        let paneId: PaneID
    }

    let tabManager: TabManager
    let notificationStore: TerminalNotificationStore
    let sidebarState = SidebarState()
    let sidebarSelectionState = SidebarSelectionState()
    let primaryWindowId = UUID()

    private var cardToWorkspaceID: [UUID: UUID] = [:]
    private var workspaceToCardID: [UUID: UUID] = [:]
    private var workspaceToBoardID: [UUID: UUID] = [:]
    private var cardToBrowserPanelID: [UUID: UUID] = [:]
    private var launchSignatureByCardID: [UUID: String] = [:]

    @ObservationIgnored private weak var boardStore: BoardStore?
    @ObservationIgnored private weak var registeredWindow: NSWindow?
    @ObservationIgnored private var launchTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var didConfigureAppDelegate = false

    init() {
        UserDefaults.standard.set(true, forKey: WelcomeSettings.shownKey)
        notificationStore = TerminalNotificationStore.shared
        tabManager = TabManager()
    }

    func attach(boardStore: BoardStore) {
        self.boardStore = boardStore
        configureAppDelegateIfNeeded()
    }

    func registerMainWindow(_ window: NSWindow) {
        configureAppDelegateIfNeeded()
        guard registeredWindow !== window else { return }
        registeredWindow = window
        AppDelegate.shared?.registerMainWindow(
            window,
            windowId: primaryWindowId,
            tabManager: tabManager,
            sidebarState: sidebarState,
            sidebarSelectionState: sidebarSelectionState
        )
    }

    func syncSelection(card: Card?, boardID: UUID?) {
        configureAppDelegateIfNeeded()

        guard let card, let boardID else { return }
        guard canCreateWorkspace(for: card, boardID: boardID) else { return }

        let workspace = ensureWorkspace(for: card, boardID: boardID)
        workspace.requestBackgroundTerminalSurfaceStartIfNeeded()
        tabManager.requestBackgroundWorkspaceLoad(for: workspace.id)
        tabManager.selectedTabId = workspace.id
        updateTitle(for: card.id, title: card.title)
        updateAgentLaunch(for: card, boardID: boardID)
    }

    func workspace(for cardID: UUID) -> Workspace? {
        guard let workspaceID = cardToWorkspaceID[cardID] else { return nil }
        return tabManager.tabs.first(where: { $0.id == workspaceID })
    }

    func isWaitingForWorktree(for card: Card, boardID: UUID) -> Bool {
        guard let board = boardStore?.board(for: boardID),
              let repositoryPath = board.repositoryPath,
              GitService.isGitRepository(path: repositoryPath) else {
            return false
        }
        return card.worktreePath == nil
    }

    func updateTitle(for cardID: UUID, title: String) {
        workspace(for: cardID)?.setCustomTitle(title)
    }

    func updateAgentLaunch(for card: Card, boardID: UUID) {
        guard let workspace = workspace(for: card.id) else {
            launchSignatureByCardID.removeValue(forKey: card.id)
            launchTasks[card.id]?.cancel()
            launchTasks.removeValue(forKey: card.id)
            return
        }

        let agent = resolvedAgent(for: card, boardID: boardID)
        let signature = launchSignature(for: card, boardID: boardID, agent: agent)
        guard launchSignatureByCardID[card.id] != signature else { return }

        launchSignatureByCardID[card.id] = signature
        launchTasks[card.id]?.cancel()

        let cardID = card.id
        let workspaceID = workspace.id
        let command = launchCommand(for: agent)

        launchTasks[cardID] = Task { [weak self] in
            defer {
                self?.launchTasks.removeValue(forKey: cardID)
            }

            for _ in 0..<120 {
                guard !Task.isCancelled, let self else { return }
                guard let workspace = self.workspace(for: cardID), workspace.id == workspaceID else { return }

                self.tabManager.requestBackgroundWorkspaceLoad(for: workspaceID)
                workspace.requestBackgroundTerminalSurfaceStartIfNeeded()

                if let terminalPanel = self.launchTerminalPanel(in: workspace),
                   terminalPanel.surface.surface != nil {
                    terminalPanel.sendText("\(command)\r")
                    return
                }

                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    func ensureBrowserSurface(for card: Card, boardID: UUID, url: URL) {
        configureAppDelegateIfNeeded()

        guard canCreateWorkspace(for: card, boardID: boardID) else { return }

        let workspace = ensureWorkspace(for: card, boardID: boardID)
        workspace.requestBackgroundTerminalSurfaceStartIfNeeded()
        tabManager.requestBackgroundWorkspaceLoad(for: workspace.id)

        if let panelID = cardToBrowserPanelID[card.id],
           let panel = workspace.panels[panelID] as? BrowserPanel {
            panel.navigate(to: url)
            return
        }

        guard let paneID = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first,
              let panel = workspace.newBrowserSurface(inPane: paneID, url: url, focus: false) else {
            return
        }

        cardToBrowserPanelID[card.id] = panel.id
    }

    func browserSurface(for cardID: UUID) -> BrowserSurfaceContext? {
        guard let workspace = workspace(for: cardID),
              let panelID = cardToBrowserPanelID[cardID],
              let panel = workspace.panels[panelID] as? BrowserPanel,
              let paneID = workspace.paneId(forPanelId: panelID) else {
            return nil
        }

        return BrowserSurfaceContext(panel: panel, paneId: paneID)
    }

    func focusBrowserSurface(for cardID: UUID) {
        guard let workspace = workspace(for: cardID),
              let context = browserSurface(for: cardID) else {
            return
        }

        tabManager.selectedTabId = workspace.id
        workspace.focusPanel(context.panel.id)
    }

    func restoreTerminalFocus(for cardID: UUID) {
        guard let workspace = workspace(for: cardID),
              let terminalPanel = launchTerminalPanel(in: workspace) else {
            return
        }

        tabManager.selectedTabId = workspace.id
        workspace.focusPanel(terminalPanel.id)
    }

    func removeWorkspace(for cardID: UUID) {
        launchTasks[cardID]?.cancel()
        launchTasks.removeValue(forKey: cardID)
        launchSignatureByCardID.removeValue(forKey: cardID)
        cardToBrowserPanelID.removeValue(forKey: cardID)

        guard let workspaceID = cardToWorkspaceID.removeValue(forKey: cardID) else { return }

        workspaceToCardID.removeValue(forKey: workspaceID)
        workspaceToBoardID.removeValue(forKey: workspaceID)

        guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceID }) else { return }
        tabManager.closeWorkspace(workspace)
    }

    private func configureAppDelegateIfNeeded() {
        guard !didConfigureAppDelegate, let appDelegate = AppDelegate.shared else { return }

        appDelegate.configure(
            tabManager: tabManager,
            notificationStore: notificationStore,
            sidebarState: sidebarState
        )
        appDelegate.zenbanWorkspaceOpenHandler = { [weak self] workspaceID in
            Task { @MainActor [weak self] in
                self?.handleNotificationOpen(workspaceID: workspaceID)
            }
        }
        didConfigureAppDelegate = true
    }

    private func handleNotificationOpen(workspaceID: UUID) {
        guard let boardStore,
              let cardID = workspaceToCardID[workspaceID],
              let boardID = workspaceToBoardID[workspaceID] else {
            return
        }

        boardStore.selectCard(cardID, in: boardID)
    }

    @discardableResult
    private func ensureWorkspace(for card: Card, boardID: UUID) -> Workspace {
        if let workspace = workspace(for: card.id) {
            workspaceToBoardID[workspace.id] = boardID
            workspace.setCustomTitle(card.title)
            return workspace
        }

        let workspace = tabManager.addWorkspace(
            workingDirectory: workingDirectory(for: card, boardID: boardID),
            select: false,
            eagerLoadTerminal: true,
            autoWelcomeIfNeeded: false
        )
        workspace.setCustomTitle(card.title)

        cardToWorkspaceID[card.id] = workspace.id
        workspaceToCardID[workspace.id] = card.id
        workspaceToBoardID[workspace.id] = boardID

        return workspace
    }

    private func canCreateWorkspace(for card: Card, boardID: UUID) -> Bool {
        !isWaitingForWorktree(for: card, boardID: boardID)
    }

    private func workingDirectory(for card: Card, boardID: UUID) -> String? {
        if let cardPath = card.worktreePath, !cardPath.isEmpty {
            return cardPath
        }

        guard let board = boardStore?.board(for: boardID),
              let repositoryPath = board.repositoryPath,
              !repositoryPath.isEmpty else {
            return nil
        }

        return repositoryPath
    }

    private func resolvedAgent(for card: Card, boardID: UUID) -> Agent {
        if let agent = card.agent {
            return agent
        }
        return boardStore?.board(for: boardID)?.agent ?? .claude
    }

    private func launchSignature(for card: Card, boardID: UUID, agent: Agent) -> String {
        let directory = workingDirectory(for: card, boardID: boardID) ?? ""
        return "\(agent.runtimeID)|\(directory)"
    }

    private func launchCommand(for agent: Agent) -> String {
        switch agent {
        case .claude:
            let binaryURL = Bundle.main.resourceURL?
                .appendingPathComponent("bin", isDirectory: true)
                .appendingPathComponent("claude", isDirectory: false)
            return shellQuoted(binaryURL?.path ?? "claude")
        case .codex:
            return "codex"
        case .gemini:
            return "gemini"
        }
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private func launchTerminalPanel(in workspace: Workspace) -> TerminalPanel? {
        if let focusedTerminalPanel = workspace.focusedTerminalPanel {
            return focusedTerminalPanel
        }

        return workspace.panels.values
            .compactMap { $0 as? TerminalPanel }
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .first
    }
}
