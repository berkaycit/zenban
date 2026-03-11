import AppKit
import Foundation
#if DEBUG
import Bonsplit
#endif

@MainActor
@Observable
final class TerminalManager {
    struct WorkspaceRecord {
        let cardID: UUID
        let boardID: UUID
        var tabManager: TabManager
        let workspace: Workspace
        let primaryTerminalPanelID: UUID
        var cardTitle: String
        var workingDirectory: String?
        var detachedWindowID: UUID?
    }

    struct AgentSessionRecord {
        let cardID: UUID
        let boardID: UUID
        let panelID: UUID
        let tmuxSessionID: String
        var agent: Agent
        var workingDirectory: String?
    }

    struct PendingAgentLaunchSnapshot: Equatable {
        let cardID: UUID
        let panelID: UUID
        let agent: Agent
        let workingDirectory: String?
        let reason: AgentLaunchReason
        let hasScheduledTask: Bool
    }

    private struct PendingAgentLaunch {
        let cardID: UUID
        var panelID: UUID
        var agent: Agent
        var workingDirectory: String?
        var reason: AgentLaunchReason
        var scheduledTask: Task<Void, Never>?
        var scheduleGeneration: UInt64 = 0
    }

    typealias AgentLaunchExecutor = @Sendable (AgentLaunchPlan, String) async -> Bool

    enum TerminalManagerError: Error {
        case workspaceUnavailable
    }

    private var records: [UUID: WorkspaceRecord] = [:]
    private var agentLaunchedForCard: Set<UUID> = []
    private var agentSessionRecordByCardID: [UUID: AgentSessionRecord] = [:]
    private var pendingAgentLaunchByCardID: [UUID: PendingAgentLaunch] = [:]
    private var pendingWorktreeReady: [UUID: (worktreePath: String, agent: Agent)] = [:]
    private var pendingCardUnfocusTarget: (cardID: UUID, panelID: UUID)?
    private var activeCardID: UUID?
    private let mainBoardTabManager = TabManager(
        createsInitialWorkspace: false,
        keepsBootstrapWorkspaceWhenEmpty: false
    )

    weak var boardStore: BoardStore?
    weak var agentSessionMonitor: AgentSessionMonitor?
    var autoLaunchDebounce: Duration = .milliseconds(150)
    var launchExecutor: AgentLaunchExecutor = { plan, sessionID in
        await AgentLauncher.launch(plan, sessionID: sessionID)
    }

#if DEBUG
    private func debugWorkspaceSummary(_ record: WorkspaceRecord) -> String {
        let terminalCount = record.workspace.panels.values.reduce(into: 0) { count, panel in
            if panel is TerminalPanel {
                count += 1
            }
        }
        let browserCount = record.workspace.panels.values.reduce(into: 0) { count, panel in
            if panel is BrowserPanel {
                count += 1
            }
        }
        return
            "card=\(record.cardID.uuidString.prefix(5)) board=\(record.boardID.uuidString.prefix(5)) " +
            "workspace=\(record.workspace.id.uuidString.prefix(5)) selectedTab=\(record.tabManager.selectedTabId?.uuidString.prefix(5) ?? "nil") " +
            "focusedPanel=\(record.workspace.focusedPanelId?.uuidString.prefix(5) ?? "nil") detached=\(record.detachedWindowID?.uuidString.prefix(5) ?? "nil") " +
            "terminals=\(terminalCount) browsers=\(browserCount) loadedTerminal=\(record.workspace.hasLoadedTerminalSurface() ? 1 : 0)"
    }
#endif

    var isTerminalAvailable: Bool {
        GhosttyApp.shared.app != nil
    }

    init() {
        _ = GhosttyApp.shared
        AppDelegate.shared?.registerMainBoardTabManager(mainBoardTabManager)
    }

    /// Read-only lookup that returns an existing record without mutating observable state.
    /// Safe to call from SwiftUI body. Returns nil if the record hasn't been created yet.
    func existingWorkspaceRecord(for cardID: UUID) -> WorkspaceRecord? {
        records[cardID]
    }

