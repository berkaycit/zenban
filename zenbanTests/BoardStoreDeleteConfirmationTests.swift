import Foundation
import Testing
@testable import zenban

struct BoardStoreDeleteConfirmationTests {
    @MainActor
    @Test
    func requestDeleteColumnCapturesSortedSnapshotForBulkDeletableColumns() {
        let todoA = Card(title: "todo-a", column: .todo, orderIndex: 0)
        let review = Card(title: "review", column: .inProgress, orderIndex: 0)
        let todoB = Card(title: "todo-b", column: .todo, orderIndex: 1)
        let done = Card(title: "done", column: .done, orderIndex: 0)
        let board = Board(name: "Board", cards: [todoB, done, review, todoA])
        let store = makeStore(board: board)

        store.requestDeleteColumn(.todo, in: board.id)

        guard let request = store.deleteConfirmationRequest else {
            Issue.record("Expected a delete confirmation request for the To Do column.")
            return
        }

        guard case .column(let boardID, let column, let cardIDs) = request.target else {
            Issue.record("Expected a column delete confirmation request.")
            return
        }

        #expect(boardID == board.id)
        #expect(column == .todo)
        #expect(cardIDs == [todoA.id, todoB.id])
        #expect(cardIDs.count == 2)

        store.requestDeleteColumn(.inProgress, in: board.id)

        guard let reviewRequest = store.deleteConfirmationRequest else {
            Issue.record("Expected a delete confirmation request for the In Review column.")
            return
        }

        guard case .column(_, let reviewColumn, let reviewCardIDs) = reviewRequest.target else {
            Issue.record("Expected an In Review column delete confirmation request.")
            return
        }

        #expect(reviewColumn == .inProgress)
        #expect(reviewCardIDs == [review.id])
        #expect(reviewCardIDs.count == 1)

        store.requestDeleteColumn(.done, in: board.id)

        guard let doneRequest = store.deleteConfirmationRequest else {
            Issue.record("Expected a delete confirmation request for the Done column.")
            return
        }

        guard case .column(_, let doneColumn, let doneCardIDs) = doneRequest.target else {
            Issue.record("Expected a Done column delete confirmation request.")
            return
        }

        #expect(doneColumn == .done)
        #expect(doneCardIDs == [done.id])
        #expect(doneCardIDs.count == 1)
    }

    @MainActor
    @Test
    func requestDeleteColumnIgnoresEmptyColumns() {
        let todo = Card(title: "todo", column: .todo, orderIndex: 0)
        let board = Board(name: "Board", cards: [todo])
        let store = makeStore(board: board)

        store.requestDeleteColumn(.inProgress, in: board.id)
        #expect(store.deleteConfirmationRequest == nil)

        store.requestDeleteColumn(.done, in: board.id)
        #expect(store.deleteConfirmationRequest == nil)
    }

    @MainActor
    @Test
    func confirmDeleteRequestRemovesOnlySnapshotCards() {
        let todoA = Card(title: "todo-a", column: .todo, orderIndex: 0)
        let review = Card(title: "review", column: .inProgress, orderIndex: 0)
        let todoB = Card(title: "todo-b", column: .todo, orderIndex: 1)
        let board = Board(name: "Board", cards: [todoA, review, todoB])
        let store = makeStore(board: board)

        store.requestDeleteColumn(.todo, in: board.id)

        let lateArrival = Card(title: "late-arrival", column: .todo, orderIndex: 2)
        store.boards[0].cards.append(lateArrival)

        store.confirmDeleteRequest()

        let remainingCards = store.boards[0].cards
        #expect(remainingCards.map(\.id).contains(review.id))
        #expect(remainingCards.map(\.id).contains(lateArrival.id))
        #expect(!remainingCards.map(\.id).contains(todoA.id))
        #expect(!remainingCards.map(\.id).contains(todoB.id))
    }

    @MainActor
    @Test
    func confirmDeleteRequestUpdatesSelectionAndCleansUpDeletedCards() {
        let todoA = Card(title: "todo-a", column: .todo, orderIndex: 0)
        let todoB = Card(title: "todo-b", column: .todo, orderIndex: 1)
        let review = Card(title: "review", column: .inProgress, orderIndex: 0)
        let done = Card(title: "done", column: .done, orderIndex: 0)
        let board = Board(name: "Board", cards: [todoA, review, done, todoB])
        let store = makeStore(board: board, selectedCardID: todoB.id)
        var deletedCardIDs: [UUID] = []
        store.onCardDeleted = { deletedCardIDs.append($0) }
        store.overlayState = .fileBrowser(cardID: todoA.id)

        store.requestDeleteColumn(.todo, in: board.id)
        store.confirmDeleteRequest()

        #expect(store.selectedCardID == review.id)
        #expect(store.overlayState == .none)
        #expect(Set(deletedCardIDs) == Set([todoA.id, todoB.id]))
        #expect(store.boards[0].cards.map(\.id) == [review.id, done.id])
    }

    @MainActor
    private func makeStore(board: Board, selectedCardID: UUID? = nil) -> BoardStore {
        let store = BoardStore(initialBoards: [board], persistenceEnabled: false)
        store.selectedBoardID = board.id
        store.selectedCardID = selectedCardID
        return store
    }
}
