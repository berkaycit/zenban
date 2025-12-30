import SwiftUI

enum FocusRegion {
    case sidebar
    case cards
}

enum DevServerState: Equatable {
    case idle
    case configuring(cardID: UUID)
    case running(cardID: UUID, setup: String?, dev: String)
    case reconfiguring(cardID: UUID, setup: String?, dev: String)
}

@MainActor
@Observable
final class BoardStore {
    var boards: [Board] = []
    var selectedBoardID: UUID?
    var selectedCardID: UUID?
    var draggedCardID: UUID?
    var focusRegion: FocusRegion = .sidebar
    var showDeleteConfirmation = false

    // Dev server state (FSM)
    var devServerState: DevServerState = .idle

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

    // MARK: - Dev Server Computed Properties

    var showDevServer: Bool {
        switch devServerState {
        case .running, .reconfiguring: true
        case .idle, .configuring: false
        }
    }

    var showDevServerConfig: Bool {
        get {
            switch devServerState {
            case .configuring, .reconfiguring: true
            case .idle, .running: false
            }
        }
        set {
            // Sheet dismissed via swipe/cancel
            if !newValue {
                switch devServerState {
                case .configuring:
                    devServerState = .idle
                case .reconfiguring(let cardID, let setup, let dev):
                    devServerState = .running(cardID: cardID, setup: setup, dev: dev)
                default:
                    break
                }
            }
        }
    }

    var devServerCard: Card? {
        switch devServerState {
        case .configuring(let cardID), .running(let cardID, _, _), .reconfiguring(let cardID, _, _):
            // Always get fresh card from board
            selectedBoard?.cards.first { $0.id == cardID }
        case .idle:
            nil
        }
    }

    var devServerSetupCommand: String? {
        switch devServerState {
        case .running(_, let setup, _), .reconfiguring(_, let setup, _):
            setup
        case .idle, .configuring:
            nil
        }
    }

    var devServerDevCommand: String {
        switch devServerState {
        case .running(_, _, let dev), .reconfiguring(_, _, let dev):
            dev
        case .idle, .configuring:
            ""
        }
    }

    // MARK: - Dev Server Transitions

    func configureDevServer(for card: Card) {
        devServerState = .configuring(cardID: card.id)
    }

    func startDevServerDirect(card: Card, setup: String?, dev: String) {
        devServerState = .running(cardID: card.id, setup: setup, dev: dev)
    }

    func stopDevServer() {
        devServerState = .idle
    }

    func toggleDevServer() {
        guard let card = selectedCard, let board = selectedBoard else { return }

        // Stop if running for this card
        if devServerCard?.id == card.id {
            stopDevServer()
            return
        }

        // Start dev server for selected card
        if let config = board.devServerConfig {
            startDevServerDirect(card: card, setup: config.setupCommand, dev: config.devCommand)
        } else {
            configureDevServer(for: card)
        }
    }

    func openReconfigure() {
        guard case .running(let cardID, let setup, let dev) = devServerState else { return }
        devServerState = .reconfiguring(cardID: cardID, setup: setup, dev: dev)
    }