    func pendingAgentLaunchSnapshot(for cardID: UUID) -> PendingAgentLaunchSnapshot? {
        guard let pending = pendingAgentLaunchByCardID[cardID] else { return nil }
        return PendingAgentLaunchSnapshot(
            cardID: pending.cardID,
            panelID: pending.panelID,
            agent: pending.agent,
            workingDirectory: pending.workingDirectory,
            reason: pending.reason,
            hasScheduledTask: pending.scheduledTask != nil
        )
    }

    func hasLaunchedAgent(for cardID: UUID) -> Bool {
        agentLaunchedForCard.contains(cardID)
    }

    func workspaceRecord(for cardID: UUID, boardID: UUID, cardTitle: String) -> WorkspaceRecord {
        if var record = records[cardID] {
            let board = boardStore?.board(for: boardID)
            let card = board?.cards.first { $0.id == cardID }
            if record.cardTitle != cardTitle {
                record.cardTitle = cardTitle
                record.workspace.setCustomTitle(cardTitle)
                AppDelegate.shared?.updateWorkspaceTitle(for: cardID, title: cardTitle)
            }
            let updatedWorkingDirectory = card?.worktreePath ?? board?.repositoryPath
            if record.workingDirectory != updatedWorkingDirectory {
                record.workingDirectory = updatedWorkingDirectory
            }
            records[cardID] = record
            refreshAutoLaunchIfNeeded(for: record, board: board, card: card)
#if DEBUG
            dlog("handoff.workspaceRecord.reuse \(debugWorkspaceSummary(record)) title=\(cardTitle)")
#endif
            return record
        }

        let board = boardStore?.board(for: boardID)
        let card = board?.cards.first { $0.id == cardID }
        let workingDirectory = card?.worktreePath ?? board?.repositoryPath
        AppDelegate.shared?.registerMainBoardTabManager(mainBoardTabManager)
        let workspace = mainBoardTabManager.addWorkspace(
            workingDirectory: workingDirectory,
            select: records.isEmpty,
            workspaceID: cardID,
            title: cardTitle
        )

        workspace.setCustomTitle(cardTitle)

        let primaryTerminalPanelID =
            workspace.focusedTerminalPanel?.id
            ?? workspace.focusedPanelId
            ?? workspace.panels.keys.first
            ?? UUID()

        var record = WorkspaceRecord(
            cardID: cardID,
            boardID: boardID,
            tabManager: mainBoardTabManager,
            workspace: workspace,
            primaryTerminalPanelID: primaryTerminalPanelID,
            cardTitle: cardTitle,
            workingDirectory: workingDirectory,
            detachedWindowID: nil
        )
        records[cardID] = record
        AppDelegate.shared?.register(tabManager: mainBoardTabManager, for: cardID, boardID: boardID)
#if DEBUG
        dlog("handoff.workspaceRecord.create \(debugWorkspaceSummary(record)) title=\(cardTitle) workdir=\(workingDirectory ?? "nil")")
#endif
        Task {
            _ = await TmuxSessionManager.shared.prewarmServer()
        }

        refreshAutoLaunchIfNeeded(for: record, board: board, card: card)

        if let updated = records[cardID] {
            record = updated
        }
        return record
    }

    func activateWorkspace(for cardID: UUID) {
        guard let record = records[cardID] else { return }
        let hadNoActiveWorkspace = activeCardID == nil

        // Skip redundant activation to prevent first-responder churn
        // when rapid card switches cause multiple activate calls for the same card.
        guard activeCardID != cardID else {
            schedulePendingAgentLaunchIfNeeded(for: cardID)
#if DEBUG
            dlog("handoff.activate.skip \(debugWorkspaceSummary(record)) reason=alreadyActive")
#endif
            return
        }
        activeCardID = cardID

#if DEBUG
        dlog("handoff.activate.begin \(debugWorkspaceSummary(record))")
#endif
        record.workspace.resumeAllTerminalSurfaces()
        if record.tabManager.selectedTabId != record.workspace.id {
            record.tabManager.selectWorkspace(record.workspace)
        }
        AppDelegate.shared?.activateCard(cardID)
        let shouldLaunchImmediately =
            hadNoActiveWorkspace &&
            pendingAgentLaunchByCardID.count <= 1
        schedulePendingAgentLaunchIfNeeded(for: cardID, immediate: shouldLaunchImmediately)
#if DEBUG
        dlog("handoff.activate.end \(debugWorkspaceSummary(record))")
#endif
    }

