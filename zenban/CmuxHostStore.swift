import AppKit
import Bonsplit
import Combine
import Foundation
import Observation

@MainActor
@Observable
final class CmuxHostStore {
    struct BrowserSurfaceContext {
        let panel: BrowserPanel
        let paneId: PaneID
    }

    private struct SelectedCardContext: Equatable {
        let cardID: UUID
        let boardID: UUID
    }

    private struct SelectedCardFocusedPanelCloseContext {
        let workspace: Workspace
        let panelID: UUID
        let panelType: PanelType
        let matchingPanelCount: Int
    }

    private enum WorkspaceResidency {
        case interactive
        case backgroundPrewarmOnly
    }

    private struct WorkspaceRuntimeState {
        var residency: WorkspaceResidency
        var hiddenSince: Date?
        var lastObservedAgentActivityAt: Date?
    }

    private struct PendingLaunchRequest {
        var token: String
        let command: String
        let targetSignature: String
        let shouldConsumePendingPrompt: Bool
        var didSendVisibleNudge: Bool
        var needsRequeue: Bool
        var retryCount: Int
        var lastQueuedAt: Date?
    }

    let tabManager: TabManager
    let notificationStore: TerminalNotificationStore
    let sidebarState = SidebarState()
    let sidebarSelectionState = SidebarSelectionState()
    let primaryWindowId = UUID()

    private var cardToWorkspaceID: [UUID: UUID] = [:]
    private var workspaceToCardID: [UUID: UUID] = [:]
    private var workspaceToBoardID: [UUID: UUID] = [:]
    private var cardToBrowserWorkspaceID: [UUID: UUID] = [:]
    private var cardToBrowserPanelID: [UUID: UUID] = [:]
    private var launchSignatureByCardID: [UUID: String] = [:]
    private var pendingLaunchByCardID: [UUID: PendingLaunchRequest] = [:]
    private var cachedClaudeSummaryByCardID: [UUID: String] = [:]
    private var workspaceRuntimeStateByID: [UUID: WorkspaceRuntimeState] = [:]
    private var workspaceStatusObservationGeneration: UInt64 = 0
    private let zellijSessionManager = ZellijSessionManager.shared

    @ObservationIgnored private weak var boardStore: BoardStore?
    @ObservationIgnored private weak var registeredWindow: NSWindow?
    @ObservationIgnored private var launchTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var hiddenWorkspaceReclaimTask: Task<Void, Never>?
    @ObservationIgnored private var hiddenWorkspaceDetachTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var workspaceStatusSubscriptions: [UUID: AnyCancellable] = [:]
    @ObservationIgnored private var didConfigureAppDelegate = false
    @ObservationIgnored private var hiddenWorkspaceReclaimTimeout: TimeInterval = 5 * 60
    @ObservationIgnored private var hiddenWorkspaceReclaimPollingInterval: Duration = .seconds(30)
    @ObservationIgnored private var hiddenWorkspaceDetachDelay: Duration = .seconds(3)
    @ObservationIgnored private var pendingLaunchAckTimeout: TimeInterval = 5
#if DEBUG
    @ObservationIgnored private var launchCommandHandlerForTesting: ((UUID, String) -> Void)?
    @ObservationIgnored private var backgroundReclaimHandlerForTesting: ((UUID) -> Void)?
#endif
    @ObservationIgnored private var selectedCardContext: SelectedCardContext?

    private enum WorkspaceLaunchMode {
        case selectionSync
        case interactiveOpen
        case backgroundPrewarm
    }

    init() {
        UserDefaults.standard.set(true, forKey: WelcomeSettings.shownKey)
        notificationStore = TerminalNotificationStore.shared
        tabManager = TabManager()
        startHiddenWorkspaceReclaimLoop()
    }

    deinit {
        hiddenWorkspaceReclaimTask?.cancel()
        hiddenWorkspaceDetachTasks.values.forEach { $0.cancel() }
    }

    func attach(boardStore: BoardStore) {
        self.boardStore = boardStore
        configureAppDelegateIfNeeded()
        notificationStore.observer = self
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
        launchWorkspace(for: card, boardID: boardID, mode: .selectionSync)
    }

    func openTerminal(for card: Card, boardID: UUID) {
        launchWorkspace(for: card, boardID: boardID, mode: .interactiveOpen)
    }

    func prewarmWorkspaceForBackgroundLaunch(for card: Card, boardID: UUID) {
        launchWorkspace(for: card, boardID: boardID, mode: .backgroundPrewarm)
    }

    func workspace(for cardID: UUID) -> Workspace? {
        guard let workspaceID = cardToWorkspaceID[cardID] else { return nil }
        return workspace(forID: workspaceID)
    }

    @discardableResult
    func handleTypeScopedCloseShortcut(forSelectedCardID cardID: UUID?) -> Bool {
        guard let context = selectedCardFocusedPanelCloseContext(for: cardID) else {
            return false
        }

        guard context.matchingPanelCount > 1 else {
            return true
        }

        owningTabManager(for: context.workspace)
            .closePanelWithConfirmation(tabId: context.workspace.id, surfaceId: context.panelID)
        return true
    }

    @discardableResult
    func handleGhosttyTerminalFullscreenToggle(workspaceID: UUID, panelID: UUID) -> Bool {
        guard let boardStore,
              let workspace = workspace(forID: workspaceID),
              workspace.focusedPanelId == panelID,
              workspace.panels[panelID] is TerminalPanel,
              let cardID = workspaceToCardID[workspaceID],
              let boardID = workspaceToBoardID[workspaceID] else {
            return false
        }

        return boardStore.toggleTerminalFullscreen(for: cardID, in: boardID)
    }

    func hasUnreadTerminalNotification(for cardID: UUID) -> Bool {
        guard let workspace = workspace(for: cardID),
              let terminalPanel = launchTerminalPanel(in: workspace) else {
            return false
        }

        return notificationStore.hasUnreadNotification(
            forTabId: workspace.id,
            surfaceId: terminalPanel.id
        )
    }

