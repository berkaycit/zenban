import Testing
@testable import zenban

struct ZenbanRootViewTests {
    @Test
    func rootContentModeUsesFullscreenWhenSelectedCardMatches() {
        let card = Card(title: "Terminal", orderIndex: 0)
        let board = Board(name: "Board", cards: [card])

        #expect(
            ZenbanRootView.rootContentMode(
                selectedBoard: board,
                selectedCard: card,
                terminalFullscreenCardID: card.id
            ) == .terminalFullscreenCardDetail
        )
    }

    @Test
    func rootContentModeReturnsSplitViewWhenFullscreenClears() {
        let card = Card(title: "Terminal", orderIndex: 0)
        let board = Board(name: "Board", cards: [card])

        #expect(
            ZenbanRootView.rootContentMode(
                selectedBoard: board,
                selectedCard: card,
                terminalFullscreenCardID: nil
            ) == .splitView
        )
    }

    @Test
    func rootContentModeReturnsSplitViewWhenFullscreenCardDoesNotMatchSelection() {
        let first = Card(title: "First", orderIndex: 0)
        let second = Card(title: "Second", orderIndex: 1)
        let board = Board(name: "Board", cards: [first, second])

        #expect(
            ZenbanRootView.rootContentMode(
                selectedBoard: board,
                selectedCard: first,
                terminalFullscreenCardID: second.id
            ) == .splitView
        )
    }
}