    func deactivateWorkspace(for cardID: UUID) {
        if activeCardID == cardID {
            activeCardID = nil
        }
        cancelPendingAgentLaunch(for: cardID, reason: "deactivate")
#if DEBUG
        if let record = records[cardID] {
            dlog("handoff.deactivate \(debugWorkspaceSummary(record))")
        } else {
            dlog("handoff.deactivate.missing card=\(cardID.uuidString.prefix(5))")
        }
#endif
        AppDelegate.shared?.deactivateCard(cardID)
    }

    func clearActiveWorkspace() {
        if let activeCardID {
            cancelPendingAgentLaunch(for: activeCardID, reason: "clearActive")
        }
        activeCardID = nil
        AppDelegate.shared?.clearActiveCard()
    }

    func startCardHandoff(from oldCardID: UUID, to newCardID: UUID) {
        // Skip if already targeting this card (rapid switches may call this multiple times)
        guard oldCardID != newCardID else { return }

#if DEBUG
        let oldSummary = records[oldCardID].map(debugWorkspaceSummary) ?? "card=\(oldCardID.uuidString.prefix(5)) missing=1"
        let newSummary = records[newCardID].map(debugWorkspaceSummary) ?? "card=\(newCardID.uuidString.prefix(5)) missing=1"
        dlog("handoff.start from={\(oldSummary)} to={\(newSummary)}")
#endif
        // Hide the retiring card's portal views immediately so the old terminal
        // content doesn't ghost above the new card for a few frames while the
        // new card's portal binding is still pending (async). The portal layer
        // sits above SwiftUI, so SwiftUI z-ordering alone cannot prevent the flash.
        hidePortalViews(for: oldCardID)
        cancelPendingAgentLaunch(for: oldCardID, reason: "handoff")

        activateWorkspace(for: newCardID)

        guard let oldRecord = records[oldCardID],
              let focusedPanelID = oldRecord.workspace.focusedPanelId,
              oldRecord.workspace.panels[focusedPanelID] != nil else {
#if DEBUG
            dlog(
                "handoff.start.noPendingUnfocus oldCard=\(oldCardID.uuidString.prefix(5)) " +
                "reason=missingFocusedPanel selected=\(newCardID.uuidString.prefix(5))"
            )
#endif
            completePendingCardUnfocus(selectedCardID: newCardID)
            return
        }

        replacePendingCardUnfocusTarget(
            with: (cardID: oldCardID, panelID: focusedPanelID),
            selectedCardID: newCardID
        )
    }

    func completeCardHandoff(retiringCardID: UUID?, selectedCardID: UUID?, reason: String) {
#if DEBUG
        dlog(
            "handoff.complete.begin retiring=\(retiringCardID?.uuidString.prefix(5) ?? "nil") " +
            "selected=\(selectedCardID?.uuidString.prefix(5) ?? "nil") reason=\(reason)"
        )
#endif
        if let retiringCardID {
            hidePortalViews(for: retiringCardID)
            suspendWorkspaceIfPossible(for: retiringCardID)
        }

        completePendingCardUnfocus(selectedCardID: selectedCardID)
#if DEBUG
        dlog(
            "handoff.complete.end retiring=\(retiringCardID?.uuidString.prefix(5) ?? "nil") " +
            "selected=\(selectedCardID?.uuidString.prefix(5) ?? "nil") reason=\(reason) " +
            "pendingUnfocus=\(pendingCardUnfocusTarget?.cardID.uuidString.prefix(5) ?? "nil")"
        )
#endif
    }

    func hidePortalViews(for cardID: UUID) {
        guard let record = records[cardID] else { return }
#if DEBUG
        dlog("handoff.hidePortals \(debugWorkspaceSummary(record))")
#endif
        record.workspace.hideAllTerminalPortalViews()
        record.workspace.hideAllBrowserPortalViews()
    }