    func agentSummary(for cardID: UUID) -> String? {
        guard resolvedAgent(forCardID: cardID) == .claude else { return nil }
        _ = workspaceStatusObservationGeneration

        if let workspace = workspace(for: cardID),
           let summary = meaningfulClaudeStatus(in: workspace) {
            return summary
        }

        if let workspace = workspace(for: cardID),
           let summary = meaningfulNotificationBody(for: workspace.id) {
            return summary
        }

        if let summary = cachedClaudeSummaryByCardID[cardID] {
            return summary
        }

        return boardStore?.card(id: cardID)?.agentSummary
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
            clearLaunchTracking(for: card.id)
            return
        }
        guard zellijSessionManager.isManagedWorkspace(workspace.id) else {
            clearLaunchTracking(for: card.id)
            return
        }

        let agent = resolvedAgent(for: card, boardID: boardID)
        let signature = launchSignature(for: card, boardID: boardID, agent: agent)
        if launchSignatureByCardID[card.id] == signature {
            if let pendingLaunch = pendingLaunchByCardID[card.id] {
                if pendingLaunch.needsRequeue {
                    queuePendingLaunchRequest(
                        pendingLaunch,
                        cardID: card.id,
                        workspaceID: workspace.id
                    )
                }
                resumePendingLaunchIfNeeded(cardID: card.id, workspaceID: workspace.id)
            }
            return
        }

        launchSignatureByCardID[card.id] = signature
        launchTasks[card.id]?.cancel()
        launchTasks.removeValue(forKey: card.id)

        let cardID = card.id
        let workspaceID = workspace.id
        let normalizedPrompt = normalizedPendingLaunchPrompt(for: card, agent: agent)
        let command = launchCommand(for: agent, pendingPrompt: normalizedPrompt)
        let postLaunchSignature = launchSignature(
            for: card,
            boardID: boardID,
            agent: agent,
            pendingPrompt: nil
        )

