import AppKit
import Bonsplit
import Combine
import Foundation
import SwiftUI

struct CommandPaletteDebugResultRow {
    let commandId: String
    let title: String
    let shortcutHint: String?
    let trailingLabel: String?
    let score: Int
}

struct CommandPaletteDebugSnapshot {
    let query: String
    let mode: String
    let results: [CommandPaletteDebugResultRow]

    static let empty = CommandPaletteDebugSnapshot(query: "", mode: "commands", results: [])
}

struct WorkspaceMoveTarget: Identifiable {
    let windowId: UUID
    let workspaceId: UUID
    let windowLabel: String
    let workspaceTitle: String
    let tabManager: TabManager
    let isCurrentWindow: Bool

    var id: String { "\(windowId.uuidString):\(workspaceId.uuidString)" }
    var label: String {
        isCurrentWindow ? workspaceTitle : "\(workspaceTitle) (\(windowLabel))"
    }
}

private final class DetachedTerminalWindowController: NSObject, NSWindowDelegate {
    let windowId: UUID
    weak var appDelegate: AppDelegate?
    let window: NSWindow

    init(windowId: UUID, appDelegate: AppDelegate, window: NSWindow) {
        self.windowId = windowId
        self.appDelegate = appDelegate
        self.window = window
        super.init()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        _ = notification
        appDelegate?.detachedWindowDidBecomeKey(windowId: windowId)
    }

    func windowDidBecomeMain(_ notification: Notification) {
        _ = notification
        appDelegate?.detachedWindowDidBecomeKey(windowId: windowId)
    }

    func windowWillClose(_ notification: Notification) {
        _ = notification
        appDelegate?.handleDetachedWindowClose(windowId: windowId)
    }
}

private final class DetachedWindowContext {
    let windowId: UUID
    let tabManager: TabManager
    let controller: DetachedTerminalWindowController
    weak var window: NSWindow?
    var cardID: UUID?
    var reattachOnClose = true

    init(
        windowId: UUID,
        tabManager: TabManager,
        controller: DetachedTerminalWindowController,
        window: NSWindow
    ) {
        self.windowId = windowId
        self.tabManager = tabManager
        self.controller = controller
        self.window = window
    }
}

private struct DetachedTerminalWindowRootView: View {
    let windowId: UUID
    let cardID: UUID?

    @Environment(TerminalManager.self) private var terminalManager
    @State private var observedWindowNumber: Int?
    @State private var isKeyWindow = false