    func suspendWorkspaceIfPossible(for cardID: UUID) {
        guard let record = records[cardID] else { return }
        guard record.detachedWindowID == nil else {
#if DEBUG
            dlog("handoff.suspend.skip \(debugWorkspaceSummary(record)) reason=detached")
#endif
            return
        }
        guard TmuxSessionManager.shared.isTmuxAvailable() else {
#if DEBUG
            dlog("handoff.suspend.skip \(debugWorkspaceSummary(record)) reason=tmuxUnavailable")
#endif
            return
        }
#if DEBUG
        dlog("handoff.suspend.begin \(debugWorkspaceSummary(record))")
#endif
        record.workspace.suspendAllTerminalSurfaces()
#if DEBUG
        dlog("handoff.suspend.end \(debugWorkspaceSummary(record))")
#endif
    }

    func killSessionForCard(_ cardID: UUID) {
        resetWorkspace(for: cardID)
        agentLaunchedForCard.remove(cardID)
        agentSessionRecordByCardID.removeValue(forKey: cardID)
        pendingAgentLaunchByCardID.removeValue(forKey: cardID)
        pendingWorktreeReady.removeValue(forKey: cardID)
    }

    func resetWorkspace(for cardID: UUID) {
        hidePortalViews(for: cardID)
        cancelPendingAgentLaunch(for: cardID, reason: "reset", clearRequest: true)
        if pendingCardUnfocusTarget?.cardID == cardID {
            pendingCardUnfocusTarget = nil
        }
        agentSessionRecordByCardID.removeValue(forKey: cardID)
        agentSessionMonitor?.removeCard(cardID)
        guard let record = records.removeValue(forKey: cardID) else { return }
#if DEBUG
        dlog("handoff.resetWorkspace \(debugWorkspaceSummary(record))")
#endif
        AppDelegate.shared?.unregister(cardID: cardID)
        _ = record.tabManager.detachWorkspace(tabId: cardID)
        record.workspace.teardownAllPanels()
    }

    var boardWindowTabManager: TabManager {
        mainBoardTabManager
    }

    func isDetached(cardID: UUID) -> Bool {
        records[cardID]?.detachedWindowID != nil
    }

    func detachedWindowID(for cardID: UUID) -> UUID? {
        records[cardID]?.detachedWindowID
    }

    func moveWorkspace(cardID: UUID, to destinationManager: TabManager, detachedWindowID: UUID?) -> Bool {
        guard var record = records[cardID] else { return false }

        if record.tabManager === destinationManager {
            record.detachedWindowID = detachedWindowID
            records[cardID] = record
            AppDelegate.shared?.register(tabManager: destinationManager, for: cardID, boardID: record.boardID)
            if detachedWindowID != nil {
                record.workspace.resumeAllTerminalSurfaces()
                schedulePendingAgentLaunchIfNeeded(for: cardID, immediate: true)
            }
#if DEBUG
            dlog("handoff.moveWorkspace.reuse \(debugWorkspaceSummary(record)) destDetached=\(detachedWindowID?.uuidString.prefix(5) ?? "nil")")
#endif
            return true
        }

        guard let workspace = record.tabManager.detachWorkspace(tabId: cardID) else {
            return false
        }

        destinationManager.attachWorkspace(workspace, select: true)
        record.tabManager = destinationManager
        record.detachedWindowID = detachedWindowID
        records[cardID] = record
        AppDelegate.shared?.register(tabManager: destinationManager, for: cardID, boardID: record.boardID)
        if detachedWindowID != nil {
            workspace.resumeAllTerminalSurfaces()
            schedulePendingAgentLaunchIfNeeded(for: cardID, immediate: true)
        }
#if DEBUG
        dlog("handoff.moveWorkspace.move \(debugWorkspaceSummary(record)) destDetached=\(detachedWindowID?.uuidString.prefix(5) ?? "nil")")
#endif
        return true
    }

    func attachWorkspaceToBoard(cardID: UUID, focus: Bool = true) -> Bool {
        guard moveWorkspace(cardID: cardID, to: mainBoardTabManager, detachedWindowID: nil) else {
            return false
        }

        if focus {
            activateWorkspace(for: cardID)
        }
        return true
    }

    func selectCardInBoard(for cardID: UUID) {
        guard let record = records[cardID] else { return }
        boardStore?.selectCard(cardID, in: record.boardID)
    }

    func switchAgent(for cardID: UUID, to agent: Agent) {
        guard let panel = targetTerminalPanel(for: cardID) else { return }
        cancelPendingAgentLaunch(for: cardID, reason: "switchAgent", clearRequest: true)
        launchAgent(
            agent: agent,
            for: cardID,
            on: panel,
            workingDirectory: currentWorkingDirectory(for: cardID),
            reason: .agentSwitch
        )
    }