    func confirmDevServerConfig(setup: String?, dev: String) {
        switch devServerState {
        case .configuring(let cardID):
            devServerState = .running(cardID: cardID, setup: setup, dev: dev)
        case .reconfiguring(let cardID, _, _):
            // Close view to trigger onDisappear (stops process), then restart
            devServerState = .idle
            Task { @MainActor in
                // Only restart if still idle (no other action changed state)
                guard devServerState == .idle else { return }
                devServerState = .running(cardID: cardID, setup: setup, dev: dev)
            }
        default:
            break
        }
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

        // Stop dev server if running for any card in this board
        if let devCard = devServerCard,
           board.cards.contains(where: { $0.id == devCard.id }) {
            stopDevServer()
        }

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

    func updateDevServerConfig(_ boardID: UUID, config: DevServerConfig) {
        guard let index = boardIndex(for: boardID) else { return }
        boards[index].devServerConfig = config
        scheduleSave()
    }

    func clearDevServerConfig(_ boardID: UUID) {
        guard let index = boardIndex(for: boardID) else { return }
        boards[index].devServerConfig = nil
        scheduleSave()
    }

    // MARK: - Card Operations

    func addCard(title: String, to boardID: UUID) {
        guard let i = boardIndex(for: boardID) else { return }
        let card = Card(title: title, orderIndex: boards[i].nextOrderIndex)
        boards[i].cards.append(card)
        selectedCardID = card.id
        focusRegion = .cards
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

    func requestDeleteSelectedCard() {
        guard selectedBoardID != nil, selectedCardID != nil else { return }
        showDeleteConfirmation = true
    }

    func confirmDeleteSelectedCard() {
        guard let boardID = selectedBoardID, let cardID = selectedCardID else { return }
        showDeleteConfirmation = false
        deleteCard(cardID, from: boardID)
    }

    func cancelDeleteSelectedCard() {
        showDeleteConfirmation = false
    }

    func deleteCard(_ cardID: UUID, from boardID: UUID) {
        guard let i = boardIndex(for: boardID) else { return }

        let card = boards[i].cards.first { $0.id == cardID }
        let repoPath = boards[i].repositoryPath
        let wasSelected = selectedCardID == cardID

        // Capture column and index before deletion for selection logic
        let deletedColumn = card?.column
        let deletedIndex = deletedColumn.flatMap { col in
            boards[i].cards(in: col).firstIndex { $0.id == cardID }
        }

        if devServerCard?.id == cardID { stopDevServer() }

        boards[i].cards.removeAll { $0.id == cardID }
        if draggedCardID == cardID { draggedCardID = nil }
        onCardDeleted?(cardID)

        if wasSelected {
            selectNextCardAfterDeletion(boardIndex: i, column: deletedColumn, deletedIndex: deletedIndex)
        }

        scheduleSave()

        if let repoPath = repoPath,
           card?.worktreePath != nil,
           GitService.isGitRepository(path: repoPath) {
            Task {
                await deleteWorktreeForCard(cardID, repositoryPath: repoPath)
            }
        }
    }

    // MARK: - Keyboard Navigation

    func selectPreviousCard() {
        guard let board = selectedBoard,
              let card = selectedCard else {
            selectFirstCard(in: .todo)
            return
        }
        let cards = board.cards(in: card.column)
        guard let index = cards.firstIndex(where: { $0.id == card.id }),
              index > 0 else { return }
        selectedCardID = cards[index - 1].id
    }

    func selectNextCard() {
        guard let board = selectedBoard,
              let card = selectedCard else {
            selectFirstCard(in: .todo)
            return
        }
        let cards = board.cards(in: card.column)
        guard let index = cards.firstIndex(where: { $0.id == card.id }),
              index < cards.count - 1 else { return }
        selectedCardID = cards[index + 1].id
    }

    func selectCardInPreviousColumn() {
        guard let board = selectedBoard,
              let card = selectedCard else {
            selectFirstCard(in: .todo)
            return
        }
        let columns = Column.allCases
        let currentCards = board.cards(in: card.column)
        let currentIndex = currentCards.firstIndex(where: { $0.id == card.id }) ?? 0
        guard let columnIndex = columns.firstIndex(of: card.column) else { return }

        if columnIndex == 0 {
            selectedCardID = nil
            focusRegion = .sidebar
            return
        }

        // Find previous non-empty column
        for i in stride(from: columnIndex - 1, through: 0, by: -1) {
            let targetCards = board.cards(in: columns[i])
            if !targetCards.isEmpty {
                let targetIndex = min(currentIndex, targetCards.count - 1)
                selectedCardID = targetCards[targetIndex].id
                return
            }
        }
        selectedCardID = nil
        focusRegion = .sidebar
    }

    func selectCardInNextColumn() {
        guard let board = selectedBoard,
              let card = selectedCard else {
            selectFirstCard(in: .todo)
            return
        }
        let columns = Column.allCases
        let currentCards = board.cards(in: card.column)
        let currentIndex = currentCards.firstIndex(where: { $0.id == card.id }) ?? 0
        guard let columnIndex = columns.firstIndex(of: card.column) else { return }

        // Find next non-empty column
        for i in (columnIndex + 1)..<columns.count {
            let targetCards = board.cards(in: columns[i])
            if !targetCards.isEmpty {
                let targetIndex = min(currentIndex, targetCards.count - 1)
                selectedCardID = targetCards[targetIndex].id
                return
            }
        }
    }

    func enterCardsFromSidebar() {
        guard selectedBoard != nil else { return }
        for column in Column.allCases {
            if selectFirstCard(in: column) { return }
        }
    }

    func selectPreviousBoard() {
        let boards = sortedBoards
        guard !boards.isEmpty else { return }
        guard let currentID = selectedBoardID,
              let index = boards.firstIndex(where: { $0.id == currentID }),
              index > 0 else { return }
        selectedBoardID = boards[index - 1].id
    }

    func selectNextBoard() {
        let boards = sortedBoards
        guard !boards.isEmpty else { return }
        guard let currentID = selectedBoardID,
              let index = boards.firstIndex(where: { $0.id == currentID }),
              index < boards.count - 1 else {
            if selectedBoardID == nil, let first = boards.first {
                selectedBoardID = first.id
            }
            return
        }
        selectedBoardID = boards[index + 1].id
    }

    @discardableResult
    private func selectFirstCard(in column: Column) -> Bool {
        guard let board = selectedBoard,
              let firstCard = board.cards(in: column).first else { return false }
        selectedCardID = firstCard.id
        focusRegion = .cards
        return true
    }

    // MARK: - Private Helpers

    private func selectNextCardAfterDeletion(boardIndex i: Int, column: Column?, deletedIndex: Int?) {
        guard let column, let index = deletedIndex else {
            selectedCardID = nil
            return
        }
        let cards = boards[i].cards(in: column)
        if index < cards.count {
            selectedCardID = cards[index].id
        } else if let last = cards.last {
            selectedCardID = last.id
        } else {
            // Column empty, select last card from any column
            selectedCardID = boards[i].cards(in: .todo).last?.id
                ?? boards[i].cards(in: .inProgress).last?.id
                ?? boards[i].cards(in: .done).last?.id
        }
    }

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