        let pendingLaunch = PendingLaunchRequest(
            token: newLaunchToken(),
            command: command,
            targetSignature: postLaunchSignature,
            shouldConsumePendingPrompt: normalizedPrompt != nil,
            didSendVisibleNudge: false,
            needsRequeue: true,
            retryCount: 0,
            lastQueuedAt: nil
        )
        pendingLaunchByCardID[cardID] = pendingLaunch
        queuePendingLaunchRequest(
            pendingLaunch,
            cardID: cardID,
            workspaceID: workspaceID
        )
        resumePendingLaunchIfNeeded(cardID: cardID, workspaceID: workspaceID)
    }

    func ensureBrowserSurface(for card: Card, boardID: UUID, url: URL) {
        configureAppDelegateIfNeeded()

        guard canCreateWorkspace(for: card, boardID: boardID) else { return }

        let workspace = ensureBrowserWorkspace(for: card, boardID: boardID)

        if let panelID = cardToBrowserPanelID[card.id],
           let panel = workspace.panels[panelID] as? BrowserPanel {
            panel.navigate(to: url)
            return
        }

        guard let paneID = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first,
              let panel = workspace.newBrowserSurface(inPane: paneID, url: url, focus: true) else { return }

        cardToBrowserPanelID[card.id] = panel.id
    }

    func browserSurface(for cardID: UUID) -> BrowserSurfaceContext? {
        guard let workspace = browserWorkspace(for: cardID),
              let panelID = cardToBrowserPanelID[cardID],
              let panel = workspace.panels[panelID] as? BrowserPanel,
              let paneID = workspace.paneId(forPanelId: panelID) else {
            return nil
        }

        return BrowserSurfaceContext(panel: panel, paneId: paneID)
    }

    @discardableResult
    func reloadBrowserSurface(for cardID: UUID) -> Bool {
        guard let context = browserSurface(for: cardID) else { return false }
        context.panel.reload()
        return true
    }

    func focusBrowserSurface(for cardID: UUID) {
        guard let workspace = browserWorkspace(for: cardID),
              let context = browserSurface(for: cardID) else {
            return
        }

        selectWorkspace(workspace)
        workspace.focusPanel(context.panel.id)
    }

    func teardownBrowserPreview(for cardID: UUID) {
        removeBrowserWorkspace(for: cardID)
    }

    func restoreTerminalFocus(for cardID: UUID) {
        guard let workspace = workspace(for: cardID) else {
            return
        }

        guard let terminalPanel = launchTerminalPanel(in: workspace) else { return }

        selectWorkspace(workspace)
        workspace.focusPanel(terminalPanel.id)
    }

    func removeWorkspace(for cardID: UUID) {
        boardStore?.clearTerminalFullscreen(for: cardID)
        launchTasks[cardID]?.cancel()
        launchTasks.removeValue(forKey: cardID)
        if var pendingLaunch = pendingLaunchByCardID[cardID] {
            pendingLaunch.needsRequeue = true
            pendingLaunch.didSendVisibleNudge = false
            pendingLaunch.lastQueuedAt = nil
            pendingLaunchByCardID[cardID] = pendingLaunch
        } else {
            launchSignatureByCardID.removeValue(forKey: cardID)
        }
        removeBrowserWorkspace(for: cardID)

        let workspaceIDs = Set(workspaceToCardID
            .filter { $0.value == cardID }
            .map(\.key))

        let activeWorkspaceID = cardToWorkspaceID.removeValue(forKey: cardID)
        let allWorkspaceIDs = activeWorkspaceID.map { workspaceIDs.union([$0]) } ?? workspaceIDs

        for workspaceID in allWorkspaceIDs {
            cancelHiddenWorkspaceDetach(for: workspaceID)
            zellijSessionManager.killSession(for: workspaceID)
            workspaceStatusSubscriptions.removeValue(forKey: workspaceID)
            workspaceToCardID.removeValue(forKey: workspaceID)
            workspaceToBoardID.removeValue(forKey: workspaceID)
            workspaceRuntimeStateByID.removeValue(forKey: workspaceID)
        }

        for workspaceID in allWorkspaceIDs {
            guard let workspace = workspace(forID: workspaceID) else { continue }
            if let owningManager = workspace.owningTabManager
                ?? AppDelegate.shared?.tabManagerFor(tabId: workspace.id) {
                owningManager.closeWorkspace(workspace)
            } else {
                workspace.teardownAllPanels()
            }
        }
    }

    func forgetCardRuntimeState(for cardID: UUID) {
        cachedClaudeSummaryByCardID.removeValue(forKey: cardID)
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
        appDelegate.zenbanClaudePromptCaptureEnabledHandler = { [weak self] workspaceID in
            guard let self,
                  let cardID = self.workspaceToCardID[workspaceID],
                  let boardID = self.workspaceToBoardID[workspaceID],
                  let card = self.boardStore?.card(id: cardID) else {
                return false
            }

            return self.resolvedAgent(for: card, boardID: boardID) == .claude
        }
        appDelegate.zenbanPromptSubmittedHandler = { [weak self] workspaceID, panelID, prompt in
            Task { @MainActor [weak self] in
                self?.handlePromptSubmission(
                    workspaceID: workspaceID,
                    panelID: panelID,
                    prompt: prompt
                )
            }
        }
        appDelegate.zenbanLaunchRequestStartedHandler = { [weak self] workspaceID, panelID, token in
            Task { @MainActor [weak self] in
                self?.handleLaunchRequestStarted(
                    workspaceID: workspaceID,
                    panelID: panelID,
                    token: token
                )
            }
        }
        appDelegate.zenbanToggleTerminalFullscreenHandler = { [weak self] workspaceID, panelID in
            guard let self else { return false }
            return self.handleGhosttyTerminalFullscreenToggle(
                workspaceID: workspaceID,
                panelID: panelID
            )
        }
        appDelegate.zenbanAppTerminationCleanupHandler = { [weak self] in
            guard let self else { return }
            _ = await self.shutdownForApplicationTermination(timeout: 2.0)
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

    private func handlePromptSubmission(workspaceID: UUID, panelID: UUID, prompt: String) {
        guard let boardStore,
              let cardID = workspaceToCardID[workspaceID],
              let boardID = workspaceToBoardID[workspaceID],
              let workspace = workspace(forID: workspaceID),
              workspace.panels[panelID] != nil,
              let card = boardStore.card(id: cardID),
              resolvedAgent(for: card, boardID: boardID) == .claude else {
            return
        }

        recordWorkspaceAgentActivity(workspaceID)
        boardStore.updateCardLastSubmittedPrompt(cardID, prompt: prompt, in: boardID)
    }

    private func handleLaunchRequestStarted(workspaceID: UUID, panelID: UUID, token: String) {
        guard let cardID = workspaceToCardID[workspaceID],
              let pendingLaunch = pendingLaunchByCardID[cardID],
              pendingLaunch.token == token else {
            return
        }

        guard let expectedPanelID = zellijSessionManager.sessionPanelId(for: workspaceID),
              expectedPanelID == panelID else {
            return
        }

        pendingLaunchByCardID.removeValue(forKey: cardID)
        recordWorkspaceAgentActivity(workspaceID)
        launchSignatureByCardID[cardID] = pendingLaunch.targetSignature
        if pendingLaunch.shouldConsumePendingPrompt,
           let boardID = workspaceToBoardID[workspaceID] {
            boardStore?.consumePendingLaunchPrompt(cardID, in: boardID)
        }
    }

    private func clearLaunchTracking(for cardID: UUID) {
        launchSignatureByCardID.removeValue(forKey: cardID)
        pendingLaunchByCardID.removeValue(forKey: cardID)
        launchTasks[cardID]?.cancel()
        launchTasks.removeValue(forKey: cardID)
    }

    private func queuePendingLaunchRequest(
        _ pendingLaunch: PendingLaunchRequest,
        cardID: UUID,
        workspaceID: UUID
    ) {
        do {
            try zellijSessionManager.queueLaunchRequest(
                for: workspaceID,
                token: pendingLaunch.token,
                command: pendingLaunch.command
            )
            if var storedPendingLaunch = pendingLaunchByCardID[cardID],
               storedPendingLaunch.token == pendingLaunch.token {
                storedPendingLaunch.needsRequeue = false
                storedPendingLaunch.didSendVisibleNudge = false
                storedPendingLaunch.lastQueuedAt = Date()
                pendingLaunchByCardID[cardID] = storedPendingLaunch
            }
#if DEBUG
            launchCommandHandlerForTesting?(cardID, pendingLaunch.command)
#endif
        } catch {
            pendingLaunchByCardID.removeValue(forKey: cardID)
            launchSignatureByCardID.removeValue(forKey: cardID)
            NSLog(
                "Failed to queue zellij launch request for workspace %@: %@",
                workspaceID.uuidString,
                String(describing: error)
            )
        }
    }

    private func resumePendingLaunchIfNeeded(cardID: UUID, workspaceID: UUID) {
        guard pendingLaunchByCardID[cardID] != nil else { return }
        guard launchTasks[cardID] == nil else { return }

        launchTasks[cardID] = Task { [weak self] in
            guard let self else { return }
            defer {
                self.launchTasks.removeValue(forKey: cardID)
                self.updateHiddenWorkspaceDetachScheduling(for: workspaceID)
            }

            let shouldRecreateBackgroundSession =
                self.workspaceRuntimeStateByID[workspaceID]?.residency == .backgroundPrewarmOnly
                && !(self.workspace(forID: workspaceID)?.hasLoadedTerminalSurface() ?? false)
            if shouldRecreateBackgroundSession {
                self.zellijSessionManager.killRuntime(for: workspaceID)
            }

            if shouldRecreateBackgroundSession || !(self.workspace(forID: workspaceID)?.hasLoadedTerminalSurface() ?? false) {
                do {
                    try await self.zellijSessionManager.prepareBackgroundSession(workspaceId: workspaceID)
                } catch {
                    NSLog(
                        "Failed to prepare zellij background session for workspace %@: %@",
                        workspaceID.uuidString,
                        String(describing: error)
                    )
                    self.pendingLaunchByCardID.removeValue(forKey: cardID)
                    self.launchSignatureByCardID.removeValue(forKey: cardID)
                    return
                }
            }

            for _ in 0..<120 {
                guard !Task.isCancelled else { return }
                guard let pendingLaunch = self.pendingLaunchByCardID[cardID],
                      let workspace = self.workspace(for: cardID),
                      workspace.id == workspaceID else {
                    return
                }

                let now = Date()
                if let lastQueuedAt = pendingLaunch.lastQueuedAt,
                   now.timeIntervalSince(lastQueuedAt) >= self.pendingLaunchAckTimeout {
                    if self.requeueTimedOutPendingLaunch(
                        pendingLaunch,
                        cardID: cardID,
                        workspaceID: workspaceID
                    ) {
                        continue
                    }
                    return
                }

                if workspaceRuntimeStateByID[workspaceID]?.residency == .backgroundPrewarmOnly,
                   !workspace.hasLoadedTerminalSurface() {
                    try? await Task.sleep(for: .milliseconds(200))
                    continue
                }

                self.requestBackgroundWorkspaceLoad(for: workspace)

                guard let terminalPanel = self.launchTerminalPanel(in: workspace),
                      self.isTerminalReadyForLaunch(terminalPanel) else {
                    try? await Task.sleep(for: .milliseconds(200))
                    continue
                }

                let shellActivityState = workspace.panelShellActivityState(panelId: terminalPanel.id)
                if shellActivityState == .promptIdle, !pendingLaunch.didSendVisibleNudge {
                    var updatedLaunch = pendingLaunch
                    updatedLaunch.didSendVisibleNudge = true
                    self.pendingLaunchByCardID[cardID] = updatedLaunch
                    terminalPanel.sendText("\n")
                }

                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func updateSelectedCardContext(card: Card?, boardID: UUID?) {
        let nextContext = card.flatMap { card in
            boardID.map { SelectedCardContext(cardID: card.id, boardID: $0) }
        }

        if let previousContext = selectedCardContext,
           previousContext != nextContext,
           let previousCard = boardStore?.card(id: previousContext.cardID),
           previousCard.column == .done {
            removeWorkspace(for: previousContext.cardID)
        }

        selectedCardContext = nextContext
    }

    private func launchWorkspace(for card: Card?, boardID: UUID?, mode: WorkspaceLaunchMode) {
        configureAppDelegateIfNeeded()

        if mode != .backgroundPrewarm {
            updateSelectedCardContext(card: card, boardID: boardID)
        }

        guard let card, let boardID else { return }
        if mode == .selectionSync, card.column == .done { return }
        guard canCreateWorkspace(for: card, boardID: boardID) else { return }

        let workspace = ensureWorkspace(for: card, boardID: boardID)
        requestBackgroundWorkspaceLoad(
            for: workspace,
            allowTerminalSurfaceCreation: mode != .backgroundPrewarm
        )
        if mode != .backgroundPrewarm {
            selectWorkspace(workspace)
        }
        setWorkspaceResidency(
            mode == .backgroundPrewarm ? .backgroundPrewarmOnly : .interactive,
            for: workspace.id
        )
        updateTitle(for: card.id, title: card.title)
        updateAgentLaunch(for: card, boardID: boardID)
    }

    @discardableResult
    private func ensureWorkspace(for card: Card, boardID: UUID) -> Workspace {
        if let workspace = workspace(for: card.id) {
            workspaceToBoardID[workspace.id] = boardID
            _ = updateWorkspaceRuntimeState(for: workspace.id) { _ in }
            workspace.setCustomTitle(card.title)
            configureWorkspaceTerminalSession(workspace, card: card, boardID: boardID)
            observeWorkspaceStatus(in: workspace)
            return workspace
        }

        let workspace = tabManager.addWorkspace(
            workingDirectory: workingDirectory(for: card, boardID: boardID),
            select: false,
            eagerLoadTerminal: false,
            autoWelcomeIfNeeded: false
        )
        workspace.setCustomTitle(card.title)

        cardToWorkspaceID[card.id] = workspace.id
        workspaceToCardID[workspace.id] = card.id
        workspaceToBoardID[workspace.id] = boardID
        _ = updateWorkspaceRuntimeState(for: workspace.id) { _ in }
        configureWorkspaceTerminalSession(workspace, card: card, boardID: boardID)
        observeWorkspaceStatus(in: workspace)

        return workspace
    }

    private func canCreateWorkspace(for card: Card, boardID: UUID) -> Bool {
        !isWaitingForWorktree(for: card, boardID: boardID)
    }

    @discardableResult
    private func ensureBrowserWorkspace(for card: Card, boardID: UUID) -> Workspace {
        if let workspace = browserWorkspace(for: card.id) {
            workspace.setCustomTitle("\(card.title) Preview")
            return workspace
        }

        let workspace = tabManager.addWorkspace(
            workingDirectory: workingDirectory(for: card, boardID: boardID),
            select: false,
            eagerLoadTerminal: false,
            autoWelcomeIfNeeded: false
        )
        workspace.setCustomTitle("\(card.title) Preview")

        cardToBrowserWorkspaceID[card.id] = workspace.id
        return workspace
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

    private func resolvedAgent(forCardID cardID: UUID) -> Agent? {
        guard let boardStore else { return nil }

        for board in boardStore.boards {
            guard let card = board.cards.first(where: { $0.id == cardID }) else { continue }
            return card.agent ?? board.agent
        }

        return nil
    }

    private func launchSignature(for card: Card, boardID: UUID, agent: Agent) -> String {
        launchSignature(
            for: card,
            boardID: boardID,
            agent: agent,
            pendingPrompt: normalizedPendingLaunchPrompt(for: card, agent: agent)
        )
    }

    private func launchSignature(
        for card: Card,
        boardID: UUID,
        agent: Agent,
        pendingPrompt: String?
    ) -> String {
        let directory = workingDirectory(for: card, boardID: boardID) ?? ""
        let promptSignature = pendingPrompt ?? ""
        return "\(agent.runtimeID)|\(directory)|\(promptSignature)"
    }

    private func launchCommand(for agent: Agent, pendingPrompt: String?) -> String {
        switch agent {
        case .claude:
            return claudeLaunchCommand(prompt: pendingPrompt)
        case .codex:
            return "codex"
        case .gemini:
            return "gemini"
        }
    }

    private func claudeLaunchCommand(prompt: String?) -> String {
        var command = "\(claudeBinaryCommand()) --dangerously-skip-permissions"
        if let prompt, !prompt.isEmpty {
            command += " \(shellQuoted(prompt))"
        }
        return command
    }

    private func claudeBinaryCommand() -> String {
        let binaryURL = Bundle.main.resourceURL?
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("claude", isDirectory: false)
        return shellQuoted(binaryURL?.path ?? "claude")
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private func normalizedPendingLaunchPrompt(for card: Card, agent: Agent) -> String? {
        guard agent == .claude else { return nil }

        let normalized = card.pendingLaunchPrompt?
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let normalized, !normalized.isEmpty else { return nil }
        return normalized
    }

    private func newLaunchToken() -> String {
        UUID().uuidString.lowercased()
    }

    private func isTerminalReadyForLaunch(_ terminalPanel: TerminalPanel) -> Bool {
#if DEBUG
        if launchCommandHandlerForTesting != nil {
            return true
        }
#endif
        return terminalPanel.surface.surface != nil
    }

    @discardableResult
    private func requeueTimedOutPendingLaunch(
        _ pendingLaunch: PendingLaunchRequest,
        cardID: UUID,
        workspaceID: UUID
    ) -> Bool {
        zellijSessionManager.clearLaunchRequest(for: workspaceID)

        if pendingLaunch.retryCount >= 1 {
            var manualRetryLaunch = pendingLaunch
            manualRetryLaunch.token = newLaunchToken()
            manualRetryLaunch.needsRequeue = true
            manualRetryLaunch.didSendVisibleNudge = false
            manualRetryLaunch.retryCount = 0
            manualRetryLaunch.lastQueuedAt = nil
            pendingLaunchByCardID[cardID] = manualRetryLaunch
            NSLog(
                "Launch request timed out for card %@ in workspace %@; awaiting another selection sync to retry.",
                cardID.uuidString,
                workspaceID.uuidString
            )
            return false
        }

        var retriedLaunch = pendingLaunch
        retriedLaunch.token = newLaunchToken()
        retriedLaunch.retryCount += 1
        retriedLaunch.needsRequeue = true
        retriedLaunch.didSendVisibleNudge = false
        retriedLaunch.lastQueuedAt = nil
        pendingLaunchByCardID[cardID] = retriedLaunch
        queuePendingLaunchRequest(
            retriedLaunch,
            cardID: cardID,
            workspaceID: workspaceID
        )
        return pendingLaunchByCardID[cardID] != nil
    }

    private func launchTerminalPanel(in workspace: Workspace) -> TerminalPanel? {
        if let sessionPanelID = zellijSessionManager.sessionPanelId(for: workspace.id),
           let terminalPanel = workspace.panels[sessionPanelID] as? TerminalPanel {
            return terminalPanel
        }

        if let focusedTerminalPanel = workspace.focusedTerminalPanel {
            return focusedTerminalPanel
        }

        return workspace.panels.values
            .compactMap { $0 as? TerminalPanel }
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .first
    }

    private func requestBackgroundWorkspaceLoad(
        for workspace: Workspace,
        allowTerminalSurfaceCreation: Bool = true
    ) {
#if DEBUG
        if launchCommandHandlerForTesting != nil {
            return
        }
#endif
        if allowTerminalSurfaceCreation {
            workspace.requestBackgroundTerminalSurfaceStartIfNeeded()
        }
        owningTabManager(for: workspace).requestBackgroundWorkspaceLoad(for: workspace.id)
    }

    private func workspace(forID workspaceID: UUID) -> Workspace? {
        if let workspace = tabManager.tabs.first(where: { $0.id == workspaceID }) {
            return workspace
        }
        if let externalManager = AppDelegate.shared?.tabManagerFor(tabId: workspaceID),
           let workspace = externalManager.tabs.first(where: { $0.id == workspaceID }) {
            return workspace
        }
        return nil
    }

    private func browserWorkspace(for cardID: UUID) -> Workspace? {
        guard let workspaceID = cardToBrowserWorkspaceID[cardID] else { return nil }
        return workspace(forID: workspaceID)
    }

    private func observeWorkspaceStatus(in workspace: Workspace) {
        guard workspaceStatusSubscriptions[workspace.id] == nil else { return }
        let workspaceID = workspace.id

        workspaceStatusSubscriptions[workspaceID] = workspace.$statusEntries.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }

                self.workspaceStatusObservationGeneration &+= 1
                if let workspace = self.workspace(forID: workspaceID),
                   workspace.statusEntries.values.contains(where: { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                    self.recordWorkspaceAgentActivity(workspaceID)
                }

                guard let cardID = self.workspaceToCardID[workspaceID],
                      let boardID = self.workspaceToBoardID[workspaceID],
                      self.resolvedAgent(forCardID: cardID) == .claude,
                      let workspace = self.workspace(forID: workspaceID),
                      let summary = self.meaningfulClaudeStatus(in: workspace) else {
                    return
                }

                self.storeClaudeSummary(summary, for: cardID, in: boardID)
            }
        }
    }

    private func meaningfulClaudeStatus(in workspace: Workspace) -> String? {
        guard let entry = workspace.statusEntries["claude_code"] else { return nil }
        return normalizedClaudeSummary(entry.value, allowsGenericFallback: false)
    }

    private func meaningfulNotificationBody(for workspaceID: UUID) -> String? {
        guard let notification = notificationStore.latestNotification(forTabId: workspaceID) else { return nil }
        return normalizedClaudeSummary(notification.body)
    }

    private func cacheClaudeSummary(from notification: TerminalNotification, for cardID: UUID, in boardID: UUID) {
        guard let summary = normalizedClaudeSummary(notification.body) else { return }
        storeClaudeSummary(summary, for: cardID, in: boardID)
    }

    private func storeClaudeSummary(_ summary: String, for cardID: UUID, in boardID: UUID) {
        cachedClaudeSummaryByCardID[cardID] = summary
        boardStore?.updateCardAgentSummary(cardID, summary: summary, in: boardID)
    }

    private func normalizedClaudeSummary(
        _ value: String,
        allowsGenericFallback: Bool = true
    ) -> String? {
        let normalized = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else { return nil }

        let lowercased = normalized.lowercased()
        let genericValues = allowsGenericFallback
            ? Self.genericClaudeSummaries
            : Self.genericClaudeStatusValues
        guard !genericValues.contains(lowercased) else { return nil }

        return normalized
    }

    private static let genericClaudeStatusValues: Set<String> = [
        "idle",
        "needs input",
        "running",
    ]

    private static let genericClaudeSummaries: Set<String> = genericClaudeStatusValues.union([
        "approval needed",
        "attention",
        "claude is waiting for your input",
        "claude needs your attention",
        "claude needs your input",
        "completed",
        "done",
        "task completed",
        "waiting for input",
    ])

    private func removeBrowserWorkspace(for cardID: UUID) {
        let browserPanelID = cardToBrowserPanelID.removeValue(forKey: cardID)
        let browserWorkspaceID = cardToBrowserWorkspaceID.removeValue(forKey: cardID)

        guard let browserWorkspaceID,
              let workspace = workspace(forID: browserWorkspaceID) else {
            return
        }

        if let browserPanelID {
            _ = workspace.closePanel(browserPanelID, force: true)
        }

        if let owningManager = workspace.owningTabManager
            ?? AppDelegate.shared?.tabManagerFor(tabId: workspace.id) {
            owningManager.closeWorkspace(workspace)
        } else {
            workspace.teardownAllPanels()
        }
    }

    private func owningTabManager(for workspace: Workspace) -> TabManager {
        workspace.owningTabManager
            ?? AppDelegate.shared?.tabManagerFor(tabId: workspace.id)
            ?? tabManager
    }

    private func selectedCardFocusedPanelCloseContext(
        for cardID: UUID?
    ) -> SelectedCardFocusedPanelCloseContext? {
        guard let cardID,
              let workspace = workspace(for: cardID) else {
            return nil
        }

        let manager = owningTabManager(for: workspace)
        guard manager.selectedTabId == workspace.id,
              let panelID = workspace.focusedPanelId,
              let panel = workspace.panels[panelID] else {
            return nil
        }

        let matchingPanelCount = workspace.panels.values.reduce(into: 0) { count, candidate in
            if candidate.panelType == panel.panelType {
                count += 1
            }
        }

        return SelectedCardFocusedPanelCloseContext(
            workspace: workspace,
            panelID: panelID,
            panelType: panel.panelType,
            matchingPanelCount: matchingPanelCount
        )
    }

    private func selectWorkspace(_ workspace: Workspace) {
        owningTabManager(for: workspace).selectedTabId = workspace.id
        cancelHiddenWorkspaceDetach(for: workspace.id)
        if workspaceToCardID[workspace.id] != nil {
            setWorkspaceResidency(.interactive, for: workspace.id)
        }
        refreshWorkspaceHiddenState()
    }

    private func startHiddenWorkspaceReclaimLoop() {
        hiddenWorkspaceReclaimTask?.cancel()
        hiddenWorkspaceReclaimTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let pollingInterval = self.hiddenWorkspaceReclaimPollingInterval
                try? await Task.sleep(for: pollingInterval)
                self.evaluateHiddenWorkspaceReclaim()
            }
        }
    }

    private func setWorkspaceResidency(_ residency: WorkspaceResidency, for workspaceID: UUID, now: Date = Date()) {
        _ = updateWorkspaceRuntimeState(for: workspaceID, defaultResidency: residency) { runtimeState in
            runtimeState.residency = residency
            if isWorkspaceSelected(workspaceID) {
                runtimeState.hiddenSince = nil
            } else if runtimeState.hiddenSince == nil {
                runtimeState.hiddenSince = now
            }
        }
        updateHiddenWorkspaceDetachScheduling(for: workspaceID)
    }

    private func recordWorkspaceAgentActivity(_ workspaceID: UUID, at date: Date = Date()) {
        _ = updateWorkspaceRuntimeState(for: workspaceID) { runtimeState in
            runtimeState.lastObservedAgentActivityAt = date
        }
    }

    private func refreshWorkspaceHiddenState(now: Date = Date()) {
        for workspaceID in workspaceToCardID.keys {
            _ = updateWorkspaceRuntimeState(for: workspaceID) { runtimeState in
                if isWorkspaceSelected(workspaceID) {
                    runtimeState.hiddenSince = nil
                } else if runtimeState.hiddenSince == nil {
                    runtimeState.hiddenSince = now
                }
            }
            updateHiddenWorkspaceDetachScheduling(for: workspaceID)
        }
    }

    private func isWorkspaceSelected(_ workspaceID: UUID) -> Bool {
        guard let workspace = workspace(forID: workspaceID) else { return false }
        return owningTabManager(for: workspace).selectedTabId == workspaceID
    }

    private func evaluateHiddenWorkspaceReclaim(now: Date = Date()) {
        refreshWorkspaceHiddenState(now: now)

        for (workspaceID, cardID) in workspaceToCardID {
            guard let runtimeState = workspaceRuntimeStateByID[workspaceID],
                  runtimeState.residency == .backgroundPrewarmOnly,
                  !isWorkspaceSelected(workspaceID),
                  let hiddenSince = runtimeState.hiddenSince,
                  now.timeIntervalSince(hiddenSince) >= hiddenWorkspaceReclaimTimeout,
                  runtimeState.lastObservedAgentActivityAt == nil,
                  launchTasks[cardID] == nil,
                  let workspace = workspace(forID: workspaceID) else {
                continue
            }

            let terminalPanels = workspace.panels.values.compactMap { $0 as? TerminalPanel }
            guard !terminalPanels.isEmpty else { continue }

            let shellStates = terminalPanels.map { workspace.panelShellActivityState(panelId: $0.id) }
            if shellStates.contains(.commandRunning) {
                recordWorkspaceAgentActivity(workspaceID, at: now)
                continue
            }

            guard shellStates.allSatisfy({ $0 == .promptIdle }) else { continue }

#if DEBUG
            if backgroundReclaimHandlerForTesting != nil {
                reclaimWorkspaceRuntime(workspace, cardID: cardID)
                continue
            }
#endif

            if !zellijSessionManager.isManagedWorkspace(workspaceID),
               !workspace.hasLoadedTerminalSurface() {
                continue
            }
            reclaimWorkspaceRuntime(workspace, cardID: cardID)
        }
    }

    private func reclaimWorkspaceRuntime(_ workspace: Workspace, cardID: UUID) {
        launchTasks[cardID]?.cancel()
        launchTasks.removeValue(forKey: cardID)
        launchSignatureByCardID.removeValue(forKey: cardID)
        cancelHiddenWorkspaceDetach(for: workspace.id)
#if DEBUG
        if let backgroundReclaimHandlerForTesting {
            backgroundReclaimHandlerForTesting(cardID)
            return
        }
#endif
        if zellijSessionManager.isManagedWorkspace(workspace.id) {
            zellijSessionManager.killRuntime(for: workspace.id)
        }
        detachWorkspaceRuntime(workspace)
    }

    @discardableResult
    private func configureWorkspaceTerminalSession(_ workspace: Workspace, card: Card, boardID: UUID) -> Bool {
        guard let terminalPanel = launchTerminalPanel(in: workspace) else {
            zellijSessionManager.forgetWorkspace(workspace.id)
            NSLog(
                "Skipping zellij session setup because workspace %@ is missing a terminal panel for card %@.",
                workspace.id.uuidString,
                card.id.uuidString
            )
            return false
        }

        do {
            let registration = try zellijSessionManager.registerWorkspace(
                workspaceId: workspace.id,
                panelId: terminalPanel.id,
                portOrdinal: terminalPanel.surface.portOrdinal,
                workingDirectory: workingDirectory(for: card, boardID: boardID)
            )
            if registration.didChangeStartup {
                workspace.configureTerminalStartup(
                    command: registration.attachCommand,
                    environment: registration.startupEnvironment
                )
            }
            return true
        } catch {
            zellijSessionManager.forgetWorkspace(workspace.id)
            NSLog(
                "Failed to configure zellij startup for workspace %@: %@",
                workspace.id.uuidString,
                String(describing: error)
            )
            return false
        }
    }

    private func cancelHiddenWorkspaceDetach(for workspaceID: UUID) {
        hiddenWorkspaceDetachTasks[workspaceID]?.cancel()
        hiddenWorkspaceDetachTasks.removeValue(forKey: workspaceID)
    }

    private func updateHiddenWorkspaceDetachScheduling(for workspaceID: UUID) {
        guard zellijSessionManager.isManagedWorkspace(workspaceID),
              let runtimeState = workspaceRuntimeStateByID[workspaceID],
              runtimeState.hiddenSince != nil,
              !isWorkspaceSelected(workspaceID),
              let workspace = workspace(forID: workspaceID),
              workspace.hasLoadedTerminalSurface() else {
            cancelHiddenWorkspaceDetach(for: workspaceID)
            return
        }

        if hiddenWorkspaceDetachTasks[workspaceID] == nil {
            scheduleHiddenWorkspaceDetach(for: workspaceID)
        }
    }

    private func scheduleHiddenWorkspaceDetach(for workspaceID: UUID) {
        cancelHiddenWorkspaceDetach(for: workspaceID)
        hiddenWorkspaceDetachTasks[workspaceID] = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.hiddenWorkspaceDetachDelay)
            guard !Task.isCancelled else { return }

            self.hiddenWorkspaceDetachTasks.removeValue(forKey: workspaceID)

            guard self.zellijSessionManager.isManagedWorkspace(workspaceID),
                  let runtimeState = self.workspaceRuntimeStateByID[workspaceID],
                  runtimeState.hiddenSince != nil,
                  !self.isWorkspaceSelected(workspaceID),
                  let workspace = self.workspace(forID: workspaceID),
                  workspace.hasLoadedTerminalSurface() else {
                return
            }

            if let cardID = self.workspaceToCardID[workspaceID],
               self.launchTasks[cardID] != nil {
                self.scheduleHiddenWorkspaceDetach(for: workspaceID)
                return
            }

            self.detachWorkspaceRuntime(workspace)
        }
    }

    private func detachWorkspaceRuntime(_ workspace: Workspace) {
        for terminalPanel in workspace.panels.values.compactMap({ $0 as? TerminalPanel }) {
            terminalPanel.releaseRuntimeSurfaceForBackgroundReclaim()
        }
    }

    @discardableResult
    private func updateWorkspaceRuntimeState(
        for workspaceID: UUID,
        defaultResidency: WorkspaceResidency = .interactive,
        _ mutate: (inout WorkspaceRuntimeState) -> Void
    ) -> WorkspaceRuntimeState {
        var runtimeState = workspaceRuntimeStateByID[workspaceID] ?? WorkspaceRuntimeState(
            residency: defaultResidency,
            hiddenSince: nil,
            lastObservedAgentActivityAt: nil
        )
        mutate(&runtimeState)
        workspaceRuntimeStateByID[workspaceID] = runtimeState
        return runtimeState
    }

    func shutdownForApplicationTermination(
        timeout: TimeInterval
    ) async -> ZellijSessionManager.ShutdownResult {
        launchTasks.values.forEach { $0.cancel() }
        launchTasks.removeAll(keepingCapacity: false)
        hiddenWorkspaceDetachTasks.values.forEach { $0.cancel() }
        hiddenWorkspaceDetachTasks.removeAll(keepingCapacity: false)
        hiddenWorkspaceReclaimTask?.cancel()
        hiddenWorkspaceReclaimTask = nil
        pendingLaunchByCardID.removeAll(keepingCapacity: false)
        launchSignatureByCardID.removeAll(keepingCapacity: false)
        return await zellijSessionManager.shutdownAllSessionsForAppTermination(timeout: timeout)
    }

}