    func worktreeReady(cardID: UUID, worktreePath: String, agent: Agent) {
        if var record = records[cardID] {
            record.workingDirectory = worktreePath
            records[cardID] = record
        }

        guard needsAgentLaunch(
            cardID: cardID,
            agent: agent,
            workingDirectory: worktreePath,
            reason: .worktreeReady
        ) else {
            pendingWorktreeReady.removeValue(forKey: cardID)
            return
        }

        guard let panel = targetTerminalPanel(for: cardID) else {
            pendingWorktreeReady[cardID] = (worktreePath, agent)
            return
        }

        pendingWorktreeReady.removeValue(forKey: cardID)
        queuePendingAgentLaunch(
            agent: agent,
            for: cardID,
            on: panel,
            workingDirectory: worktreePath,
            reason: .worktreeReady
        )
    }

    func terminateAllSessions() {
        let cardIDs = Array(records.keys)
        for cardID in cardIDs {
            resetWorkspace(for: cardID)
        }
        agentLaunchedForCard.removeAll()
        agentSessionRecordByCardID.removeAll()
        pendingAgentLaunchByCardID.removeAll()
        pendingWorktreeReady.removeAll()
    }

    func suspendAllTerminals() {
        guard TmuxSessionManager.shared.isTmuxAvailable() else { return }
        for record in records.values {
            record.workspace.suspendAllTerminalSurfaces()
        }
    }

    func resumeAllTerminals() {
        for record in records.values {
            record.workspace.resumeAllTerminalSurfaces()
        }
    }

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

    func allAgentSessionSnapshots() -> [AgentSessionSnapshot] {
        guard let boardStore else { return [] }

        return agentSessionRecordByCardID.values.compactMap { session in
            snapshot(for: session, boardStore: boardStore)
        }
    }

    func agentSessionSnapshot(for cardID: UUID) -> AgentSessionSnapshot? {
        guard let boardStore,
              let session = agentSessionRecordByCardID[cardID] else {
            return nil
        }

        return snapshot(for: session, boardStore: boardStore)
    }

    func handleRuntimeSignal(
        _ signal: AgentRuntimeSignal,
        agent: Agent,
        workspaceID: UUID,
        panelID: UUID
    ) {
        guard let session = agentSessionRecordByCardID[workspaceID] else {
            agentLifecycleDebugLog(
                "terminal.signal.ignore reason=missingSession signal=\(signal.rawValue) " +
                "agent=\(agent.runtimeID) workspace=\(workspaceID.uuidString) panel=\(panelID.uuidString)"
            )
            return
        }
        guard session.panelID == panelID else {
            agentLifecycleDebugLog(
                "terminal.signal.ignore reason=panelMismatch signal=\(signal.rawValue) " +
                "agent=\(agent.runtimeID) workspace=\(workspaceID.uuidString) expectedPanel=\(session.panelID.uuidString) " +
                "actualPanel=\(panelID.uuidString)"
            )
            return
        }
        guard session.agent == agent else {
            agentLifecycleDebugLog(
                "terminal.signal.ignore reason=agentMismatch signal=\(signal.rawValue) " +
                "workspace=\(workspaceID.uuidString) expectedAgent=\(session.agent.runtimeID) actualAgent=\(agent.runtimeID)"
            )
            return
        }
        agentLifecycleDebugLog(
            "terminal.signal.accept signal=\(signal.rawValue) agent=\(agent.runtimeID) " +
            "workspace=\(workspaceID.uuidString) panel=\(panelID.uuidString)"
        )
        agentSessionMonitor?.registerRuntimeSignal(signal, for: workspaceID)
    }

