//
//  zenbanTests.swift
//  zenbanTests
//
//  Created by Berkay Çit on 25.12.2025.
//

import Foundation
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

    @Test
    func legacyBoardsJsonDecodesWithoutAgentSummary() throws {
        let json = """
        [
          {
            "id": "A2E7F1A5-63A5-4B99-8E68-1E2B4749AA01",
            "name": "Legacy Board",
            "cards": [
              {
                "id": "35E9D3E4-5F18-4F55-8D05-045B78505634",
                "title": "cc-1",
                "column": "To Do",
                "createdAt": "2026-03-15T10:00:00Z",
                "orderIndex": 0,
                "agent": "Claude Code",
                "worktreePath": "/tmp/cc-1"
              }
            ],
            "createdAt": "2026-03-15T10:00:00Z",
            "isPinned": false,
            "agent": "Claude Code",
            "agentCounters": {
              "cc": 1
            }
          }
        ]
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let boards = try decoder.decode([Board].self, from: Data(json.utf8))
        let card = try #require(boards.first?.cards.first)

        #expect(card.title == "cc-1")
        #expect(card.agentSummary == nil)
        #expect(card.lastSubmittedPrompt == nil)
        #expect(card.pendingLaunchPrompt == nil)
    }

    @MainActor
    @Test
    func fanOutClaudePromptCreatesSiblingCardsAndPreservesSelection() throws {
        let prompt = "Investigate the failing login tests"
        let sourceCard = Card(
            title: "Login bug",
            lastSubmittedPrompt: prompt,
            column: .todo,
            orderIndex: 0,
            agent: .claude
        )
        let board = Board(name: "Fan Out", cards: [sourceCard], agent: .claude)
        let store = BoardStore(initialBoards: [board], persistenceEnabled: false)
        store.selectedBoardID = board.id
        store.selectedCardID = sourceCard.id

        store.fanOutClaudePrompt(from: sourceCard.id, in: board.id, count: 3)

        let updatedBoard = try #require(store.board(for: board.id))
        let cards = updatedBoard.cards(in: .todo)

        #expect(cards.map(\.title) == ["Login bug (2)", "Login bug (3)", "Login bug (4)", "Login bug"])
        #expect(store.selectedCardID == sourceCard.id)

        let clonedCards = cards.filter { $0.id != sourceCard.id }
        #expect(clonedCards.count == 3)
        #expect(clonedCards.allSatisfy { $0.agent == .claude })
        #expect(clonedCards.allSatisfy { $0.column == .todo })
        #expect(clonedCards.allSatisfy { $0.lastSubmittedPrompt == prompt })
        #expect(clonedCards.allSatisfy { $0.pendingLaunchPrompt == prompt })
    }

    @Test
    func claudePromptCaptureStateCommitsNormalizedPromptAfterDeleteBackward() {
        var captureState = ClaudePromptCaptureState()

        captureState.append("Fix")
        captureState.append(" testss")
        captureState.deleteBackward()

        #expect(captureState.commit() == "Fix tests")
        #expect(captureState.commit() == nil)
    }

    @Test
    func claudePromptCaptureStateNormalizesMultilinePasteAndClearsUnsupportedDraft() {
        var captureState = ClaudePromptCaptureState()

        captureState.append("Investigate\n  flaky   login\nflow")
        #expect(captureState.commit() == "Investigate flaky login flow")

        captureState.append("stale draft")
        captureState.clearDueToUnsupportedEdit()
        #expect(captureState.commit() == nil)
    }
}
