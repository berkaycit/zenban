import AppKit
import Testing
@testable import zenban

@Suite(.serialized)
@MainActor
struct AppDelegateEmbeddedHostTests {
    @Test
    func embeddedZenbanRegistrationDoesNotRestoreStandaloneSessionWindows() {
        let previousShared = AppDelegate.shared
        let appDelegate = AppDelegate()
        let window = makeWindow()
        defer {
            cleanup(appDelegate: appDelegate, window: window, previousShared: previousShared)
        }

        appDelegate.setHostBundleIdentifierForTesting(SocketControlSettings.zenbanBundleIdentifier)
        appDelegate.setStartupSessionSnapshotForTesting(makeSessionSnapshot(windowCount: 2))

        appDelegate.registerMainWindow(
            window,
            windowId: UUID(),
            tabManager: TabManager(),
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState()
        )

        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        #expect(appDelegate.scriptableMainWindows().count == 1)
    }

    @Test
    func embeddedZenbanHostDisablesStandaloneSessionPersistenceAndAutosave() {
        let previousShared = AppDelegate.shared
        let appDelegate = AppDelegate()
        let window = makeWindow()
        defer {
            cleanup(appDelegate: appDelegate, window: window, previousShared: previousShared)
        }

        appDelegate.setHostBundleIdentifierForTesting(SocketControlSettings.zenbanBundleIdentifier)
        appDelegate.registerMainWindow(
            window,
            windowId: UUID(),
            tabManager: TabManager(),
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState()
        )

        #expect(!appDelegate.saveSessionSnapshotForTesting(includeScrollback: false))

        appDelegate.startSessionAutosaveTimerForTesting()

        #expect(!appDelegate.hasSessionAutosaveTimerForTesting())
    }

    @Test
    func embeddedZenbanHostPreventsStandaloneWindowCreationFallbacks() {
        let previousShared = AppDelegate.shared
        let appDelegate = AppDelegate()
        defer {
            cleanup(appDelegate: appDelegate, window: nil, previousShared: previousShared)
        }

        appDelegate.setHostBundleIdentifierForTesting(SocketControlSettings.zenbanBundleIdentifier)

        #expect(appDelegate.createMainWindow() == nil)

        appDelegate.showNotificationsPopoverFromMenuBar()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        #expect(appDelegate.scriptableMainWindows().isEmpty)
    }

    private func cleanup(appDelegate: AppDelegate, window: NSWindow?, previousShared: AppDelegate?) {
        if let window {
            appDelegate.unregisterMainWindowForTesting(window)
            window.orderOut(nil)
        }
        appDelegate.resetApplicationTerminationHooksForTesting()
        AppDelegate.shared = previousShared
    }

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
    }

    private func makeSessionSnapshot(windowCount: Int) -> AppSessionSnapshot {
        let panelID = UUID()
        let panel = SessionPanelSnapshot(
            id: panelID,
            type: .terminal,
            title: "Shell",
            customTitle: nil,
            directory: "/tmp",
            isPinned: false,
            isManuallyUnread: false,
            gitBranch: nil,
            listeningPorts: [],
            ttyName: nil,
            terminal: SessionTerminalPanelSnapshot(workingDirectory: "/tmp", scrollback: nil),
            browser: nil,
            markdown: nil
        )
        let workspace = SessionWorkspaceSnapshot(
            processTitle: "Shell",
            customTitle: nil,
            customColor: nil,
            isPinned: false,
            currentDirectory: "/tmp",
            focusedPanelId: panelID,
            layout: .pane(.init(panelIds: [panelID], selectedPanelId: panelID)),
            panels: [panel],
            statusEntries: [],
            logEntries: [],
            progress: nil,
            gitBranch: nil
        )
        let window = SessionWindowSnapshot(
            frame: nil,
            display: nil,
            tabManager: SessionTabManagerSnapshot(selectedWorkspaceIndex: 0, workspaces: [workspace]),
            sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: 240)
        )
        return AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: Date().timeIntervalSince1970,
            windows: Array(repeating: window, count: windowCount)
        )
    }
}
