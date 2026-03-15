//
//  zenbanTests.swift
//  zenbanTests
//
//  Created by Berkay Çit on 25.12.2025.
//

import Testing
@testable import zenban

struct zenbanTests {
    @MainActor
    @Test
    func claudeAutoNamedCardKeepsStableCcPrefix() throws {
        let board = Board(name: "Auto Name", agent: .claude)
        let store = BoardStore(initialBoards: [board], persistenceEnabled: false)

        store.addCardWithAutoName(to: board.id)

        let createdCard = try #require(store.board(for: board.id)?.cards.first)
        #expect(createdCard.title == "cc-1")
    }
}
