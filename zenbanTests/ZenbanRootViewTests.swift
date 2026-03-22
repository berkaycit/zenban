import Testing
@testable import zenban

struct ZenbanRootViewTests {
    @Test
    func shouldPresentTerminalFullscreenWhenSelectedCardMatches() {
        let card = Card(title: "Terminal", orderIndex: 0)
        let board = Board(name: "Board", cards: [card])

        #expect(
            ZenbanRootView.shouldPresentTerminalFullscreen(
                selectedBoard: board,
                selectedCard: card,
                terminalFullscreenCardID: card.id
            )
        )
    }

    @Test
    func shouldNotPresentTerminalFullscreenWhenFullscreenClears() {
        let card = Card(title: "Terminal", orderIndex: 0)
        let board = Board(name: "Board", cards: [card])

        #expect(
            !ZenbanRootView.shouldPresentTerminalFullscreen(
                selectedBoard: board,
                selectedCard: card,
                terminalFullscreenCardID: nil
            )
        )
    }

    @Test
    func shouldNotPresentTerminalFullscreenWhenFullscreenCardDoesNotMatchSelection() {
        let first = Card(title: "First", orderIndex: 0)
        let second = Card(title: "Second", orderIndex: 1)
        let board = Board(name: "Board", cards: [first, second])

        #expect(
            !ZenbanRootView.shouldPresentTerminalFullscreen(
                selectedBoard: board,
                selectedCard: first,
                terminalFullscreenCardID: second.id
            )
        )
    }
}
