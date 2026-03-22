import Foundation
import Testing
@testable import zenban

struct BoardStoreTerminalFullscreenTests {
    @MainActor
    @Test
    func toggleTerminalFullscreenTracksSelectedCard() {
        let card = Card(title: "Terminal", orderIndex: 0)
        let board = Board(name: "Board", cards: [card])
        let store = makeStore(board: board, selectedCardID: card.id)

        #expect(store.toggleTerminalFullscreen(for: card.id, in: board.id))
        #expect(store.terminalFullscreenCardID == card.id)
        #expect(store.isTerminalFullscreenActive(for: card.id))

        #expect(store.toggleTerminalFullscreen(for: card.id, in: board.id))
        #expect(store.terminalFullscreenCardID == nil)
    }

    @MainActor
    @Test
    func overlayPresentationClearsTerminalFullscreen() {
        let card = Card(title: "Terminal", orderIndex: 0)
        let board = Board(name: "Board", cards: [card])
        let store = makeStore(board: board, selectedCardID: card.id)

        #expect(store.toggleTerminalFullscreen(for: card.id, in: board.id))

        store.overlayState = .fileBrowser(cardID: card.id)

        #expect(store.terminalFullscreenCardID == nil)
    }

    @MainActor
    @Test
    func changingSelectedCardClearsTerminalFullscreen() {
        let first = Card(title: "First", orderIndex: 0)
        let second = Card(title: "Second", orderIndex: 1)
        let board = Board(name: "Board", cards: [first, second])
        let store = makeStore(board: board, selectedCardID: first.id)

        #expect(store.toggleTerminalFullscreen(for: first.id, in: board.id))

        store.selectedCardID = second.id

        #expect(store.terminalFullscreenCardID == nil)
    }

    @MainActor
    @Test
    func changingSelectedBoardClearsTerminalFullscreen() {
        let firstCard = Card(title: "First", orderIndex: 0)
        let firstBoard = Board(name: "First", cards: [firstCard])
        let secondBoard = Board(name: "Second", cards: [])
        let store = BoardStore(initialBoards: [firstBoard, secondBoard], persistenceEnabled: false)
        store.selectedBoardID = firstBoard.id
        store.selectedCardID = firstCard.id

        #expect(store.toggleTerminalFullscreen(for: firstCard.id, in: firstBoard.id))

        store.selectedBoardID = secondBoard.id

        #expect(store.terminalFullscreenCardID == nil)
    }

    @MainActor
    @Test
    func movingCardToDoneClearsTerminalFullscreen() {
        let card = Card(title: "Terminal", orderIndex: 0)
        let board = Board(name: "Board", cards: [card])
        let store = makeStore(board: board, selectedCardID: card.id)

        #expect(store.toggleTerminalFullscreen(for: card.id, in: board.id))

        #expect(store.moveCard(card.id, to: .done, in: board.id))
        #expect(store.terminalFullscreenCardID == nil)
    }

    @MainActor
    @Test
    func deletingSelectedCardClearsTerminalFullscreen() {
        let card = Card(title: "Terminal", orderIndex: 0)
        let board = Board(name: "Board", cards: [card])
        let store = makeStore(board: board, selectedCardID: card.id)

        #expect(store.toggleTerminalFullscreen(for: card.id, in: board.id))

        store.deleteCard(card.id, from: board.id)

        #expect(store.terminalFullscreenCardID == nil)
    }

    @MainActor
    @Test
    func deletingSelectedBoardClearsTerminalFullscreen() {
        let firstCard = Card(title: "Terminal", orderIndex: 0)
        let firstBoard = Board(name: "First", cards: [firstCard])
        let secondBoard = Board(name: "Second", cards: [])
        let store = BoardStore(initialBoards: [firstBoard, secondBoard], persistenceEnabled: false)
        store.selectedBoardID = firstBoard.id
        store.selectedCardID = firstCard.id

        #expect(store.toggleTerminalFullscreen(for: firstCard.id, in: firstBoard.id))

        store.deleteBoard(firstBoard)

        #expect(store.terminalFullscreenCardID == nil)
        #expect(store.selectedBoardID == secondBoard.id)
    }

    @MainActor
    private func makeStore(board: Board, selectedCardID: UUID?) -> BoardStore {
        let store = BoardStore(initialBoards: [board], persistenceEnabled: false)
        store.selectedBoardID = board.id
        store.selectedCardID = selectedCardID
        return store
    }
}
