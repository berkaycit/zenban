import SwiftUI

@Observable
final class BoardStore {
    var boards: [Board] = []
    var selectedBoardID: UUID?

    private var saveTask: Task<Void, Never>?

    var selectedBoard: Board? {
        boards.first { $0.id == selectedBoardID }
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
        guard let index = boards.firstIndex(where: { $0.id == boardID }) else { return }
        let card = Card(title: title, orderIndex: boards[index].nextOrderIndex)
        boards[index].cards.append(card)
        scheduleSave()
    }

    func moveCard(_ cardID: UUID, to column: Column, in boardID: UUID) {
        guard let boardIndex = boards.firstIndex(where: { $0.id == boardID }),
              let cardIndex = boards[boardIndex].cards.firstIndex(where: { $0.id == cardID }) else { return }

        boards[boardIndex].cards[cardIndex].column = column
        scheduleSave()
    }

    func updateCard(_ cardID: UUID, title: String, in boardID: UUID) {
        guard let boardIndex = boards.firstIndex(where: { $0.id == boardID }),
              let cardIndex = boards[boardIndex].cards.firstIndex(where: { $0.id == cardID }) else { return }

        boards[boardIndex].cards[cardIndex].title = title
        scheduleSave()
    }

    func deleteCard(_ cardID: UUID, from boardID: UUID) {
        guard let boardIndex = boards.firstIndex(where: { $0.id == boardID }) else { return }
        boards[boardIndex].cards.removeAll { $0.id == cardID }
        scheduleSave()
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
