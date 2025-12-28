import SwiftUI

@MainActor
@Observable
final class BoardStore {
    var boards: [Board] = []
    var selectedBoardID: UUID?
    var selectedCardID: UUID?
    var draggedCardID: UUID?

    var onCardDeleted: ((UUID) -> Void)?
    weak var terminalManager: TerminalManager?

    private var saveTask: Task<Void, Never>?

    var selectedBoard: Board? {
        boards.first { $0.id == selectedBoardID }
    }

    var sortedBoards: [Board] {
        boards.sorted { $0.isPinned && !$1.isPinned }
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

    func createBoard(name: String, repositoryPath: String? = nil, agent: Agent = .claude) {
        let board = Board(name: name, repositoryPath: repositoryPath, agent: agent)
        boards.insert(board, at: 0)
        selectedBoardID = board.id
        scheduleSave()
    }

    func board(for boardID: UUID) -> Board? {
        boards.first { $0.id == boardID }
    }

    func deleteBoard(_ board: Board) {
        let repoPath = board.repositoryPath

        for card in board.cards {
            onCardDeleted?(card.id)

            // Delete worktree if exists
            if let repoPath = repoPath,
               card.worktreePath != nil,
               GitService.isGitRepository(path: repoPath) {
                let cardID = card.id
                Task {
                    await deleteWorktreeForCard(cardID, repositoryPath: repoPath)
                }
            }
        }

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

    func togglePin(_ board: Board) {
        guard let index = boards.firstIndex(where: { $0.id == board.id }) else { return }
        boards[index].isPinned.toggle()
        scheduleSave()
    }

    // MARK: - Card Operations

    func addCard(title: String, to boardID: UUID) {
        guard let i = boardIndex(for: boardID) else { return }
        let card = Card(title: title, orderIndex: boards[i].nextOrderIndex)
        boards[i].cards.append(card)
        selectedCardID = card.id
        scheduleSave()

        if let repoPath = boards[i].repositoryPath,
           GitService.isGitRepository(path: repoPath) {
            Task {
                await createWorktreeForCard(card.id, in: boardID, repositoryPath: repoPath)
            }
        }
    }

    // Skip if card is already in target column to prevent reordering.
    // Agent detection triggers this frequently when card is already in correct column.
    func moveCard(_ cardID: UUID, to column: Column, in boardID: UUID) {
        guard let (bi, ci) = cardIndices(cardID: cardID, boardID: boardID),
              boards[bi].cards[ci].column != column else { return }
        let minOrderIndex = boards[bi].cards
            .filter { $0.column == column }
            .map(\.orderIndex)
            .min() ?? 1
        boards[bi].cards[ci].column = column
        boards[bi].cards[ci].orderIndex = minOrderIndex - 1
        scheduleSave()
    }

    func updateCard(_ cardID: UUID, title: String, in boardID: UUID) {
        guard let (bi, ci) = cardIndices(cardID: cardID, boardID: boardID) else { return }
        boards[bi].cards[ci].title = title
        scheduleSave()
    }

    func updateCardAgent(_ cardID: UUID, agent: Agent?, in boardID: UUID) {
        guard let (bi, ci) = cardIndices(cardID: cardID, boardID: boardID) else { return }
        boards[bi].cards[ci].agent = agent
        scheduleSave()
    }

    func deleteCard(_ cardID: UUID, from boardID: UUID) {
        guard let i = boardIndex(for: boardID) else { return }

        let card = boards[i].cards.first { $0.id == cardID }
        let repoPath = boards[i].repositoryPath

        boards[i].cards.removeAll { $0.id == cardID }
        if selectedCardID == cardID { selectedCardID = nil }
        if draggedCardID == cardID { draggedCardID = nil }
        onCardDeleted?(cardID)
        scheduleSave()

        if let repoPath = repoPath,
           card?.worktreePath != nil,
           GitService.isGitRepository(path: repoPath) {
            Task {
                await deleteWorktreeForCard(cardID, repositoryPath: repoPath)
            }
        }
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

    // MARK: - Worktree Operations

    private func createWorktreeForCard(_ cardID: UUID, in boardID: UUID, repositoryPath: String) async {
        do {
            let worktreePath = try await GitService.createWorktree(cardID: cardID, repositoryPath: repositoryPath)
            guard let (bi, ci) = cardIndices(cardID: cardID, boardID: boardID) else { return }
            boards[bi].cards[ci].worktreePath = worktreePath
            scheduleSave()

            // Notify terminal to launch agent in worktree
            let agent = boards[bi].cards[ci].agent ?? boards[bi].agent
            terminalManager?.worktreeReady(cardID: cardID, worktreePath: worktreePath, agent: agent)
        } catch {
            print("Failed to create worktree for card \(cardID): \(error)")
        }
    }

    private func deleteWorktreeForCard(_ cardID: UUID, repositoryPath: String) async {
        guard FileManager.default.fileExists(atPath: repositoryPath) else { return }
        await GitService.deleteWorktree(cardID: cardID, repositoryPath: repositoryPath)
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
