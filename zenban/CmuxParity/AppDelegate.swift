import AppKit
import Bonsplit
import Foundation

struct WorkspaceMoveTarget: Identifiable {
    let windowId: UUID
    let workspaceId: UUID
    let windowLabel: String
    let workspaceTitle: String
    let tabManager: TabManager
    let isCurrentWindow: Bool

    var id: UUID { workspaceId }
    var label: String {
        isCurrentWindow ? workspaceTitle : "\(workspaceTitle) (\(windowLabel))"
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    private struct CardContext {
        let cardID: UUID
        let boardID: UUID
        let tabManager: TabManager
    }

    private var contextsByCardID: [UUID: CardContext] = [:]
    private var cardIDByWorkspaceID: [UUID: UUID] = [:]
    private var jumpUnreadFocusExpectation: (tabId: UUID, surfaceId: UUID)?
    private var jumpUnreadFocusObserver: NSObjectProtocol?
    private let mainWindowID = UUID()

    weak var terminalManager: TerminalManager?
    weak var notificationStore: TerminalNotificationStore?
    private(set) var activeCardID: UUID?

    var tabManager: TabManager? {
        if let activeCardID, let context = contextsByCardID[activeCardID] {
            return context.tabManager
        }
        return contextsByCardID.values.first?.tabManager
    }

    override init() {
        super.init()
        notificationStore = TerminalNotificationStore.shared
        Self.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
        notificationStore = TerminalNotificationStore.shared
        Self.shared = self
        TerminalController.shared.startIfNeeded()
        if let activeCardID, let context = contextsByCardID[activeCardID] {
            TerminalController.shared.setActiveTabManager(context.tabManager)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        _ = notification
        if let jumpUnreadFocusObserver {
            NotificationCenter.default.removeObserver(jumpUnreadFocusObserver)
            self.jumpUnreadFocusObserver = nil
        }
        TerminalController.shared.stop()
    }

    func register(tabManager: TabManager, for cardID: UUID, boardID: UUID) {
        contextsByCardID[cardID] = CardContext(cardID: cardID, boardID: boardID, tabManager: tabManager)
        cardIDByWorkspaceID[cardID] = cardID
        if activeCardID == nil {
            activeCardID = cardID
            TerminalController.shared.setActiveTabManager(tabManager)
        } else if activeCardID == cardID {
            TerminalController.shared.setActiveTabManager(tabManager)
        }
    }

    func unregister(cardID: UUID) {
        guard let context = contextsByCardID.removeValue(forKey: cardID) else { return }
        cardIDByWorkspaceID.removeValue(forKey: context.cardID)
        if activeCardID == cardID {
            if let replacementID = contextsByCardID.keys.sorted(by: { $0.uuidString < $1.uuidString }).first,
               let replacement = contextsByCardID[replacementID] {
                activeCardID = replacementID
                TerminalController.shared.setActiveTabManager(replacement.tabManager)
            } else {
                activeCardID = nil
                TerminalController.shared.setActiveTabManager(nil)
            }
        }
    }

    func activateCard(_ cardID: UUID) {
        guard contextsByCardID[cardID] != nil else { return }
        activeCardID = cardID
        TerminalController.shared.setActiveTabManager(contextsByCardID[cardID]?.tabManager)
    }

    func deactivateCard(_ cardID: UUID) {
        guard activeCardID == cardID else { return }
        if let replacement = contextsByCardID.keys.first(where: { $0 != cardID }) {
            activateCard(replacement)
        } else {
            activeCardID = nil
            TerminalController.shared.setActiveTabManager(nil)
        }
    }

    func tabManagerFor(windowId: UUID) -> TabManager? {
        windowId == mainWindowID ? tabManager : nil
    }

    func tabManagerFor(tabId: UUID) -> TabManager? {
        if let cardID = cardIDByWorkspaceID[tabId] {
            return contextsByCardID[cardID]?.tabManager
        }
        for context in contextsByCardID.values where context.tabManager.tabs.contains(where: { $0.id == tabId }) {
            return context.tabManager
        }
        return nil
    }

    func windowId(for tabManager: TabManager) -> UUID? {
        contextsByCardID.values.contains(where: { $0.tabManager === tabManager }) ? mainWindowID : nil
    }

    func mainWindow(for windowId: UUID) -> NSWindow? {
        guard windowId == mainWindowID else { return nil }
        return NSApp.keyWindow ?? NSApp.mainWindow
    }

    func isCommandPaletteVisible(for window: NSWindow) -> Bool {
        _ = window
        return false
    }

    func focusMainWindow(windowId: UUID) -> Bool {
        guard let window = mainWindow(for: windowId) else { return false }
        window.makeKeyAndOrderFront(nil)
        return true
    }

    func createMainWindow() -> UUID {
        mainWindowID
    }

    func closeMainWindow(windowId: UUID) -> Bool {
        guard windowId == mainWindowID else { return false }
        return false
    }

    func closeMainWindowContainingTabId(_ tabId: UUID) {
        terminalManager?.resetWorkspace(for: tabId)
        if tabId == activeCardID {
            terminalManager?.activateWorkspace(for: tabId)
        }
    }

    func workspaceMoveTargets(excludingWorkspaceId: UUID? = nil, referenceWindowId: UUID?) -> [WorkspaceMoveTarget] {
        _ = referenceWindowId
        return contextsByCardID.values.compactMap { context in
            guard let workspace = context.tabManager.tabs.first(where: { $0.id == context.cardID }) else {
                return nil
            }
            guard workspace.id != excludingWorkspaceId else { return nil }
            return WorkspaceMoveTarget(
                windowId: mainWindowID,
                workspaceId: workspace.id,
                windowLabel: "Zenban",
                workspaceTitle: workspace.title,
                tabManager: context.tabManager,
                isCurrentWindow: true
            )
        }
    }

    @discardableResult
    func moveSurface(
        panelId: UUID,
        toWorkspace targetWorkspaceId: UUID,
        targetPane: PaneID? = nil,
        targetIndex: Int? = nil,
        splitTarget: (orientation: SplitOrientation, insertFirst: Bool)? = nil,
        focus: Bool = true,
        focusWindow: Bool = true
    ) -> Bool {
        _ = targetIndex
        _ = focusWindow
        guard let source = workspaceContainingPanel(panelId: panelId),
              source.workspace.id == targetWorkspaceId else {
            return false
        }
        if let splitTarget {
            return source.workspace.newTerminalSplit(
                from: panelId,
                orientation: splitTarget.orientation,
                insertFirst: splitTarget.insertFirst,
                focus: focus
            ) != nil
        }
        guard let targetPane else { return false }
        return source.workspace.moveSurface(panelId: panelId, toPane: targetPane, atIndex: targetIndex, focus: focus)
    }

    @discardableResult
    func moveBonsplitTab(
        tabId: UUID,
        toWorkspace workspaceId: UUID,
        targetPane: PaneID,
        targetIndex: Int? = nil,
        splitTarget: (orientation: SplitOrientation, insertFirst: Bool)? = nil,
        focus: Bool = true,
        focusWindow: Bool = true
    ) -> Bool {
        guard let source = locateBonsplitSurface(tabId: tabId) else { return false }
        return moveSurface(
            panelId: source.panelId,
            toWorkspace: workspaceId,
            targetPane: targetPane,
            targetIndex: targetIndex,
            splitTarget: splitTarget,
            focus: focus,
            focusWindow: focusWindow
        )
    }

    func locateBonsplitSurface(tabId: UUID) -> (windowId: UUID, workspaceId: UUID, panelId: UUID, tabManager: TabManager)? {
        let bonsplitTabId = TabID(uuid: tabId)
        for context in contextsByCardID.values {
            for workspace in context.tabManager.tabs {
                if let panelId = workspace.panelIdFromSurfaceId(bonsplitTabId) {
                    return (mainWindowID, workspace.id, panelId, context.tabManager)
                }
            }
        }
        return nil
    }

    func locateSurface(surfaceId: UUID) -> (windowId: UUID, workspaceId: UUID, tabManager: TabManager)? {
        for context in contextsByCardID.values {
            for workspace in context.tabManager.tabs where workspace.panels[surfaceId] != nil {
                return (mainWindowID, workspace.id, context.tabManager)
            }
        }
        return nil
    }

    func workspaceContainingPanel(
        panelId: UUID,
        preferredWorkspaceId: UUID? = nil
    ) -> (workspace: Workspace, tabManager: TabManager)? {
        if let preferredWorkspaceId,
           let manager = tabManagerFor(tabId: preferredWorkspaceId),
           let workspace = manager.tabs.first(where: { $0.id == preferredWorkspaceId }),
           workspace.panels[panelId] != nil {
            return (workspace, manager)
        }

        for context in contextsByCardID.values {
            for workspace in context.tabManager.tabs where workspace.panels[panelId] != nil {
                return (workspace, context.tabManager)
            }
        }

        return nil
    }

    func refreshTerminalSurfacesAfterGhosttyConfigReload(source: String) {
        var refreshedCount = 0
        forEachTerminalPanel { terminalPanel in
            terminalPanel.hostedView.reconcileGeometryNow()
            terminalPanel.surface.forceRefresh()
            refreshedCount += 1
        }
        dlog("reload.config.surfaceRefresh source=\(source) count=\(refreshedCount)")
    }

    func armJumpUnreadFocusRecord(tabId: UUID, surfaceId: UUID) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CMUX_UI_TEST_JUMP_UNREAD_PATH"], !path.isEmpty else { return }
        _ = path
        jumpUnreadFocusExpectation = (tabId: tabId, surfaceId: surfaceId)
        installJumpUnreadFocusObserverIfNeeded()
    }

    func recordJumpUnreadFocusIfExpected(tabId: UUID, surfaceId: UUID) {
        guard let expectation = jumpUnreadFocusExpectation else { return }
        guard expectation.tabId == tabId && expectation.surfaceId == surfaceId else { return }
        jumpUnreadFocusExpectation = nil
        if let jumpUnreadFocusObserver {
            NotificationCenter.default.removeObserver(jumpUnreadFocusObserver)
            self.jumpUnreadFocusObserver = nil
        }
    }

    @discardableResult
    func handleBrowserSurfaceKeyEquivalent(_ event: NSEvent) -> Bool {
        guard let shortcut = StoredShortcut.from(event: event),
              let manager = tabManager,
              let workspace = manager.selectedWorkspace,
              let focusedPanelId = workspace.focusedPanelId else {
            return false
        }

        func matches(_ action: KeyboardShortcutSettings.Action) -> Bool {
            shortcut == KeyboardShortcutSettings.shortcut(for: action)
        }

        if matches(.splitRight) {
            return manager.newSplit(tabId: workspace.id, surfaceId: focusedPanelId, direction: .right) != nil
        }
        if matches(.splitDown) {
            return manager.newSplit(tabId: workspace.id, surfaceId: focusedPanelId, direction: .down) != nil
        }
        if matches(.focusLeft) {
            return manager.moveSplitFocus(tabId: workspace.id, surfaceId: focusedPanelId, direction: .left)
        }
        if matches(.focusRight) {
            return manager.moveSplitFocus(tabId: workspace.id, surfaceId: focusedPanelId, direction: .right)
        }
        if matches(.focusUp) {
            return manager.moveSplitFocus(tabId: workspace.id, surfaceId: focusedPanelId, direction: .up)
        }
        if matches(.focusDown) {
            return manager.moveSplitFocus(tabId: workspace.id, surfaceId: focusedPanelId, direction: .down)
        }
        if matches(.toggleSplitZoom) {
            return manager.toggleSplitZoom(tabId: workspace.id, surfaceId: focusedPanelId)
        }
        if matches(.nextSurface) {
            manager.selectNextSurface()
            return true
        }
        if matches(.prevSurface) {
            manager.selectPreviousSurface()
            return true
        }
        if matches(.newSurface) {
            return workspace.newTerminalSurfaceInFocusedPane() != nil
        }
        if matches(.openBrowser),
           let paneId = workspace.bonsplitController.focusedPaneId {
            return manager.newBrowserSurface(tabId: workspace.id, inPane: paneId) != nil
        }
        if matches(.splitBrowserRight) {
            return workspace.newBrowserSplit(from: focusedPanelId, orientation: .horizontal) != nil
        }
        if matches(.splitBrowserDown) {
            return workspace.newBrowserSplit(from: focusedPanelId, orientation: .vertical) != nil
        }
        if matches(.toggleBrowserDeveloperTools) {
            return manager.toggleDeveloperToolsFocusedBrowser()
        }
        if matches(.showBrowserJavaScriptConsole) {
            return manager.showJavaScriptConsoleFocusedBrowser()
        }
        return false
    }

    private func installJumpUnreadFocusObserverIfNeeded() {
        guard jumpUnreadFocusObserver == nil else { return }
        jumpUnreadFocusObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyDidFocusSurface,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID else { return }
            guard let surfaceId = notification.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID else { return }
            self.recordJumpUnreadFocusIfExpected(tabId: tabId, surfaceId: surfaceId)
        }
    }

    private func forEachTerminalPanel(_ body: (TerminalPanel) -> Void) {
        var seenManagers: Set<ObjectIdentifier> = []
        for context in contextsByCardID.values {
            let managerID = ObjectIdentifier(context.tabManager)
            guard seenManagers.insert(managerID).inserted else { continue }
            for workspace in context.tabManager.tabs {
                for panel in workspace.panels.values {
                    if let terminalPanel = panel as? TerminalPanel {
                        body(terminalPanel)
                    }
                }
            }
        }
    }
}
