import AppKit
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
}
