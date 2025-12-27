import SwiftUI

@Observable
final class BoardStore {
    var boards: [Board] = []
    var selectedBoardID: UUID?
    var selectedCardID: UUID?
    var draggedCardID: UUID?

    var onCardDeleted: ((UUID) -> Void)?

    private var saveTask: Task<Void, Never>?

    var selectedBoard: Board? {
        boards.first { $0.id == selectedBoardID }
    }

    var selectedCard: Card? {
        guard let cardID = selectedCardID else { return nil }
        return selectedBoard?.cards.first { $0.id == cardID }
    }

    init() {
        boards = BoardStorage.load()
        selectedBoardID = boards.first?.id
    }

    // MARK: - Board Operations

    func createBoard(name: String) {
        let board = Board(name: name)
        boards.append(board)
        selectedBoardID = board.id
        scheduleSave()
    }

    func deleteBoard(_ board: Board) {
        boards.removeAll { $0.id == board.id }
        if selectedBoardID == board.id {
            selectedBoardID = boards.first?.id
            selectedCardID = nil
        }
        scheduleSave()
    }

    func renameBoard(_ board: Board, to name: String) {
        guard let index = boards.firstIndex(where: { $0.id == board.id }) else { return }
        boards[index].name = name
        scheduleSave()
    }

    // MARK: - Card Operations

    func addCard(title: String, to boardID: UUID) {
        guard let i = boardIndex(for: boardID) else { return }
        let card = Card(title: title, orderIndex: boards[i].nextOrderIndex)
        boards[i].cards.append(card)
        scheduleSave()
    }

    // Skip if card is already in target column to prevent reordering.
    // Agent detection triggers this frequently when card is already in correct column.
    func moveCard(_ cardID: UUID, to column: Column, in boardID: UUID) {
        guard let (bi, ci) = cardIndices(cardID: cardID, boardID: boardID),
              boards[bi].cards[ci].column != column else { return }
        let maxOrderIndex = boards[bi].cards
            .filter { $0.column == column }
            .map(\.orderIndex)
            .max() ?? -1
        boards[bi].cards[ci].column = column
        boards[bi].cards[ci].orderIndex = maxOrderIndex + 1
        scheduleSave()
    }

    func updateCard(_ cardID: UUID, title: String, in boardID: UUID) {
        guard let (bi, ci) = cardIndices(cardID: cardID, boardID: boardID) else { return }
        boards[bi].cards[ci].title = title
        scheduleSave()
    }

    func deleteCard(_ cardID: UUID, from boardID: UUID) {
        guard let i = boardIndex(for: boardID) else { return }
        boards[i].cards.removeAll { $0.id == cardID }
        if selectedCardID == cardID { selectedCardID = nil }
        if draggedCardID == cardID { draggedCardID = nil }
        onCardDeleted?(cardID)
        scheduleSave()
    }

    // MARK: - Private Helpers

    private func boardIndex(for id: UUID) -> Int? {
        boards.firstIndex { $0.id == id }
    }

    private func cardIndices(cardID: UUID, boardID: UUID) -> (board: Int, card: Int)? {
        guard let bi = boardIndex(for: boardID),
              let ci = boards[bi].cards.firstIndex(where: { $0.id == cardID }) else { return nil }
        return (bi, ci)
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            BoardStorage.save(boards)
        }
    }
}