    private func completePendingCardUnfocus(selectedCardID: UUID?) {
        guard let pending = pendingCardUnfocusTarget else { return }

        guard Self.shouldUnfocusPendingCard(
            pendingCardID: pending.cardID,
            selectedCardID: selectedCardID
        ) else {
#if DEBUG
            dlog(
                "handoff.unfocus.skip card=\(pending.cardID.uuidString.prefix(5)) " +
                "panel=\(pending.panelID.uuidString.prefix(5)) selected=\(selectedCardID?.uuidString.prefix(5) ?? "nil")"
            )
#endif
            pendingCardUnfocusTarget = nil
            return
        }

        pendingCardUnfocusTarget = nil

        guard let record = records[pending.cardID],
              let panel = record.workspace.panels[pending.panelID] else {
#if DEBUG
            dlog(
                "handoff.unfocus.missing card=\(pending.cardID.uuidString.prefix(5)) " +
                "panel=\(pending.panelID.uuidString.prefix(5))"
            )
#endif
            return
        }

#if DEBUG
        dlog("handoff.unfocus.apply \(debugWorkspaceSummary(record)) targetPanel=\(pending.panelID.uuidString.prefix(5))")
#endif
        panel.unfocus()
    }

    private func replacePendingCardUnfocusTarget(
        with next: (cardID: UUID, panelID: UUID),
        selectedCardID: UUID?
    ) {
        if let current = pendingCardUnfocusTarget,
           current.cardID == next.cardID,
           current.panelID == next.panelID {
#if DEBUG
            dlog(
                "handoff.unfocus.replace.skip card=\(next.cardID.uuidString.prefix(5)) " +
                "panel=\(next.panelID.uuidString.prefix(5)) reason=sameTarget"
            )
#endif
            return
        }

        if let current = pendingCardUnfocusTarget {
            if Self.shouldUnfocusPendingCard(
                pendingCardID: current.cardID,
                selectedCardID: selectedCardID
            ),
               let record = records[current.cardID],
               let panel = record.workspace.panels[current.panelID] {
#if DEBUG
                dlog("handoff.unfocus.replace.flush \(debugWorkspaceSummary(record)) targetPanel=\(current.panelID.uuidString.prefix(5))")
#endif
                panel.unfocus()
            }
        }

        pendingCardUnfocusTarget = next
#if DEBUG
        dlog(
            "handoff.unfocus.replace card=\(next.cardID.uuidString.prefix(5)) " +
            "panel=\(next.panelID.uuidString.prefix(5)) selected=\(selectedCardID?.uuidString.prefix(5) ?? "nil")"
        )
#endif
    }

    private static func shouldUnfocusPendingCard(pendingCardID: UUID, selectedCardID: UUID?) -> Bool {
        selectedCardID != pendingCardID
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
        queuePendingAgentLaunch(
            agent: agent,
            for: record.cardID,
            on: panel,
            workingDirectory: record.workingDirectory,
            reason: .initialLaunch
        )
    }

    private func refreshAutoLaunchIfNeeded(for record: WorkspaceRecord, board: Board?, card: Card?) {
        let agent = card?.agent ?? board?.agent
        guard let agent else { return }
        if let pending = pendingWorktreeReady[record.cardID] {
            worktreeReady(cardID: record.cardID, worktreePath: pending.worktreePath, agent: pending.agent)
            return
        }
        if let worktreePath = card?.worktreePath {
            worktreeReady(cardID: record.cardID, worktreePath: worktreePath, agent: agent)
            return
        }
        launchAgentIfNeeded(agent, in: record)
    }

    private func needsAgentLaunch(
        cardID: UUID,
        agent: Agent,
        workingDirectory: String?,
        reason: AgentLaunchReason
    ) -> Bool {
        switch reason {
        case .initialLaunch:
            return !agentLaunchedForCard.contains(cardID)

        case .worktreeReady:
            guard agentLaunchedForCard.contains(cardID),
                  let session = agentSessionRecordByCardID[cardID] else {
                return true
            }
            return session.agent != agent || session.workingDirectory != workingDirectory

        case .agentSwitch:
            return true
        }
    }

