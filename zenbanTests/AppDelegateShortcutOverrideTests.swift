import AppKit
import Bonsplit
import Testing
@testable import zenban

@Suite(.serialized)
@MainActor
struct AppDelegateShortcutOverrideTests {
    @Test
    func customShortcutOverrideConsumesCommandShiftR() throws {
        let appDelegate = AppDelegate()
        var invocationCount = 0
        var receivedCharactersIgnoringModifiers: String?

        appDelegate.zenbanShortcutOverrideHandler = { event in
            invocationCount += 1
            receivedCharactersIgnoringModifiers = event.charactersIgnoringModifiers?.lowercased()
            return true
        }

        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command, .shift],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                characters: "R",
                charactersIgnoringModifiers: "r",
                isARepeat: false,
                keyCode: 15
            )
        )

        #expect(appDelegate.debugHandleCustomShortcut(event: event))
        #expect(invocationCount == 1)
        #expect(receivedCharactersIgnoringModifiers == "r")
    }

    @Test
    func previewShortcutFocusDetectionRecognizesFocusedPreview() throws {
        let (boardStore, board, card) = makeBoardFixture()
        let (hostStore, window) = makeHostStore(boardStore: boardStore)
        defer {
            window.close()
        }

        boardStore.startDevServerDirect(card: card, setup: nil, dev: "npm run dev")
        hostStore.syncSelection(card: card, boardID: board.id)
        hostStore.ensureBrowserSurface(for: card, boardID: board.id, url: URL(string: "http://localhost:5173")!)
        hostStore.focusBrowserSurface(for: card.id)
        let context = try #require(hostStore.browserSurface(for: card.id))
        context.panel.webView.frame = window.contentView?.bounds ?? .zero
        context.panel.webView.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(context.panel.webView)
        window.makeKeyAndOrderFront(nil)
        #expect(window.makeFirstResponder(context.panel.webView))
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))

        #expect(isPreviewWebViewFocused(event: try makeCommandShiftCEvent(window: window), context: context))
    }

    @Test
    func previewConsoleShortcutHandleDecisionAllowsFocusedDevtoolsPanel() {
        #expect(
            shouldHandlePreviewConsoleShortcut(
                previewWebViewFocused: false,
                developerToolsVisible: true,
                previewPanelIsFocusedBrowser: true
            )
        )
        #expect(
            !shouldHandlePreviewConsoleShortcut(
                previewWebViewFocused: false,
                developerToolsVisible: true,
                previewPanelIsFocusedBrowser: false
            )
        )
    }

    @Test
    func commandShiftCDoesNotHandleWithoutPreviewSurface() throws {
        let appDelegate = AppDelegate()
        let (boardStore, board, card) = makeBoardFixture()
        let (hostStore, window) = makeHostStore(boardStore: boardStore)
        defer {
            window.close()
            _ = appDelegate
        }

        boardStore.startDevServerDirect(card: card, setup: nil, dev: "npm run dev")
        hostStore.syncSelection(card: card, boardID: board.id)
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))

        appDelegate.tabManager = hostStore.tabManager

        #expect(
            !handleZenbanShortcutOverride(
                event: try makeCommandShiftCEvent(window: window),
                store: boardStore,
                cmuxHost: hostStore,
                appDelegate: appDelegate
            )
        )
    }

    @Test
    func commandShiftCDoesNotHandleWhenAnotherBrowserIsFocused() throws {
        let appDelegate = AppDelegate()
        let firstCard = Card(title: "preview", column: .todo, orderIndex: 0, agent: .claude, worktreePath: "/tmp/preview")
        let secondCard = Card(title: "other", column: .todo, orderIndex: 1, agent: .claude, worktreePath: "/tmp/other")
        let board = Board(
            name: "Board",
            cards: [firstCard, secondCard],
            repositoryPath: "/tmp/repo",
            agent: .claude
        )
        let boardStore = makeBoardStore(board: board, selectedCardID: firstCard.id)
        let (hostStore, window) = makeHostStore(boardStore: boardStore)
        defer {
            window.close()
            _ = appDelegate
        }

        boardStore.startDevServerDirect(card: firstCard, setup: nil, dev: "npm run dev")

        hostStore.syncSelection(card: firstCard, boardID: board.id)
        hostStore.ensureBrowserSurface(for: firstCard, boardID: board.id, url: URL(string: "http://localhost:5173")!)

        hostStore.syncSelection(card: secondCard, boardID: board.id)
        hostStore.ensureBrowserSurface(for: secondCard, boardID: board.id, url: URL(string: "http://localhost:4173")!)
        hostStore.focusBrowserSurface(for: secondCard.id)
        let secondContext = try #require(hostStore.browserSurface(for: secondCard.id))
        secondContext.panel.webView.frame = window.contentView?.bounds ?? .zero
        secondContext.panel.webView.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(secondContext.panel.webView)
        window.makeKeyAndOrderFront(nil)
        #expect(window.makeFirstResponder(secondContext.panel.webView))
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))

        appDelegate.tabManager = hostStore.tabManager

        #expect(
            !handleZenbanShortcutOverride(
                event: try makeCommandShiftCEvent(window: window),
                store: boardStore,
                cmuxHost: hostStore,
                appDelegate: appDelegate
            )
        )
    }

    @Test
    func typeScopedCloseClosesFocusedTerminalWhenMultipleTerminalsExist() throws {
        let (boardStore, board, card) = makeBoardFixture()
        let (hostStore, window) = makeHostStore(boardStore: boardStore)
        defer {
            window.close()
        }

        hostStore.syncSelection(card: card, boardID: board.id)
        let workspace = try #require(hostStore.workspace(for: card.id))
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let terminalPanel = try #require(workspace.newTerminalSurface(inPane: paneId, focus: true))

        #expect(workspace.focusedPanelId == terminalPanel.id)
        #expect(panelCount(of: .terminal, in: workspace) == 2)

        #expect(hostStore.handleTypeScopedCloseShortcut(forSelectedCardID: boardStore.selectedCardID))

        RunLoop.main.run(until: Date().addingTimeInterval(0.01))

        #expect(panelCount(of: .terminal, in: workspace) == 1)
        #expect(workspace.panels[terminalPanel.id] == nil)
    }

    @Test
    func typeScopedCloseConsumesFocusedTerminalWhenItIsLastTerminal() throws {
        let (boardStore, board, card) = makeBoardFixture()
        let (hostStore, window) = makeHostStore(boardStore: boardStore)
        defer {
            window.close()
        }

        hostStore.syncSelection(card: card, boardID: board.id)
        let workspace = try #require(hostStore.workspace(for: card.id))
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let previewURL = try #require(URL(string: "http://localhost:5173"))
        _ = try #require(workspace.newBrowserSurface(inPane: paneId, url: previewURL, focus: false))
        let panelIDsBeforeShortcut = Set(workspace.panels.keys)

        #expect(workspace.focusedTerminalPanel != nil)
        #expect(panelCount(of: .terminal, in: workspace) == 1)
        #expect(panelCount(of: .browser, in: workspace) == 1)

        #expect(hostStore.handleTypeScopedCloseShortcut(forSelectedCardID: boardStore.selectedCardID))

        RunLoop.main.run(until: Date().addingTimeInterval(0.01))

        #expect(Set(workspace.panels.keys) == panelIDsBeforeShortcut)
        #expect(panelCount(of: .terminal, in: workspace) == 1)
        #expect(panelCount(of: .browser, in: workspace) == 1)
    }

    @Test
    func commandWClosesFocusedBrowserWhenMultipleBrowsersExist() throws {
        let appDelegate = AppDelegate()
        let (boardStore, board, card) = makeBoardFixture()
        let (hostStore, window) = makeHostStore(boardStore: boardStore)
        defer {
            window.close()
            _ = appDelegate
        }

        hostStore.syncSelection(card: card, boardID: board.id)
        let workspace = try #require(hostStore.workspace(for: card.id))
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let firstURL = try #require(URL(string: "http://localhost:5173"))
        let secondURL = try #require(URL(string: "http://localhost:4173"))
        _ = try #require(workspace.newBrowserSurface(inPane: paneId, url: firstURL, focus: true))
        let browserPanel = try #require(workspace.newBrowserSurface(inPane: paneId, url: secondURL, focus: true))

        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))

        #expect(workspace.focusedPanelId == browserPanel.id)
        #expect(panelCount(of: .browser, in: workspace) == 2)

        #expect(
            handleZenbanShortcutOverride(
                event: try makeCommandWEvent(window: window),
                store: boardStore,
                cmuxHost: hostStore,
                appDelegate: appDelegate
            )
        )

        RunLoop.main.run(until: Date().addingTimeInterval(0.01))

        #expect(panelCount(of: .browser, in: workspace) == 1)
        #expect(workspace.panels[browserPanel.id] == nil)
    }

    @Test
    func typeScopedCloseConsumesFocusedBrowserWhenItIsLastBrowser() throws {
        let (boardStore, board, card) = makeBoardFixture()
        let (hostStore, window) = makeHostStore(boardStore: boardStore)
        defer {
            window.close()
        }

        hostStore.syncSelection(card: card, boardID: board.id)
        let workspace = try #require(hostStore.workspace(for: card.id))
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let previewURL = try #require(URL(string: "http://localhost:5173"))
        let browserPanel = try #require(workspace.newBrowserSurface(inPane: paneId, url: previewURL, focus: true))
        let panelIDsBeforeShortcut = Set(workspace.panels.keys)

        #expect(workspace.focusedPanelId == browserPanel.id)
        #expect(panelCount(of: .browser, in: workspace) == 1)
        #expect(panelCount(of: .terminal, in: workspace) == 1)

        #expect(hostStore.handleTypeScopedCloseShortcut(forSelectedCardID: boardStore.selectedCardID))

        RunLoop.main.run(until: Date().addingTimeInterval(0.01))

        #expect(Set(workspace.panels.keys) == panelIDsBeforeShortcut)
        #expect(panelCount(of: .browser, in: workspace) == 1)
        #expect(panelCount(of: .terminal, in: workspace) == 1)
    }

    @Test
    func commandWFileBrowserPreflightStillPostsCloseRequest() throws {
        let (boardStore, _, card) = makeBoardFixture()
        boardStore.overlayState = .fileBrowser(cardID: card.id)
        var closeRequestCount = 0

        #expect(
            handleZenbanFileBrowserCloseShortcut(
                event: try makeCommandWEvent(),
                store: boardStore
            ) {
                closeRequestCount += 1
            }
        )
        #expect(closeRequestCount == 1)
    }

    @Test
    func commandShiftReturnRemainsUnchangedByZenbanOverride() throws {
        let appDelegate = AppDelegate()
        let (boardStore, _, _) = makeBoardFixture()
        let hostStore = CmuxHostStore()
        boardStore.cmuxHost = hostStore
        hostStore.attach(boardStore: boardStore)

        #expect(
            !handleZenbanShortcutOverride(
                event: try makeCommandShiftReturnEvent(),
                store: boardStore,
                cmuxHost: hostStore,
                appDelegate: appDelegate
            )
        )
    }

    private func makeBoardFixture() -> (BoardStore, Board, Card) {
        let card = Card(title: "Preview", column: .todo, orderIndex: 0, agent: .claude, worktreePath: "/tmp/preview")
        let board = Board(name: "Board", cards: [card], repositoryPath: "/tmp/repo", agent: .claude)
        let boardStore = makeBoardStore(board: board, selectedCardID: card.id)
        return (boardStore, board, card)
    }

    private func makeBoardStore(board: Board, selectedCardID: UUID?) -> BoardStore {
        let boardStore = BoardStore()
        boardStore.boards = [board]
        boardStore.selectedBoardID = board.id
        boardStore.selectedCardID = selectedCardID
        return boardStore
    }

    private func makeHostStore(boardStore: BoardStore) -> (CmuxHostStore, NSWindow) {
        let hostStore = CmuxHostStore()
        boardStore.cmuxHost = hostStore
        hostStore.attach(boardStore: boardStore)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        hostStore.registerMainWindow(window)
        return (hostStore, window)
    }

    private func makeCommandShiftCEvent(window: NSWindow? = nil) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command, .shift],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window?.windowNumber ?? 0,
                context: nil,
                characters: "C",
                charactersIgnoringModifiers: "c",
                isARepeat: false,
                keyCode: 8
            )
        )
    }

    private func makeCommandWEvent(window: NSWindow? = nil) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window?.windowNumber ?? 0,
                context: nil,
                characters: "w",
                charactersIgnoringModifiers: "w",
                isARepeat: false,
                keyCode: 13
            )
        )
    }

    private func makeCommandShiftReturnEvent(window: NSWindow? = nil) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command, .shift],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window?.windowNumber ?? 0,
                context: nil,
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                isARepeat: false,
                keyCode: 36
            )
        )
    }

    private func panelCount(of panelType: PanelType, in workspace: Workspace) -> Int {
        workspace.panels.values.filter { $0.panelType == panelType }.count
    }
}