    var body: some View {
        Group {
            if let cardID,
               let record = terminalManager.record(forWorkspaceID: cardID) {
                WorkspaceContentView(
                    workspace: record.workspace,
                    isWorkspaceVisible: true,
                    isWorkspaceInputActive: isKeyWindow && (NSApp?.isActive ?? false),
                    workspacePortalPriority: 2,
                    onThemeRefreshRequest: nil
                )
                .onAppear {
                    terminalManager.activateWorkspace(for: cardID)
                }
            } else {
                ContentUnavailableView(
                    "Detached Terminal",
                    systemImage: "rectangle.on.rectangle",
                    description: Text("Move a card workspace into this window to start using it.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .background(
            WindowAccessor(dedupeByWindow: false) { window in
                observedWindowNumber = window.windowNumber
                isKeyWindow = window.isKeyWindow
            }
        )
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  window.windowNumber == observedWindowNumber else {
                return
            }
            isKeyWindow = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  window.windowNumber == observedWindowNumber else {
                return
            }
            isKeyWindow = false
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    struct MainWindowSummary {
        let windowId: UUID
        let isKeyWindow: Bool
        let isVisible: Bool
        let workspaceCount: Int
        let selectedWorkspaceId: UUID?
    }

    private struct CardContext {
        let cardID: UUID
        let boardID: UUID
        let tabManager: TabManager
    }

    static weak var shared: AppDelegate?

    private var contextsByCardID: [UUID: CardContext] = [:]
    private var cardIDByWorkspaceID: [UUID: UUID] = [:]
    private var jumpUnreadFocusExpectation: (tabId: UUID, surfaceId: UUID)?
    private var jumpUnreadFocusObserver: NSObjectProtocol?
    private let mainWindowID = UUID()
    private weak var mainAppWindow: NSWindow?
    private var mainBoardTabManager: TabManager?
    private var detachedWindowContexts: [UUID: DetachedWindowContext] = [:]
    private var detachedWindowIDByCardID: [UUID: UUID] = [:]
    private var commandPaletteVisibilityByWindowId: [UUID: Bool] = [:]
    private var commandPaletteSelectionByWindowId: [UUID: Int] = [:]
    private var commandPaletteSnapshotByWindowId: [UUID: CommandPaletteDebugSnapshot] = [:]
    private var tabManagerSelectionObservers: [ObjectIdentifier: AnyCancellable] = [:]
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var activeWindowID: UUID?
    private var browserAddressBarFocusedPanelId: UUID?

    weak var terminalManager: TerminalManager? {
        didSet {
            if let terminalManager {
                registerMainBoardTabManager(terminalManager.boardWindowTabManager)
            }
        }
    }
    private(set) var activeCardID: UUID?

    var tabManager: TabManager? {
        if let activeCardID, let context = contextsByCardID[activeCardID] {
            return context.tabManager
        }
        if let activeWindowID, let manager = tabManagerFor(windowId: activeWindowID) {
            return manager
        }
        return mainBoardTabManager
    }

    override init() {
        super.init()
        Self.shared = self
        installLifecycleObservers()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
        Self.shared = self
        if let terminalManager {
            registerMainBoardTabManager(terminalManager.boardWindowTabManager)
        }
        startSocketControllerIfPossible()
        if let activeCardID {
            activateCard(activeCardID)
        } else if let mainBoardTabManager {
            TerminalController.shared.setActiveTabManager(mainBoardTabManager)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        _ = notification
        if let jumpUnreadFocusObserver {
            NotificationCenter.default.removeObserver(jumpUnreadFocusObserver)
            self.jumpUnreadFocusObserver = nil
        }
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        lifecycleObservers.removeAll()
        TerminalController.shared.stop()
    }

    func registerMainBoardTabManager(_ tabManager: TabManager) {
        mainBoardTabManager = tabManager
        observeSelection(for: tabManager)
        startSocketControllerIfPossible()
        if activeWindowID == nil {
            activeWindowID = mainWindowID
        }
        if activeCardID == nil {
            TerminalController.shared.setActiveTabManager(tabManager)
        }
    }

    func registerMainAppWindow(_ window: NSWindow) {
        mainAppWindow = window
        if window.isKeyWindow || activeWindowID == nil {
            setActiveWindow(mainWindowID)
        }
    }

    func register(tabManager: TabManager, for cardID: UUID, boardID: UUID) {
        contextsByCardID[cardID] = CardContext(cardID: cardID, boardID: boardID, tabManager: tabManager)
        cardIDByWorkspaceID[cardID] = cardID
        observeSelection(for: tabManager)

        if tabManager === mainBoardTabManager {
            detachedWindowIDByCardID.removeValue(forKey: cardID)
        } else if let windowId = windowId(for: tabManager),
                  let context = detachedWindowContexts[windowId] {
            context.cardID = cardID
            detachedWindowIDByCardID[cardID] = windowId
            updateDetachedWindow(windowId: windowId)
        }

        if activeCardID == nil {
            activateCard(cardID)
        } else if activeCardID == cardID {
            TerminalController.shared.setActiveTabManager(tabManager)
        }
    }

    func unregister(cardID: UUID) {
        guard let context = contextsByCardID.removeValue(forKey: cardID) else { return }
        cardIDByWorkspaceID.removeValue(forKey: context.cardID)

        if let windowId = detachedWindowIDByCardID.removeValue(forKey: cardID),
           let detached = detachedWindowContexts[windowId] {
            detached.cardID = nil
            updateDetachedWindow(windowId: windowId)
            closeDetachedWindowIfEmpty(windowId: windowId, reattachOnClose: false)
        }

        if activeCardID == cardID {
            clearActiveCard()
        }
    }

    func updateWorkspaceTitle(for cardID: UUID, title: String) {
        guard let windowId = detachedWindowIDByCardID[cardID] else { return }
        updateDetachedWindowTitle(windowId: windowId, fallbackTitle: title)
    }

    func activateCard(_ cardID: UUID) {
        guard let context = contextsByCardID[cardID] else { return }
        activeCardID = cardID
        if context.tabManager.selectedTabId != cardID,
           let workspace = context.tabManager.tabs.first(where: { $0.id == cardID }) {
            context.tabManager.selectWorkspace(workspace)
        }
        if context.tabManager === mainBoardTabManager {
            terminalManager?.selectCardInBoard(for: cardID)
            setActiveWindow(mainWindowID)
        } else if let windowId = detachedWindowIDByCardID[cardID] {
            setActiveWindow(windowId)
        }
        TerminalController.shared.setActiveTabManager(context.tabManager)
    }

    func clearActiveCard() {
        activeCardID = nil
        if let activeWindowID,
           let manager = tabManagerFor(windowId: activeWindowID) {
            TerminalController.shared.setActiveTabManager(manager)
        } else {
            TerminalController.shared.setActiveTabManager(mainBoardTabManager)
        }
    }

    func deactivateCard(_ cardID: UUID) {
        guard activeCardID == cardID else { return }
        clearActiveCard()
    }

    func listMainWindowSummaries() -> [MainWindowSummary] {
        var summaries: [MainWindowSummary] = []

        if let mainWindow = mainAppWindow ?? NSApp.mainWindow ?? NSApp.keyWindow {
            let selectedWorkspaceId = activeWindowID == mainWindowID ? mainBoardTabManager?.selectedTabId : nil
            summaries.append(
                MainWindowSummary(
                    windowId: mainWindowID,
                    isKeyWindow: mainWindow.isKeyWindow,
                    isVisible: mainWindow.isVisible,
                    workspaceCount: mainBoardTabManager?.tabs.count ?? 0,
                    selectedWorkspaceId: selectedWorkspaceId
                )
            )
        } else if mainBoardTabManager != nil {
            summaries.append(
                MainWindowSummary(
                    windowId: mainWindowID,
                    isKeyWindow: activeWindowID == mainWindowID,
                    isVisible: true,
                    workspaceCount: mainBoardTabManager?.tabs.count ?? 0,
                    selectedWorkspaceId: activeWindowID == mainWindowID ? mainBoardTabManager?.selectedTabId : nil
                )
            )
        }

        for context in detachedWindowContexts.values.sorted(by: { $0.windowId.uuidString < $1.windowId.uuidString }) {
            let window = context.window ?? context.controller.window
            summaries.append(
                MainWindowSummary(
                    windowId: context.windowId,
                    isKeyWindow: window.isKeyWindow,
                    isVisible: window.isVisible,
                    workspaceCount: context.cardID == nil ? 0 : context.tabManager.tabs.count,
                    selectedWorkspaceId: context.cardID
                )
            )
        }

        return summaries
    }

    func tabManagerFor(windowId: UUID) -> TabManager? {
        if windowId == mainWindowID {
            return mainBoardTabManager
        }
        return detachedWindowContexts[windowId]?.tabManager
    }

    func tabManagerFor(tabId: UUID) -> TabManager? {
        if let cardID = cardIDByWorkspaceID[tabId],
           let context = contextsByCardID[cardID] {
            return context.tabManager
        }
        if let mainBoardTabManager,
           mainBoardTabManager.tabs.contains(where: { $0.id == tabId }) {
            return mainBoardTabManager
        }
        for context in detachedWindowContexts.values where context.tabManager.tabs.contains(where: { $0.id == tabId }) {
            return context.tabManager
        }
        return nil
    }

    func windowId(for tabManager: TabManager) -> UUID? {
        if let mainBoardTabManager, mainBoardTabManager === tabManager {
            return mainWindowID
        }
        return detachedWindowContexts.values.first(where: { $0.tabManager === tabManager })?.windowId
    }

    func mainWindow(for windowId: UUID) -> NSWindow? {
        if windowId == mainWindowID {
            return mainAppWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
        }
        return detachedWindowContexts[windowId]?.window ?? detachedWindowContexts[windowId]?.controller.window
    }

    func isCommandPaletteVisible(windowId: UUID) -> Bool {
        commandPaletteVisibilityByWindowId[windowId] ?? false
    }

    func commandPaletteSelectionIndex(windowId: UUID) -> Int {
        commandPaletteSelectionByWindowId[windowId] ?? 0
    }

    func commandPaletteSnapshot(windowId: UUID) -> CommandPaletteDebugSnapshot {
        commandPaletteSnapshotByWindowId[windowId] ?? .empty
    }

    func isCommandPaletteVisible(for window: NSWindow) -> Bool {
        guard let windowId = mainWindowId(for: window) else { return false }
        return isCommandPaletteVisible(windowId: windowId)
    }

    func focusMainWindow(windowId: UUID) -> Bool {
        guard let window = mainWindow(for: windowId) else { return false }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        if TerminalController.socketCommandAllowsInAppFocusMutations() {
            NSApp.activate(ignoringOtherApps: true)
        }
        setActiveWindow(windowId)
        return true
    }

    func createMainWindow() -> UUID {
        let windowId = UUID()
        let tabManager = TabManager(
            createsInitialWorkspace: false,
            keepsBootstrapWorkspaceWhenEmpty: false
        )
        observeSelection(for: tabManager)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.center()

        let controller = DetachedTerminalWindowController(windowId: windowId, appDelegate: self, window: window)
        let context = DetachedWindowContext(
            windowId: windowId,
            tabManager: tabManager,
            controller: controller,
            window: window
        )
        detachedWindowContexts[windowId] = context
        window.delegate = controller

        updateDetachedWindow(windowId: windowId)
        window.makeKeyAndOrderFront(nil)
        if TerminalController.socketCommandAllowsInAppFocusMutations() {
            NSApp.activate(ignoringOtherApps: true)
        }
        setActiveWindow(windowId)
        return windowId
    }

    func closeMainWindow(windowId: UUID) -> Bool {
        guard windowId != mainWindowID else { return false }
        return closeDetachedWindowIfPresent(windowId: windowId, reattachOnClose: true)
    }

    func closeMainWindowContainingTabId(_ tabId: UUID) {
        guard let manager = tabManagerFor(tabId: tabId),
              let windowId = windowId(for: manager) else {
            terminalManager?.resetWorkspace(for: tabId)
            return
        }

        if windowId == mainWindowID {
            terminalManager?.resetWorkspace(for: tabId)
        } else {
            _ = closeDetachedWindowIfPresent(windowId: windowId, reattachOnClose: true)
        }
    }

    func workspaceMoveTargets(excludingWorkspaceId: UUID? = nil, referenceWindowId: UUID?) -> [WorkspaceMoveTarget] {
        let orderedSummaries = orderedMainWindowSummaries(referenceWindowId: referenceWindowId)
        let labels = windowLabelsById(orderedSummaries: orderedSummaries, referenceWindowId: referenceWindowId)

        var targets: [WorkspaceMoveTarget] = []
        for summary in orderedSummaries {
            guard let manager = tabManagerFor(windowId: summary.windowId) else { continue }
            let windowLabel = labels[summary.windowId] ?? "Window"
            let isCurrentWindow = summary.windowId == referenceWindowId

            for workspace in manager.tabs where workspace.id != excludingWorkspaceId {
                targets.append(
                    WorkspaceMoveTarget(
                        windowId: summary.windowId,
                        workspaceId: workspace.id,
                        windowLabel: windowLabel,
                        workspaceTitle: workspace.title,
                        tabManager: manager,
                        isCurrentWindow: isCurrentWindow
                    )
                )
            }
        }
        return targets
    }

    @discardableResult
    func moveWorkspaceToWindow(workspaceId: UUID, windowId: UUID, focus: Bool = true) -> Bool {
        guard let terminalManager,
              let sourceManager = tabManagerFor(tabId: workspaceId),
              let sourceWindowId = self.windowId(for: sourceManager) else {
            return false
        }

        if windowId == sourceWindowId {
            if focus {
                activateCard(workspaceId)
                _ = focusMainWindow(windowId: windowId)
            }
            return true
        }

        if windowId == mainWindowID {
            guard terminalManager.attachWorkspaceToBoard(cardID: workspaceId, focus: focus) else {
                return false
            }
            detachedWindowIDByCardID.removeValue(forKey: workspaceId)
            if let sourceDetached = detachedWindowContexts[sourceWindowId] {
                sourceDetached.cardID = nil
                updateDetachedWindow(windowId: sourceWindowId)
                closeDetachedWindowIfEmpty(windowId: sourceWindowId, reattachOnClose: false)
            }
            if focus {
                _ = focusMainWindow(windowId: mainWindowID)
            }
            return true
        }

        guard let destinationContext = detachedWindowContexts[windowId] else {
            return false
        }
        if let occupiedCardID = destinationContext.cardID, occupiedCardID != workspaceId {
            return false
        }
        guard terminalManager.moveWorkspace(
            cardID: workspaceId,
            to: destinationContext.tabManager,
            detachedWindowID: windowId
        ) else {
            return false
        }

        if sourceWindowId != mainWindowID,
           let sourceDetached = detachedWindowContexts[sourceWindowId],
           sourceWindowId != windowId {
            sourceDetached.cardID = nil
            updateDetachedWindow(windowId: sourceWindowId)
            closeDetachedWindowIfEmpty(windowId: sourceWindowId, reattachOnClose: false)
        }

        destinationContext.cardID = workspaceId
        detachedWindowIDByCardID[workspaceId] = windowId
        updateDetachedWindow(windowId: windowId)

        if focus {
            activateCard(workspaceId)
            _ = focusMainWindow(windowId: windowId)
        } else {
            TerminalController.shared.setActiveTabManager(destinationContext.tabManager)
        }
        return true
    }

    @discardableResult
    func moveWorkspaceToNewWindow(workspaceId: UUID, focus: Bool = true) -> UUID? {
        let windowId = createMainWindow()
        guard moveWorkspaceToWindow(workspaceId: workspaceId, windowId: windowId, focus: focus) else {
            _ = closeDetachedWindowIfPresent(windowId: windowId, reattachOnClose: false)
            return nil
        }
        return windowId
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
        for manager in allTabManagers() {
            guard let windowId = windowId(for: manager) else { continue }
            for workspace in manager.tabs {
                if let panelId = workspace.panelIdFromSurfaceId(bonsplitTabId) {
                    return (windowId, workspace.id, panelId, manager)
                }
            }
        }
        return nil
    }

    func locateSurface(surfaceId: UUID) -> (windowId: UUID, workspaceId: UUID, tabManager: TabManager)? {
        for manager in allTabManagers() {
            guard let windowId = windowId(for: manager) else { continue }
            for workspace in manager.tabs where workspace.panels[surfaceId] != nil {
                return (windowId, workspace.id, manager)
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

        if let located = locateSurface(surfaceId: panelId),
           let workspace = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }) {
            return (workspace, located.tabManager)
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
        if matches(.toggleBrowserDeveloperTools) {
            return manager.toggleDeveloperToolsFocusedBrowser()
        }
        if matches(.showBrowserJavaScriptConsole) {
            return manager.showJavaScriptConsoleFocusedBrowser()
        }
        return false
    }

    func sidebarVisibility(windowId: UUID) -> Bool? {
        if windowId == mainWindowID {
            return nil
        }
        return false
    }

    @objc func openNewMainWindow(_ sender: Any?) {
        _ = sender
        _ = createMainWindow()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        _ = notification
        if let keyWindow = NSApp.keyWindow ?? NSApp.mainWindow,
           let windowId = mainWindowId(for: keyWindow) {
            setActiveWindow(windowId)
        } else if activeWindowID == nil {
            setActiveWindow(mainWindowID)
        }
    }

    func focusedBrowserAddressBarPanelId() -> UUID? {
        browserAddressBarFocusedPanelId
    }

#if DEBUG
    func debugHandleCustomShortcut(event: NSEvent) -> Bool {
        handleBrowserSurfaceKeyEquivalent(event)
    }
#endif

    func detachedWindowDidBecomeKey(windowId: UUID) {
        setActiveWindow(windowId)
        if let cardID = detachedWindowContexts[windowId]?.cardID {
            activeCardID = cardID
        }
    }

    func handleDetachedWindowClose(windowId: UUID) {
        guard let context = detachedWindowContexts.removeValue(forKey: windowId) else { return }
        let cardID = context.cardID

        if let cardID {
            detachedWindowIDByCardID.removeValue(forKey: cardID)
            if context.reattachOnClose {
                _ = terminalManager?.attachWorkspaceToBoard(cardID: cardID, focus: false)
            }
        }

        if activeWindowID == windowId {
            activeWindowID = mainWindowID
            if let mainBoardTabManager {
                TerminalController.shared.setActiveTabManager(mainBoardTabManager)
                if let selectedWorkspaceId = mainBoardTabManager.selectedTabId,
                   contextsByCardID[selectedWorkspaceId] != nil {
                    activeCardID = selectedWorkspaceId
                    terminalManager?.selectCardInBoard(for: selectedWorkspaceId)
                } else {
                    activeCardID = nil
                }
            } else {
                TerminalController.shared.setActiveTabManager(nil)
                activeCardID = nil
            }
        }
    }

    private func installLifecycleObservers() {
        lifecycleObservers.append(
            NotificationCenter.default.addObserver(
                forName: .browserDidFocusAddressBar,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.browserAddressBarFocusedPanelId = notification.object as? UUID
            }
        )
        lifecycleObservers.append(
            NotificationCenter.default.addObserver(
                forName: .browserDidBlurAddressBar,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self else { return }
                guard let panelId = notification.object as? UUID else { return }
                guard browserAddressBarFocusedPanelId == panelId else { return }
                browserAddressBarFocusedPanelId = nil
            }
        )
    }

    private func startSocketControllerIfPossible() {
        guard let mainBoardTabManager else { return }
        let storedMode = UserDefaults.standard.string(forKey: SocketControlSettings.appStorageKey)
            ?? SocketControlSettings.defaultMode.rawValue
        let accessMode = SocketControlSettings.migrateMode(storedMode)
        guard accessMode != .off else {
            TerminalController.shared.stop()
            return
        }
        TerminalController.shared.start(
            tabManager: mainBoardTabManager,
            socketPath: SocketControlSettings.socketPath(),
            accessMode: accessMode
        )
    }

    private func observeSelection(for tabManager: TabManager) {
        let identifier = ObjectIdentifier(tabManager)
        guard tabManagerSelectionObservers[identifier] == nil else { return }
        tabManagerSelectionObservers[identifier] = tabManager.$selectedTabId.sink { [weak self, weak tabManager] selectedTabId in
            guard let self, let tabManager else { return }
            Task { @MainActor in
                self.handleSelectionChange(selectedTabId: selectedTabId, in: tabManager)
            }
        }
    }

    private func handleSelectionChange(selectedTabId: UUID?, in tabManager: TabManager) {
        guard let windowId = windowId(for: tabManager) else { return }
        if windowId == mainWindowID, let selectedTabId, contextsByCardID[selectedTabId] != nil {
            terminalManager?.selectCardInBoard(for: selectedTabId)
        }
        guard activeWindowID == windowId else { return }
        guard let selectedTabId, contextsByCardID[selectedTabId] != nil else {
            if activeWindowID == mainWindowID {
                activeCardID = nil
            }
            return
        }
        activeCardID = selectedTabId
    }

    private func mainWindowId(for window: NSWindow) -> UUID? {
        if mainAppWindow === window {
            return mainWindowID
        }
        if window === NSApp.keyWindow || window === NSApp.mainWindow,
           mainAppWindow == nil {
            return mainWindowID
        }
        return detachedWindowContexts.values.first(where: { $0.window === window || $0.controller.window === window })?.windowId
    }

    private func setActiveWindow(_ windowId: UUID) {
        activeWindowID = windowId
        guard let manager = tabManagerFor(windowId: windowId) else {
            TerminalController.shared.setActiveTabManager(nil)
            return
        }
        TerminalController.shared.setActiveTabManager(manager)
        if let selectedWorkspaceId = manager.selectedTabId,
           contextsByCardID[selectedWorkspaceId] != nil {
            activeCardID = selectedWorkspaceId
            if windowId == mainWindowID {
                terminalManager?.selectCardInBoard(for: selectedWorkspaceId)
            }
        } else if windowId == mainWindowID {
            activeCardID = nil
        }
    }

    private func allTabManagers() -> [TabManager] {
        var managers: [TabManager] = []
        var seen: Set<ObjectIdentifier> = []

        if let mainBoardTabManager {
            let id = ObjectIdentifier(mainBoardTabManager)
            if seen.insert(id).inserted {
                managers.append(mainBoardTabManager)
            }
        }

        for context in detachedWindowContexts.values {
            let id = ObjectIdentifier(context.tabManager)
            if seen.insert(id).inserted {
                managers.append(context.tabManager)
            }
        }

        return managers
    }

    private func closeDetachedWindowIfPresent(windowId: UUID, reattachOnClose: Bool) -> Bool {
        guard let context = detachedWindowContexts[windowId] else { return false }
        context.reattachOnClose = reattachOnClose
        (context.window ?? context.controller.window).performClose(nil)
        return true
    }

    private func closeDetachedWindowIfEmpty(windowId: UUID, reattachOnClose: Bool) {
        guard let context = detachedWindowContexts[windowId],
              context.cardID == nil || context.tabManager.tabs.isEmpty else {
            return
        }
        _ = closeDetachedWindowIfPresent(windowId: windowId, reattachOnClose: reattachOnClose)
    }

    private func updateDetachedWindow(windowId: UUID) {
        guard let context = detachedWindowContexts[windowId] else { return }
        let rootView: AnyView

        if let terminalManager {
            rootView = AnyView(
                DetachedTerminalWindowRootView(windowId: windowId, cardID: context.cardID)
                    .environment(terminalManager)
            )
        } else {
            rootView = AnyView(
                ContentUnavailableView(
                    "Detached Terminal",
                    systemImage: "rectangle.on.rectangle",
                    description: Text("Terminal host is still starting.")
                )
            )
        }

        (context.window ?? context.controller.window).contentView = NSHostingView(rootView: rootView)
        updateDetachedWindowTitle(windowId: windowId)
    }

    private func updateDetachedWindowTitle(windowId: UUID, fallbackTitle: String? = nil) {
        guard let context = detachedWindowContexts[windowId] else { return }
        let title: String
        if let cardID = context.cardID,
           let record = terminalManager?.record(forWorkspaceID: cardID) {
            title = record.cardTitle
        } else if let fallbackTitle {
            title = fallbackTitle
        } else {
            title = "Detached Terminal"
        }
        (context.window ?? context.controller.window).title = title
    }

    private func orderedMainWindowSummaries(referenceWindowId: UUID?) -> [MainWindowSummary] {
        listMainWindowSummaries().sorted { lhs, rhs in
            let lhsIsReference = lhs.windowId == referenceWindowId
            let rhsIsReference = rhs.windowId == referenceWindowId
            if lhsIsReference != rhsIsReference { return lhsIsReference }
            if lhs.isKeyWindow != rhs.isKeyWindow { return lhs.isKeyWindow }
            if lhs.isVisible != rhs.isVisible { return lhs.isVisible }
            return lhs.windowId.uuidString < rhs.windowId.uuidString
        }
    }

    private func windowLabelsById(orderedSummaries: [MainWindowSummary], referenceWindowId: UUID?) -> [UUID: String] {
        var labels: [UUID: String] = [:]
        for (index, summary) in orderedSummaries.enumerated() {
            if summary.windowId == referenceWindowId {
                labels[summary.windowId] = "Current Window"
            } else if summary.windowId == mainWindowID {
                labels[summary.windowId] = "Zenban"
            } else {
                labels[summary.windowId] = "Window \(index + 1)"
            }
        }
        return labels
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
        for manager in allTabManagers() {
            let managerID = ObjectIdentifier(manager)
            guard seenManagers.insert(managerID).inserted else { continue }
            for workspace in manager.tabs {
                for panel in workspace.panels.values {
                    if let terminalPanel = panel as? TerminalPanel {
                        body(terminalPanel)
                    }
                }
            }
        }
    }
}
