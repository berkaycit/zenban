import SwiftUI
import Foundation

enum FocusRegion {
    case sidebar
    case cards
}

enum OverlayState: Equatable {
    case none

    // Dev Server states
    case devServerConfiguring(cardID: UUID)
    case devServerRunning(cardID: UUID, setup: String?, dev: String)
    case devServerReconfiguring(cardID: UUID, setup: String?, dev: String)

    // Git Changes state
    case gitChanges(cardID: UUID)

    // File Browser state
    case fileBrowser(cardID: UUID)

    var cardID: UUID? {
        switch self {
        case .none: nil
        case .devServerConfiguring(let id), .devServerRunning(let id, _, _), .devServerReconfiguring(let id, _, _),
             .gitChanges(let id), .fileBrowser(let id): id
        }
    }

    var isDevServer: Bool {
        switch self {
        case .devServerConfiguring, .devServerRunning, .devServerReconfiguring: true
        default: false
        }
    }

    var isGitChanges: Bool {
        if case .gitChanges = self { return true }
        return false
    }

    var isFileBrowser: Bool {
        if case .fileBrowser = self { return true }
        return false
    }
}

@MainActor
@Observable
final class BoardStore {
    var boards: [Board] = [] {
        didSet { invalidateLookupCache() }
    }
    var selectedBoardID: UUID?
    var selectedCardID: UUID?
    var draggedCardID: UUID?
    var focusRegion: FocusRegion = .sidebar
    var showDeleteConfirmation = false
    var showKeyboardShortcuts = false
    var showDependencySetup = false

    // Dependency checking state
    var dependencyStatus: DependencyCheckService.Status?
    var isInstallingDependency = false
    var installationOutput = ""
    var dependencySetupIsBlocking = false

    // Unified overlay state (FSM)
    var overlayState: OverlayState = .none

    var onCardDeleted: ((UUID) -> Void)?
    weak var terminalManager: TerminalManager?

    private var saveTask: Task<Void, Never>?

    // O(1) board index cache - invalidated when boards change
    private var boardIndexCache: [UUID: Int]?
    private var _sortedBoardsCache: [Board]?

    var selectedBoard: Board? {
        guard let selectedBoardID, let index = boardIndex(for: selectedBoardID) else { return nil }
        return boards[index]
    }

    var sortedBoards: [Board] {
        if let cached = _sortedBoardsCache { return cached }
        let sorted = boards.sorted { $0.isPinned && !$1.isPinned }
        _sortedBoardsCache = sorted
        return sorted
    }

    var selectedCard: Card? {
        guard let cardID = selectedCardID else { return nil }
        return selectedBoard?.cards.first { $0.id == cardID }
    }

    func card(id: UUID) -> Card? {
        boards.lazy.flatMap(\.cards).first { $0.id == id }
    }

    // MARK: - Dev Server Computed Properties

    var showDevServer: Bool {
        switch overlayState {
        case .devServerRunning, .devServerReconfiguring: true
        default: false
        }
    }

    var showDevServerConfig: Bool {
        get {
            switch overlayState {
            case .devServerConfiguring, .devServerReconfiguring: true
            default: false
            }
        }
        set {
            // Sheet dismissed via swipe/cancel
            if !newValue {
                switch overlayState {
                case .devServerConfiguring:
                    overlayState = .none
                case .devServerReconfiguring(let cardID, let setup, let dev):
                    overlayState = .devServerRunning(cardID: cardID, setup: setup, dev: dev)
                default:
                    break
                }
            }
        }
    }

    var devServerCard: Card? {
        switch overlayState {
        case .devServerConfiguring(let cardID),
             .devServerRunning(let cardID, _, _),
             .devServerReconfiguring(let cardID, _, _):
            selectedBoardCard(cardID)
        default:
            nil
        }
    }

    var devServerSetupCommand: String? {
        switch overlayState {
        case .devServerRunning(_, let setup, _), .devServerReconfiguring(_, let setup, _):
            setup
        default:
            nil
        }
    }