#if DEBUG
extension CmuxHostStore {
    func configureClaudeLaunchHooksForTesting(
        launchCommandHandler: ((UUID, String) -> Void)? = nil
    ) {
        launchCommandHandlerForTesting = launchCommandHandler
    }

    func resetClaudeLaunchHooksForTesting() {
        launchCommandHandlerForTesting = nil
    }

    func configureBackgroundReclaimHookForTesting(_ handler: ((UUID) -> Void)? = nil) {
        backgroundReclaimHandlerForTesting = handler
    }

    func setWorkspaceHiddenSinceForTesting(cardID: UUID, date: Date?) {
        guard let workspaceID = cardToWorkspaceID[cardID] else { return }
        _ = updateWorkspaceRuntimeState(for: workspaceID) { runtimeState in
            runtimeState.hiddenSince = date
        }
    }

    func setWorkspaceObservedAgentActivityForTesting(cardID: UUID, date: Date?) {
        guard let workspaceID = cardToWorkspaceID[cardID] else { return }
        _ = updateWorkspaceRuntimeState(for: workspaceID) { runtimeState in
            runtimeState.lastObservedAgentActivityAt = date
        }
    }

    func markWorkspaceInteractiveForTesting(cardID: UUID) {
        guard let workspaceID = cardToWorkspaceID[cardID] else { return }
        setWorkspaceResidency(.interactive, for: workspaceID)
    }