    private func queuePendingAgentLaunch(
        agent: Agent,
        for cardID: UUID,
        on panel: TerminalPanel,
        workingDirectory: String?,
        reason: AgentLaunchReason
    ) {
        guard needsAgentLaunch(
            cardID: cardID,
            agent: agent,
            workingDirectory: workingDirectory,
            reason: reason
        ) else {
            pendingAgentLaunchByCardID.removeValue(forKey: cardID)
            return
        }

        if let existing = pendingAgentLaunchByCardID[cardID],
           existing.agent != agent || existing.panelID != panel.id || existing.workingDirectory != workingDirectory || existing.reason != reason {
            cancelPendingAgentLaunch(for: cardID, reason: "replaced")
        }

        if var pending = pendingAgentLaunchByCardID[cardID] {
            pending.panelID = panel.id
            pending.agent = agent
            pending.workingDirectory = workingDirectory
            pending.reason = reason
            pendingAgentLaunchByCardID[cardID] = pending
        } else {
            pendingAgentLaunchByCardID[cardID] = PendingAgentLaunch(
                cardID: cardID,
                panelID: panel.id,
                agent: agent,
                workingDirectory: workingDirectory,
                reason: reason
            )
        }

        schedulePendingAgentLaunchIfNeeded(for: cardID)
    }

    private func schedulePendingAgentLaunchIfNeeded(for cardID: UUID, immediate: Bool = false) {
        guard var pending = pendingAgentLaunchByCardID[cardID] else { return }
        guard pending.scheduledTask == nil else { return }
        guard let record = records[cardID] else { return }

        let isDetached = record.detachedWindowID != nil
        guard isDetached || activeCardID == cardID else {
            agentLifecycleDebugLog(
                "terminal.launch.skip reason=inactive card=\(cardID.uuidString) " +
                "agent=\(pending.agent.runtimeID) pendingReason=\(pending.reason.rawValue)"
            )
            return
        }

        let shouldLaunchImmediately = immediate || isDetached
        let launchDelay = autoLaunchDebounce
        let launchDelayMs =
            shouldLaunchImmediately
            ? 0
            : Int((Double(launchDelay.components.seconds) * 1_000) +
                (Double(launchDelay.components.attoseconds) / 1_000_000_000_000_000))
        pending.scheduleGeneration &+= 1
        let generation = pending.scheduleGeneration
        agentLifecycleDebugLog(
            "terminal.launch.schedule card=\(cardID.uuidString) panel=\(pending.panelID.uuidString) " +
            "agent=\(pending.agent.runtimeID) reason=\(pending.reason.rawValue) " +
            "delayMs=\(launchDelayMs)"
        )
        pending.scheduledTask = Task { [weak self] in
            if !shouldLaunchImmediately {
                try? await Task.sleep(for: launchDelay)
            }
            guard !Task.isCancelled else { return }
            await self?.performPendingAgentLaunch(for: cardID, generation: generation)
        }
        pendingAgentLaunchByCardID[cardID] = pending
    }

    private func cancelPendingAgentLaunch(for cardID: UUID, reason: String, clearRequest: Bool = false) {
        guard var pending = pendingAgentLaunchByCardID[cardID] else { return }
        pending.scheduledTask?.cancel()
        pending.scheduledTask = nil
        pending.scheduleGeneration &+= 1
        agentLifecycleDebugLog(
            "terminal.launch.cancel card=\(cardID.uuidString) panel=\(pending.panelID.uuidString) " +
            "agent=\(pending.agent.runtimeID) reason=\(reason)"
        )
        if clearRequest {
            pendingAgentLaunchByCardID.removeValue(forKey: cardID)
        } else {
            pendingAgentLaunchByCardID[cardID] = pending
        }
    }

    private func performPendingAgentLaunch(for cardID: UUID, generation: UInt64) async {
        guard let pending = pendingAgentLaunchByCardID[cardID],
              pending.scheduleGeneration == generation,
              let record = records[cardID] else {
            return
        }

        let isDetached = record.detachedWindowID != nil
        guard isDetached || activeCardID == cardID else {
            if var stalePending = pendingAgentLaunchByCardID[cardID],
               stalePending.scheduleGeneration == generation {
                stalePending.scheduledTask = nil
                pendingAgentLaunchByCardID[cardID] = stalePending
            }
            agentLifecycleDebugLog(
                "terminal.launch.skip reason=inactive card=\(cardID.uuidString) " +
                "agent=\(pending.agent.runtimeID) pendingReason=\(pending.reason.rawValue)"
            )
            return
        }
        guard needsAgentLaunch(
            cardID: cardID,
            agent: pending.agent,
            workingDirectory: pending.workingDirectory,
            reason: pending.reason
        ) else {
            pendingAgentLaunchByCardID.removeValue(forKey: cardID)
            return
        }

        let panel = record.workspace.terminalPanel(for: pending.panelID) ?? targetTerminalPanel(for: cardID)
        guard let panel else {
            if var stalePending = pendingAgentLaunchByCardID[cardID],
               stalePending.scheduleGeneration == generation {
                stalePending.scheduledTask = nil
                pendingAgentLaunchByCardID[cardID] = stalePending
            }
            return
        }

        pendingAgentLaunchByCardID.removeValue(forKey: cardID)
        launchAgent(
            agent: pending.agent,
            for: cardID,
            on: panel,
            workingDirectory: pending.workingDirectory,
            reason: pending.reason
        )
    }

