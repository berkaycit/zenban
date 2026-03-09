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

    enum TerminalManagerError: Error {
        case workspaceUnavailable
    }

    private var records: [UUID: WorkspaceRecord] = [:]
    private var agentLaunchedForCard: Set<UUID> = []
    private var agentSessionRecordByCardID: [UUID: AgentSessionRecord] = [:]
    private var pendingWorktreeReady: [UUID: (worktreePath: String, agent: Agent)] = [:]
    private var pendingCardUnfocusTarget: (cardID: UUID, panelID: UUID)?
    private var activeCardID: UUID?
    private let mainBoardTabManager = TabManager(
        createsInitialWorkspace: false,
        keepsBootstrapWorkspaceWhenEmpty: false
    )

    weak var boardStore: BoardStore?
    weak var agentSessionMonitor: AgentSessionMonitor?

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

    func workspaceRecord(for cardID: UUID, boardID: UUID, cardTitle: String) -> WorkspaceRecord {
        if var record = records[cardID] {
            if record.cardTitle != cardTitle {
                record.cardTitle = cardTitle
                record.workspace.setCustomTitle(cardTitle)
                AppDelegate.shared?.updateWorkspaceTitle(for: cardID, title: cardTitle)
            }
            let board = boardStore?.board(for: boardID)
            let card = board?.cards.first { $0.id == cardID }
            let updatedWorkingDirectory = card?.worktreePath ?? board?.repositoryPath
            if record.workingDirectory != updatedWorkingDirectory {
                record.workingDirectory = updatedWorkingDirectory
            }
            records[cardID] = record
#if DEBUG
            dlog("handoff.workspaceRecord.reuse \(debugWorkspaceSummary(record)) title=\(cardTitle)")
#endif
            return record
        }

        let board = boardStore?.board(for: boardID)
        let card = board?.cards.first { $0.id == cardID }
        let agent = card?.agent ?? board?.agent
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

        let isGitRepo = board?.repositoryPath.map { GitService.isGitRepository(path: $0) } ?? false
        if let agent, !isGitRepo {
            launchAgentIfNeeded(agent, in: record)
        } else if let pending = pendingWorktreeReady[cardID] {
            worktreeReady(cardID: cardID, worktreePath: pending.worktreePath, agent: pending.agent)
        } else if isGitRepo,
                  let worktreePath = card?.worktreePath,
                  let agent {
            worktreeReady(cardID: cardID, worktreePath: worktreePath, agent: agent)
        }

        if let updated = records[cardID] {
            record = updated
        }
        return record
    }

    func activateWorkspace(for cardID: UUID) {
        guard let record = records[cardID] else { return }

        // Skip redundant activation to prevent first-responder churn
        // when rapid card switches cause multiple activate calls for the same card.
        guard activeCardID != cardID else {
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
#if DEBUG
        dlog("handoff.activate.end \(debugWorkspaceSummary(record))")
#endif
    }

    func deactivateWorkspace(for cardID: UUID) {
        if activeCardID == cardID {
            activeCardID = nil
        }
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
        pendingWorktreeReady.removeValue(forKey: cardID)
    }

    func resetWorkspace(for cardID: UUID) {
        hidePortalViews(for: cardID)
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
        boardStore?.selectedBoardID = record.boardID
        boardStore?.selectedCardID = cardID
        boardStore?.focusRegion = .cards
    }

    func switchAgent(for cardID: UUID, to agent: Agent) {
        guard let panel = targetTerminalPanel(for: cardID) else { return }
        launchAgent(
            agent: agent,
            for: cardID,
            on: panel,
            workingDirectory: currentWorkingDirectory(for: cardID),
            reason: .agentSwitch
        )
    }

    func worktreeReady(cardID: UUID, worktreePath: String, agent: Agent) {
        guard !agentLaunchedForCard.contains(cardID) else {
            pendingWorktreeReady.removeValue(forKey: cardID)
            return
        }
        if var record = records[cardID] {
            record.workingDirectory = worktreePath
            records[cardID] = record
        }

        guard let panel = targetTerminalPanel(for: cardID) else {
            pendingWorktreeReady[cardID] = (worktreePath, agent)
            return
        }

        pendingWorktreeReady.removeValue(forKey: cardID)
        agentLaunchedForCard.insert(cardID)
        launchAgent(
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
        agentLaunchedForCard.insert(record.cardID)
        launchAgent(
            agent: agent,
            for: record.cardID,
            on: panel,
            workingDirectory: record.workingDirectory,
            reason: .initialLaunch
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

        agentSessionRecordByCardID[cardID] = AgentSessionRecord(
            cardID: cardID,
            boardID: record.boardID,
            panelID: panel.id,
            tmuxSessionID: panel.tmuxSessionID,
            agent: agent,
            workingDirectory: workingDirectory
        )

        let plan = AgentLauncher.plan(
            for: agent,
            cardID: cardID,
            boardID: record.boardID,
            workingDirectory: workingDirectory,
            reason: reason
        )

        Task { @MainActor in
            await AgentLauncher.launch(plan, on: panel)
            self.agentSessionMonitor?.registerLaunch(for: cardID)
        }
    }

    private func currentWorkingDirectory(for cardID: UUID) -> String? {
        guard let session = agentSessionRecordByCardID[cardID] else {
            return records[cardID]?.workingDirectory
        }
        return session.workingDirectory ?? records[cardID]?.workingDirectory
    }
}