    func markWorkspaceBackgroundPrewarmOnlyForTesting(cardID: UUID) {
        guard let workspaceID = cardToWorkspaceID[cardID] else { return }
        setWorkspaceResidency(.backgroundPrewarmOnly, for: workspaceID)
    }

    func cancelLaunchTaskForTesting(cardID: UUID) {
        launchTasks[cardID]?.cancel()
        launchTasks.removeValue(forKey: cardID)
    }

    @discardableResult
    func acknowledgePendingLaunchForTesting(cardID: UUID) -> Bool {
        guard let workspaceID = cardToWorkspaceID[cardID],
              let panelID = zellijSessionManager.sessionPanelId(for: workspaceID),
              let pendingLaunch = pendingLaunchByCardID[cardID] else {
            return false
        }
        handleLaunchRequestStarted(
            workspaceID: workspaceID,
            panelID: panelID,
            token: pendingLaunch.token
        )
        return pendingLaunchByCardID[cardID] == nil
    }

    func setHiddenWorkspaceReclaimTimeoutForTesting(_ timeout: TimeInterval) {
        hiddenWorkspaceReclaimTimeout = timeout
    }

    func setHiddenWorkspaceDetachDelayForTesting(_ delay: Duration) {
        hiddenWorkspaceDetachDelay = delay
    }