    var devServerDevCommand: String {
        switch overlayState {
        case .devServerRunning(_, _, let dev), .devServerReconfiguring(_, _, let dev):
            dev
        default:
            ""
        }
    }

    // MARK: - Dev Server Transitions

    func configureDevServer(for card: Card) {
        overlayState = .devServerConfiguring(cardID: card.id)
    }

    func startDevServerDirect(card: Card, setup: String?, dev: String) {
        overlayState = .devServerRunning(cardID: card.id, setup: setup, dev: dev)
    }

    func stopDevServer() {
        if overlayState.isDevServer { overlayState = .none }
    }

    func toggleDevServer() {
        guard let card = selectedCard, let board = selectedBoard else { return }

        // Toggle off if already showing for this card
        if devServerCard?.id == card.id {
            overlayState = .none
            return
        }

        // Open dev server (automatically closes any other overlay)
        if let config = board.devServerConfig {
            overlayState = .devServerRunning(cardID: card.id, setup: config.setupCommand, dev: config.devCommand)
        } else {
            overlayState = .devServerConfiguring(cardID: card.id)
        }
    }

    func openReconfigure() {
        guard case .devServerRunning(let cardID, let setup, let dev) = overlayState else { return }
        overlayState = .devServerReconfiguring(cardID: cardID, setup: setup, dev: dev)
    }

    func confirmDevServerConfig(setup: String?, dev: String) {
        switch overlayState {
        case .devServerConfiguring(let cardID):
            overlayState = .devServerRunning(cardID: cardID, setup: setup, dev: dev)
        case .devServerReconfiguring(let cardID, _, _):
            // Close view to trigger onDisappear (stops process), then restart
            overlayState = .none
            Task { @MainActor in
                // Only restart if still idle (no other action changed state)
                guard overlayState == .none else { return }
                overlayState = .devServerRunning(cardID: cardID, setup: setup, dev: dev)
            }
        default:
            break
        }
    }

    // MARK: - Git Changes Computed Properties

    var showGitChanges: Bool {
        overlayState.isGitChanges
    }

    var gitChangesCard: Card? {
        guard overlayState.isGitChanges, let cardID = overlayState.cardID else { return nil }
        return selectedBoardCard(cardID)
    }

    // MARK: - File Browser Computed Properties

    var showFileBrowser: Bool {
        overlayState.isFileBrowser
    }

    var fileBrowserCard: Card? {
        guard overlayState.isFileBrowser, let cardID = overlayState.cardID else { return nil }
        return selectedBoardCard(cardID)
    }

    // MARK: - Git Changes Transitions

    func toggleGitChanges() {
        guard let card = selectedCard else { return }
        toggleOverlay(for: card.id, matching: { $0.isGitChanges && $0.cardID == $1 }) {
            .gitChanges(cardID: $0)
        }
    }

    func stopGitChanges() {
        clearOverlay { $0.isGitChanges }
    }

    // MARK: - File Browser Transitions

    func toggleFileBrowser() {
        guard let card = selectedCard else { return }
        toggleOverlay(for: card.id, matching: { $0.isFileBrowser && $0.cardID == $1 }) {
            .fileBrowser(cardID: $0)
        }
    }

    func stopOverlays() {
        overlayState = .none
    }

    init() {
        boards = BoardStorage.load()
        selectedBoardID = boards.first?.id
    }

    // MARK: - Dependency Management

    private static let skipDependencyCheckKey = "skipDependencyCheck"

    func checkDependencies() {
        Task { [weak self] in
            let status = await Task.detached(priority: .utility) {
                DependencyCheckService.shared.checkAll()
            }.value
            guard let self else { return }
            self.applyDependencyStatus(status)
        }
    }

    func presentDependencySetup(blocking: Bool = false) {
        dependencySetupIsBlocking = blocking
        showDependencySetup = true
    }

    func dismissDependencySetup() {
        dependencySetupIsBlocking = false
        showDependencySetup = false
    }

