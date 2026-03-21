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
        let token: String
        let command: String
        let targetSignature: String
        let shouldConsumePendingPrompt: Bool
        var didSendVisibleNudge: Bool
        var needsRequeue: Bool
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
    @ObservationIgnored private var applicationWillTerminateObserver: NSObjectProtocol?
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
        applicationWillTerminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleApplicationWillTerminate()
            }
        }
    }

    deinit {
        hiddenWorkspaceReclaimTask?.cancel()
        hiddenWorkspaceDetachTasks.values.forEach { $0.cancel() }
        if let applicationWillTerminateObserver {
            NotificationCenter.default.removeObserver(applicationWillTerminateObserver)
        }
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
            launchSignatureByCardID.removeValue(forKey: card.id)
            pendingLaunchByCardID.removeValue(forKey: card.id)
            launchTasks[card.id]?.cancel()
            launchTasks.removeValue(forKey: card.id)
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

        if zellijSessionManager.isManagedWorkspace(workspaceID) {
            let pendingLaunch = PendingLaunchRequest(
                token: UUID().uuidString.lowercased(),
                command: command,
                targetSignature: postLaunchSignature,
                shouldConsumePendingPrompt: normalizedPrompt != nil,
                didSendVisibleNudge: false,
                needsRequeue: true
            )
            pendingLaunchByCardID[cardID] = pendingLaunch
            queuePendingLaunchRequest(
                pendingLaunch,
                cardID: cardID,
                workspaceID: workspaceID
            )
            resumePendingLaunchIfNeeded(cardID: cardID, workspaceID: workspaceID)
            return
        }

        launchTasks[cardID] = Task { [weak self] in
            var consecutivePromptIdleObservations = 0
            var unknownShellStateSinceSurfaceReadyAt: Date?
            defer {
                self?.launchTasks.removeValue(forKey: cardID)
                if let workspaceID = self?.cardToWorkspaceID[cardID] {
                    self?.updateHiddenWorkspaceDetachScheduling(for: workspaceID)
                }
            }

            for _ in 0..<120 {
                guard !Task.isCancelled, let self else { return }
                guard let workspace = self.workspace(for: cardID), workspace.id == workspaceID else { return }
                self.requestBackgroundWorkspaceLoad(for: workspace)

                if let terminalPanel = self.launchTerminalPanel(in: workspace),
                   self.isTerminalReadyForLaunch(terminalPanel) {
                    let shellActivityState = workspace.panelShellActivityState(panelId: terminalPanel.id)
                    switch shellActivityState {
                    case .promptIdle:
                        consecutivePromptIdleObservations += 1
                        unknownShellStateSinceSurfaceReadyAt = nil
                        // Give the shell prompt one more polling turn to settle so the
                        // injected Enter key is not swallowed while the prompt redraws.
                        if consecutivePromptIdleObservations >= 2 {
                            self.sendLaunchCommand(command, to: terminalPanel, cardID: cardID)
                            self.launchSignatureByCardID[cardID] = postLaunchSignature
                            if normalizedPrompt != nil {
                                self.boardStore?.consumePendingLaunchPrompt(cardID, in: boardID)
                            }
                            return
                        }
                    case .unknown:
                        consecutivePromptIdleObservations = 0
                        if unknownShellStateSinceSurfaceReadyAt == nil {
                            unknownShellStateSinceSurfaceReadyAt = Date()
                        }
                        // Some shells may never report prompt readiness; fall back only
                        // after a short grace period so we avoid injecting before the
                        // initial prompt in the common case.
                        if let unknownShellStateSinceSurfaceReadyAt,
                           Date().timeIntervalSince(unknownShellStateSinceSurfaceReadyAt) >= 1.5 {
                            self.sendLaunchCommand(command, to: terminalPanel, cardID: cardID)
                            self.launchSignatureByCardID[cardID] = postLaunchSignature
                            if normalizedPrompt != nil {
                                self.boardStore?.consumePendingLaunchPrompt(cardID, in: boardID)
                            }
                            return
                        }
                    case .commandRunning:
                        consecutivePromptIdleObservations = 0
                        unknownShellStateSinceSurfaceReadyAt = nil
                    }
                } else {
                    consecutivePromptIdleObservations = 0
                    unknownShellStateSinceSurfaceReadyAt = nil
                }

                try? await Task.sleep(for: .milliseconds(200))
            }
        }
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
#if DEBUG
        debugLogWorkspaceMemory(
            event: "zenban.workspace.remove.begin",
            cardID: cardID,
            workspaceID: cardToWorkspaceID[cardID],
            extra: "reason=card_cleanup"
        )
#endif
        launchTasks[cardID]?.cancel()
        launchTasks.removeValue(forKey: cardID)
        if var pendingLaunch = pendingLaunchByCardID[cardID] {
            pendingLaunch.needsRequeue = true
            pendingLaunch.didSendVisibleNudge = false
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
#if DEBUG
        debugLogWorkspaceMemory(
            event: "zenban.workspace.remove.end",
            cardID: cardID,
            workspaceID: nil,
            extra: "removedCount=\(allWorkspaceIDs.count)"
        )
#endif
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
#if DEBUG
        debugLogLaunchRequest(
            event: "launch.request.acked",
            cardID: cardID,
            workspaceID: workspaceID,
            token: pendingLaunch.token,
            extra: "panel=\(String(panelID.uuidString.prefix(5)))"
        )
#endif
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
#if DEBUG
            debugLogLaunchRequest(
                event: "launch.request.enqueued",
                cardID: cardID,
                workspaceID: workspaceID,
                token: pendingLaunch.token,
                extra: "command=\(resolvedAgent(forCardID: cardID)?.runtimeID ?? "unknown")"
            )
#endif
            if var storedPendingLaunch = pendingLaunchByCardID[cardID],
               storedPendingLaunch.token == pendingLaunch.token {
                storedPendingLaunch.needsRequeue = false
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

#if DEBUG
            if self.launchCommandHandlerForTesting != nil {
                return
            }
#endif

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
#if DEBUG
                    self.debugLogLaunchRequest(
                        event: "launch.request.nudged",
                        cardID: cardID,
                        workspaceID: workspaceID,
                        token: pendingLaunch.token,
                        extra: "shellState=promptIdle"
                    )
#endif
                }

                try? await Task.sleep(for: .milliseconds(200))
            }

            guard let pendingLaunch = self.pendingLaunchByCardID[cardID] else { return }
#if DEBUG
            self.debugLogLaunchRequest(
                event: "launch.request.still_pending",
                cardID: cardID,
                workspaceID: workspaceID,
                token: pendingLaunch.token,
                extra: "nudged=\(pendingLaunch.didSendVisibleNudge ? 1 : 0)"
            )
#endif
        }
    }

    private func updateSelectedCardContext(card: Card?, boardID: UUID?) {
        let nextContext = card.flatMap { card in
            boardID.map { SelectedCardContext(cardID: card.id, boardID: $0) }
        }

#if DEBUG
        debugLogWorkspaceMemory(
            event: "zenban.card.transition",
            cardID: nextContext?.cardID,
            workspaceID: nextContext.flatMap { cardToWorkspaceID[$0.cardID] },
            extra: [
                "fromCard=\(debugShortCardId(selectedCardContext?.cardID))",
                "fromWorkspace=\(debugShortWorkspaceId(selectedCardContext?.cardID))",
                "toCard=\(debugShortCardId(nextContext?.cardID))",
                "toWorkspace=\(debugShortWorkspaceId(nextContext?.cardID))",
            ].joined(separator: " ")
        )
#endif

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
#if DEBUG
        debugLogWorkspaceMemory(
            event: "zenban.workspace.launch",
            cardID: card.id,
            workspaceID: workspace.id,
            extra: "mode=\(debugLaunchModeName(mode)) column=\(card.column.rawValue)"
        )
#endif
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
            if workspaceRuntimeStateByID[workspace.id] == nil {
                workspaceRuntimeStateByID[workspace.id] = WorkspaceRuntimeState(
                    residency: .interactive,
                    hiddenSince: nil,
                    lastObservedAgentActivityAt: nil
                )
            }
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
        workspaceRuntimeStateByID[workspace.id] = WorkspaceRuntimeState(
            residency: .interactive,
            hiddenSince: nil,
            lastObservedAgentActivityAt: nil
        )
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

    private func isTerminalReadyForLaunch(_ terminalPanel: TerminalPanel) -> Bool {
#if DEBUG
        if launchCommandHandlerForTesting != nil {
            return true
        }
#endif
        return terminalPanel.surface.surface != nil
    }

    private func sendLaunchCommand(_ command: String, to terminalPanel: TerminalPanel, cardID: UUID) {
        if let workspaceID = cardToWorkspaceID[cardID] {
            recordWorkspaceAgentActivity(workspaceID)
        }
#if DEBUG
        if let launchCommandHandlerForTesting {
            launchCommandHandlerForTesting(cardID, command)
            return
        }
#endif
        terminalPanel.sendShellCommand(command)
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

    private func selectWorkspace(_ workspace: Workspace) {
        owningTabManager(for: workspace).selectedTabId = workspace.id
        cancelHiddenWorkspaceDetach(for: workspace.id)
        if workspaceToCardID[workspace.id] != nil {
            setWorkspaceResidency(.interactive, for: workspace.id)
        }
        refreshWorkspaceHiddenState()
#if DEBUG
        debugLogWorkspaceMemory(
            event: "zenban.workspace.select",
            cardID: workspaceToCardID[workspace.id],
            workspaceID: workspace.id,
            extra: "selected=1"
        )
#endif
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
        var runtimeState = workspaceRuntimeStateByID[workspaceID] ?? WorkspaceRuntimeState(
            residency: residency,
            hiddenSince: nil,
            lastObservedAgentActivityAt: nil
        )
        runtimeState.residency = residency
        if isWorkspaceSelected(workspaceID) {
            runtimeState.hiddenSince = nil
        } else if runtimeState.hiddenSince == nil {
            runtimeState.hiddenSince = now
        }
        workspaceRuntimeStateByID[workspaceID] = runtimeState
#if DEBUG
        let hiddenForMs: String
        if let hiddenSince = runtimeState.hiddenSince {
            hiddenForMs = String(format: "%.0f", max(0, now.timeIntervalSince(hiddenSince) * 1000))
        } else {
            hiddenForMs = "0"
        }
        debugLogWorkspaceMemory(
            event: "zenban.workspace.residency",
            cardID: workspaceToCardID[workspaceID],
            workspaceID: workspaceID,
            extra: "state=\(debugResidencyName(residency)) hiddenForMs=\(hiddenForMs)"
        )
#endif
        updateHiddenWorkspaceDetachScheduling(for: workspaceID)
    }

    private func recordWorkspaceAgentActivity(_ workspaceID: UUID, at date: Date = Date()) {
        var runtimeState = workspaceRuntimeStateByID[workspaceID] ?? WorkspaceRuntimeState(
            residency: .interactive,
            hiddenSince: nil,
            lastObservedAgentActivityAt: nil
        )
        runtimeState.lastObservedAgentActivityAt = date
        workspaceRuntimeStateByID[workspaceID] = runtimeState
    }

    private func refreshWorkspaceHiddenState(now: Date = Date()) {
        for workspaceID in workspaceToCardID.keys {
            var runtimeState = workspaceRuntimeStateByID[workspaceID] ?? WorkspaceRuntimeState(
                residency: .interactive,
                hiddenSince: nil,
                lastObservedAgentActivityAt: nil
            )
            if isWorkspaceSelected(workspaceID) {
                runtimeState.hiddenSince = nil
            } else if runtimeState.hiddenSince == nil {
                runtimeState.hiddenSince = now
            }
            workspaceRuntimeStateByID[workspaceID] = runtimeState
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
#if DEBUG
        debugLogWorkspaceMemory(
            event: "zenban.workspace.reclaim.begin",
            cardID: cardID,
            workspaceID: workspace.id,
            extra: "reason=background_reclaim"
        )
#endif
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
        detachWorkspaceRuntime(workspace, reason: "background_reclaim")
    }

    private func configureWorkspaceTerminalSession(_ workspace: Workspace, card: Card, boardID: UUID) {
        guard let terminalPanel = launchTerminalPanel(in: workspace) else {
            fatalError("Workspace \(workspace.id) is missing a terminal panel for card \(card.id).")
        }

        zellijSessionManager.registerWorkspace(
            workspaceId: workspace.id,
            panelId: terminalPanel.id,
            portOrdinal: terminalPanel.surface.portOrdinal,
            workingDirectory: workingDirectory(for: card, boardID: boardID)
        )

        do {
            workspace.configureTerminalStartup(
                command: try zellijSessionManager.attachCommand(for: workspace.id),
                environment: try zellijSessionManager.startupEnvironment(for: workspace.id)
            )
        } catch {
            fatalError(error.localizedDescription)
        }
    }

    private func cancelHiddenWorkspaceDetach(for workspaceID: UUID) {
        let hadTask = hiddenWorkspaceDetachTasks[workspaceID] != nil
        hiddenWorkspaceDetachTasks[workspaceID]?.cancel()
        hiddenWorkspaceDetachTasks.removeValue(forKey: workspaceID)
#if DEBUG
        if hadTask {
            debugLogWorkspaceMemory(
                event: "zenban.workspace.detach.canceled",
                cardID: workspaceToCardID[workspaceID],
                workspaceID: workspaceID,
                extra: "reason=visibility_or_cleanup"
            )
        }
#endif
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
#if DEBUG
        let hiddenForMs: String = {
            guard let hiddenSince = workspaceRuntimeStateByID[workspaceID]?.hiddenSince else { return "0" }
            return String(format: "%.0f", max(0, Date().timeIntervalSince(hiddenSince) * 1000))
        }()
        debugLogWorkspaceMemory(
            event: "zenban.workspace.detach.scheduled",
            cardID: workspaceToCardID[workspaceID],
            workspaceID: workspaceID,
            extra: "delayMs=3000 hiddenForMs=\(hiddenForMs)"
        )
#endif
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

            self.detachWorkspaceRuntime(workspace, reason: "hidden_switch")
        }
    }

    private func detachWorkspaceRuntime(_ workspace: Workspace, reason: String) {
#if DEBUG
        let hiddenForMs: String = {
            guard let hiddenSince = workspaceRuntimeStateByID[workspace.id]?.hiddenSince else { return "0" }
            return String(format: "%.0f", max(0, Date().timeIntervalSince(hiddenSince) * 1000))
        }()
        debugLogWorkspaceMemory(
            event: "zenban.workspace.detach.begin",
            cardID: workspaceToCardID[workspace.id],
            workspaceID: workspace.id,
            extra: "reason=\(reason) hiddenForMs=\(hiddenForMs)"
        )
#endif
        for terminalPanel in workspace.panels.values.compactMap({ $0 as? TerminalPanel }) {
            terminalPanel.releaseRuntimeSurfaceForBackgroundReclaim()
        }
#if DEBUG
        debugLogWorkspaceMemory(
            event: "zenban.workspace.detach.end",
            cardID: workspaceToCardID[workspace.id],
            workspaceID: workspace.id,
            extra: "reason=\(reason)"
        )
#endif
    }

    private func handleApplicationWillTerminate() {
        launchTasks.values.forEach { $0.cancel() }
        launchTasks.removeAll(keepingCapacity: false)
        hiddenWorkspaceDetachTasks.values.forEach { $0.cancel() }
        hiddenWorkspaceDetachTasks.removeAll(keepingCapacity: false)
        hiddenWorkspaceReclaimTask?.cancel()
        pendingLaunchByCardID.removeAll(keepingCapacity: false)
        launchSignatureByCardID.removeAll(keepingCapacity: false)
        zellijSessionManager.killAllSessions()
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
        var runtimeState = workspaceRuntimeStateByID[workspaceID] ?? WorkspaceRuntimeState(
            residency: .interactive,
            hiddenSince: nil,
            lastObservedAgentActivityAt: nil
        )
        runtimeState.hiddenSince = date
        workspaceRuntimeStateByID[workspaceID] = runtimeState
    }

    func setWorkspaceObservedAgentActivityForTesting(cardID: UUID, date: Date?) {
        guard let workspaceID = cardToWorkspaceID[cardID] else { return }
        var runtimeState = workspaceRuntimeStateByID[workspaceID] ?? WorkspaceRuntimeState(
            residency: .interactive,
            hiddenSince: nil,
            lastObservedAgentActivityAt: nil
        )
        runtimeState.lastObservedAgentActivityAt = date
        workspaceRuntimeStateByID[workspaceID] = runtimeState
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

    func evaluateHiddenWorkspaceReclaimForTesting(now: Date = Date()) {
        evaluateHiddenWorkspaceReclaim(now: now)
    }

    private func debugLogWorkspaceMemory(
        event: String,
        cardID: UUID?,
        workspaceID: UUID?,
        extra: String
    ) {
        let loadedSurfaceCount = workspaceToCardID.keys.reduce(into: 0) { count, candidateWorkspaceID in
            guard let workspace = workspace(forID: candidateWorkspaceID),
                  workspace.hasLoadedTerminalSurface() else { return }
            count += 1
        }
        let managedSessionCount = workspaceToCardID.keys.reduce(into: 0) { count, candidateWorkspaceID in
            if zellijSessionManager.isManagedWorkspace(candidateWorkspaceID) {
                count += 1
            }
        }
        var suffix = [
            "card=\(debugShortCardId(cardID))",
            "loadedSurfaces=\(loadedSurfaceCount)",
            "managedSessions=\(managedSessionCount)",
        ]
        if !extra.isEmpty {
            suffix.append(extra)
        }
        DebugProcessMemory.log(
            event,
            workspaceId: workspaceID,
            panelId: workspaceID.flatMap { zellijSessionManager.sessionPanelId(for: $0) },
            extra: suffix.joined(separator: " ")
        )
    }

    private func debugLogLaunchRequest(
        event: String,
        cardID: UUID,
        workspaceID: UUID,
        token: String,
        extra: String
    ) {
        var suffix = [
            "card=\(debugShortCardId(cardID))",
            "token=\(String(token.prefix(8)))",
        ]
        if !extra.isEmpty {
            suffix.append(extra)
        }
        debugLogWorkspaceMemory(
            event: event,
            cardID: cardID,
            workspaceID: workspaceID,
            extra: suffix.joined(separator: " ")
        )
    }

    private func debugShortCardId(_ cardID: UUID?) -> String {
        guard let cardID else { return "nil" }
        return String(cardID.uuidString.prefix(5))
    }

    private func debugShortWorkspaceId(_ cardID: UUID?) -> String {
        guard let cardID,
              let workspaceID = cardToWorkspaceID[cardID] else {
            return "nil"
        }
        return String(workspaceID.uuidString.prefix(5))
    }

    private func debugResidencyName(_ residency: WorkspaceResidency) -> String {
        switch residency {
        case .interactive:
            return "interactive"
        case .backgroundPrewarmOnly:
            return "backgroundPrewarmOnly"
        }
    }

    private func debugLaunchModeName(_ mode: WorkspaceLaunchMode) -> String {
        switch mode {
        case .selectionSync:
            return "selectionSync"
        case .interactiveOpen:
            return "interactiveOpen"
        case .backgroundPrewarm:
            return "backgroundPrewarm"
        }
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