    func setPendingLaunchAckTimeoutForTesting(_ timeout: TimeInterval) {
        pendingLaunchAckTimeout = timeout
    }

    func pendingLaunchSnapshotForTesting(cardID: UUID) -> (token: String, retryCount: Int, needsRequeue: Bool)? {
        guard let pendingLaunch = pendingLaunchByCardID[cardID] else { return nil }
        return (
            token: pendingLaunch.token,
            retryCount: pendingLaunch.retryCount,
            needsRequeue: pendingLaunch.needsRequeue
        )
    }

    func evaluateHiddenWorkspaceReclaimForTesting(now: Date = Date()) {
        evaluateHiddenWorkspaceReclaim(now: now)
    }
}
#endif

extension CmuxHostStore: TerminalNotificationStoreObserver {
    func terminalNotificationStore(
        _ store: TerminalNotificationStore,
        didAdd notification: TerminalNotification
    ) {
        guard let boardStore,
              let cardID = workspaceToCardID[notification.tabId],
              let boardID = workspaceToBoardID[notification.tabId],
              let card = boardStore.card(id: cardID) else {
            return
        }

        if resolvedAgent(for: card, boardID: boardID) == .claude {
            cacheClaudeSummary(from: notification, for: cardID, in: boardID)
        }

        recordWorkspaceAgentActivity(notification.tabId)

        guard card.column == .todo else { return }
        _ = boardStore.moveCard(cardID, to: .inProgress, in: boardID)
    }
}