    func skipDependencySetup() {
        UserDefaults.standard.set(true, forKey: Self.skipDependencyCheckKey)
        dismissDependencySetup()
    }

    // MARK: - Board Operations

    func createBoard(name: String, repositoryPath: String? = nil, agent: Agent = .claude) {
        let board = Board(name: name, repositoryPath: repositoryPath, agent: agent)
        boards.insert(board, at: 0)
        selectedBoardID = board.id
        scheduleSave()
    }

    func board(for boardID: UUID) -> Board? {
        guard let index = boardIndex(for: boardID) else { return nil }
        return boards[index]
    }

    func selectCard(_ cardID: UUID, in boardID: UUID) {
        guard let board = board(for: boardID),
              board.cards.contains(where: { $0.id == cardID }) else {
            return
        }

        selectedBoardID = boardID
        selectedCardID = cardID
        focusRegion = .cards
    }

    func clearSelectedCardIfNeededForSelectedBoardChange() {
        guard let cardID = selectedCardID,
              let board = selectedBoard,
              board.cards.contains(where: { $0.id == cardID }) else {
            selectedCardID = nil
            return
        }
    }

    func deleteBoard(_ board: Board) {
        let repoPath = board.repositoryPath
        let cardIDs = Set(board.cards.map(\.id))

        // Stop overlay if showing for any card in this board
        if let id = overlayState.cardID, cardIDs.contains(id) { overlayState = .none }

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
        guard let index = boardIndex(for: board.id) else { return }
        boards[index].name = name
        scheduleSave()
    }

    func togglePin(_ board: Board) {
        guard let index = boardIndex(for: board.id) else { return }
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

    func addCardWithAutoName(to boardID: UUID) {
        guard let i = boardIndex(for: boardID) else { return }

        let agent = boards[i].agent
        let title = boards[i].nextAutoName(for: agent)
        let card = Card(title: title, orderIndex: boards[i].nextOrderIndex, agent: agent)

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

    func updateFileBrowserSession(_ cardID: UUID, in boardID: UUID, session: FileBrowserSessionState?) {
        guard let (bi, ci) = cardIndices(cardID: cardID, boardID: boardID) else { return }
        boards[bi].cards[ci].fileBrowserSession = session
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

        if overlayState.cardID == cardID { overlayState = .none }

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

    // MARK: - O(1) Lookup Cache

    private func invalidateLookupCache() {
        boardIndexCache = nil
        _sortedBoardsCache = nil
    }

    private func applyDependencyStatus(_ status: DependencyCheckService.Status) {
        dependencyStatus = status

        if !status.allRequired,
           !UserDefaults.standard.bool(forKey: Self.skipDependencyCheckKey) {
            dependencySetupIsBlocking = true
            showDependencySetup = true
        } else if status.allRequired {
            dependencySetupIsBlocking = false
        }
    }

    private func clearOverlay(if predicate: (OverlayState) -> Bool) {
        if predicate(overlayState) {
            overlayState = .none
        }
    }

    private func toggleOverlay(
        for cardID: UUID,
        matching predicate: (OverlayState, UUID) -> Bool,
        makeState: (UUID) -> OverlayState
    ) {
        if predicate(overlayState, cardID) {
            overlayState = .none
            return
        }
        overlayState = makeState(cardID)
    }

    private func selectedBoardCard(_ cardID: UUID) -> Card? {
        selectedBoard?.cards.first { $0.id == cardID }
    }

    private func boardIndex(for id: UUID) -> Int? {
        if boardIndexCache == nil {
            var cache: [UUID: Int] = [:]
            cache.reserveCapacity(boards.count)
            for (index, board) in boards.enumerated() {
                cache[board.id] = index
            }
            boardIndexCache = cache
        }
        return boardIndexCache?[id]
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
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            let snapshot = self.boards
            DispatchQueue.global(qos: .utility).async {
                BoardStorage.save(snapshot)
            }
        }
    }
}