    private func launchAgent(
        agent: Agent,
        for cardID: UUID,
        on panel: TerminalPanel,
        workingDirectory: String?,
        reason: AgentLaunchReason
    ) {
        guard let record = records[cardID] else { return }

        let sessionRecord = AgentSessionRecord(
            cardID: cardID,
            boardID: record.boardID,
            panelID: panel.id,
            tmuxSessionID: panel.tmuxSessionID,
            agent: agent,
            workingDirectory: workingDirectory
        )
        panel.surface.resetPendingUserDraftInput()
        panel.surface.onUserSubmit = { [weak self] in
            agentLifecycleDebugLog(
                "terminal.submit card=\(cardID.uuidString) panel=\(panel.id.uuidString) agent=\(agent.runtimeID)"
            )
            self?.agentSessionMonitor?.registerRuntimeSignal(.started, for: cardID)
        }

        let plan = AgentLauncher.plan(
            for: agent,
            cardID: cardID,
            boardID: record.boardID,
            panelID: panel.id,
            workingDirectory: workingDirectory,
            reason: reason,
            interruptExisting: reason == .agentSwitch || (reason == .worktreeReady && agentLaunchedForCard.contains(cardID))
        )
        agentLifecycleDebugLog(
            "terminal.plan card=\(cardID.uuidString) panel=\(panel.id.uuidString) agent=\(agent.runtimeID) " +
            "workspaceEnv=\(plan.environment["CMUX_WORKSPACE_ID"] ?? "nil") " +
            "surfaceEnv=\(plan.environment["CMUX_SURFACE_ID"] ?? "nil")"
        )

        let launchExecutor = self.launchExecutor
        let tmuxSessionID = panel.tmuxSessionID
        agentLifecycleDebugLog(
            "terminal.launch.begin card=\(cardID.uuidString) panel=\(panel.id.uuidString) agent=\(agent.runtimeID) " +
            "reason=\(reason.rawValue)"
        )

        Task {
            let start = ContinuousClock.now
            let didLaunch = await launchExecutor(plan, tmuxSessionID)
            let latency = start.duration(to: ContinuousClock.now)
            let latencyMs = Int((Double(latency.components.seconds) * 1_000) + (Double(latency.components.attoseconds) / 1_000_000_000_000_000))
            agentLifecycleDebugLog(
                "terminal.launch.end result=\(didLaunch ? "success" : "failure") card=\(cardID.uuidString) " +
                "panel=\(panel.id.uuidString) agent=\(agent.runtimeID) reason=\(reason.rawValue) latencyMs=\(latencyMs)"
            )
            guard didLaunch else {
                return
            }
            self.agentSessionRecordByCardID[cardID] = sessionRecord
            self.agentLaunchedForCard.insert(cardID)
            self.agentSessionMonitor?.registerLaunch(for: cardID)
        }
    }

    private func currentWorkingDirectory(for cardID: UUID) -> String? {
        guard let session = agentSessionRecordByCardID[cardID] else {
            return records[cardID]?.workingDirectory
        }
        return session.workingDirectory ?? records[cardID]?.workingDirectory
    }

    private func snapshot(
        for session: AgentSessionRecord,
        boardStore: BoardStore
    ) -> AgentSessionSnapshot? {
        guard let board = boardStore.board(for: session.boardID),
              let card = board.cards.first(where: { $0.id == session.cardID }) else {
            return nil
        }

        return AgentSessionSnapshot(
            cardID: session.cardID,
            boardID: session.boardID,
            cardTitle: card.title,
            column: card.column,
            agent: card.agent ?? board.agent,
            tmuxSessionID: session.tmuxSessionID
        )
    }
}
