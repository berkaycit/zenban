import SwiftUI
import Foundation
import Observation

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

struct DeleteConfirmationRequest: Identifiable, Equatable {
    enum Target: Equatable {
        case card(boardID: UUID, cardID: UUID, cardTitle: String)
        case column(boardID: UUID, column: Column, cardIDs: [UUID])
    }

    let target: Target

    static func card(boardID: UUID, card: Card) -> Self {
        Self(target: .card(boardID: boardID, cardID: card.id, cardTitle: card.title))
    }

    static func column(boardID: UUID, column: Column, cards: [Card]) -> Self {
        Self(target: .column(boardID: boardID, column: column, cardIDs: cards.map(\.id)))
    }

    var id: String {
        switch target {
        case .card(_, let cardID, _):
            cardID.uuidString
        case .column(let boardID, let column, _):
            "\(boardID.uuidString)-\(column.rawValue)"
        }
    }

    var content: DeleteConfirmationContent {
        switch target {
        case .card(_, _, let cardTitle):
            return DeleteConfirmationContent(
                title: String(localized: "Delete Card?", defaultValue: "Delete Card?"),
                message: String(
                    localized: "Are you sure you want to delete",
                    defaultValue: "Are you sure you want to delete"
                ),
                detail: String.localizedStringWithFormat(
                    String(localized: "\"%@\"?", defaultValue: "\"%@\"?"),
                    cardTitle
                ),
                deleteAccessibilityLabel: String(localized: "Delete card", defaultValue: "Delete card")
            )
        case .column(_, let column, let cardIDs):
            return DeleteConfirmationContent(
                title: column.bulkDeleteConfirmationTitle,
                message: column.bulkDeleteConfirmationMessage(cardCount: cardIDs.count),
                detail: nil,
                deleteAccessibilityLabel: column.bulkDeleteAccessibilityLabel
            )
        }
    }

    func affectsAnyCard(in cardIDs: Set<UUID>) -> Bool {
        switch target {
        case .card(_, let cardID, _):
            cardIDs.contains(cardID)
        case .column(_, _, let snapshotCardIDs):
            !cardIDs.isDisjoint(with: Set(snapshotCardIDs))
        }
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
    var deleteConfirmationRequest: DeleteConfirmationRequest?
    var showKeyboardShortcuts = false
    var showDependencySetup = false

    // Dependency checking state
    var dependencyStatus: DependencyCheckService.Status?
    var isInstallingDependency = false
    var installationOutput = ""

    // Unified overlay state (FSM)
    var overlayState: OverlayState = .none

    var onCardDeleted: ((UUID) -> Void)?
    @ObservationIgnored weak var cmuxHost: CmuxHostStore?

    @ObservationIgnored private let persistenceEnabled: Bool
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

    init(initialBoards: [Board]? = nil, persistenceEnabled: Bool = true) {
        self.persistenceEnabled = persistenceEnabled
        boards = initialBoards ?? BoardStorage.load()
        selectedBoardID = boards.first?.id
    }

    // MARK: - Dependency Management

    func checkDependencies() {
        Task { [weak self] in
            let status = await Task.detached(priority: .utility) {
                DependencyCheckService.shared.checkAll()
            }.value
            guard let self else { return }
            self.dependencyStatus = status
        }
    }

    func presentDependencySetup(blocking: Bool = false) {
        _ = blocking
        showDependencySetup = true
    }

    func dismissDependencySetup() {
        showDependencySetup = false
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
        if let request = deleteConfirmationRequest, request.affectsAnyCard(in: cardIDs) {
            deleteConfirmationRequest = nil
        }

        for card in board.cards {
            cmuxHost?.removeWorkspace(for: card.id)
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
    @discardableResult
    func moveCard(_ cardID: UUID, to column: Column, in boardID: UUID) -> Bool {
        guard let (bi, ci) = cardIndices(cardID: cardID, boardID: boardID),
              boards[bi].cards[ci].column != column else { return false }
        let previousColumn = boards[bi].cards[ci].column
        let minOrderIndex = boards[bi].cards
            .filter { $0.column == column }
            .map(\.orderIndex)
            .min() ?? 1
        boards[bi].cards[ci].column = column
        boards[bi].cards[ci].orderIndex = minOrderIndex - 1
        if column == .done, previousColumn != .done {
            if overlayState.isDevServer, overlayState.cardID == cardID {
                overlayState = .none
            }
            cmuxHost?.removeWorkspace(for: cardID)
        }
        scheduleSave()
        return true
    }

    func updateCard(_ cardID: UUID, title: String, in boardID: UUID) {
        guard let (bi, ci) = cardIndices(cardID: cardID, boardID: boardID) else { return }
        boards[bi].cards[ci].title = title
        cmuxHost?.updateTitle(for: cardID, title: title)
        scheduleSave()
    }

    func updateCardAgent(_ cardID: UUID, agent: Agent?, in boardID: UUID) {
        guard let (bi, ci) = cardIndices(cardID: cardID, boardID: boardID) else { return }
        boards[bi].cards[ci].agent = agent
        cmuxHost?.updateAgentLaunch(for: boards[bi].cards[ci], boardID: boardID)
        scheduleSave()
    }

    func updateCardAgentSummary(_ cardID: UUID, summary: String?, in boardID: UUID) {
        guard let (bi, ci) = cardIndices(cardID: cardID, boardID: boardID) else { return }
        guard boards[bi].cards[ci].agentSummary != summary else { return }
        boards[bi].cards[ci].agentSummary = summary
        scheduleSave()
    }

    func updateCardLastSubmittedPrompt(_ cardID: UUID, prompt: String?, in boardID: UUID) {
        guard let (bi, ci) = cardIndices(cardID: cardID, boardID: boardID) else { return }
        guard boards[bi].cards[ci].lastSubmittedPrompt != prompt else { return }
        boards[bi].cards[ci].lastSubmittedPrompt = prompt
        scheduleSave()
    }

    func consumePendingLaunchPrompt(_ cardID: UUID, in boardID: UUID) {
        guard let (bi, ci) = cardIndices(cardID: cardID, boardID: boardID) else { return }
        guard boards[bi].cards[ci].pendingLaunchPrompt != nil else { return }
        boards[bi].cards[ci].pendingLaunchPrompt = nil
        scheduleSave()
    }

    func fanOutClaudePrompt(from sourceCardID: UUID, in boardID: UUID, count: Int) {
        guard (1...10).contains(count),
              let (bi, ci) = cardIndices(cardID: sourceCardID, boardID: boardID) else {
            return
        }

        let sourceCard = boards[bi].cards[ci]
        let resolvedAgent = sourceCard.agent ?? boards[bi].agent
        guard resolvedAgent == .claude else { return }

        let normalizedPrompt = sourceCard.lastSubmittedPrompt?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalizedPrompt, !normalizedPrompt.isEmpty else { return }

        var nextOrderIndex = (
            boards[bi].cards
                .filter { $0.column == sourceCard.column }
                .map(\.orderIndex)
                .min() ?? 1
        ) - 1

        var clonedCards: [Card] = []
        clonedCards.reserveCapacity(count)

        for copyNumber in stride(from: count, through: 1, by: -1) {
            clonedCards.append(
                Card(
                    title: fanOutCloneTitle(for: sourceCard.title, copyNumber: copyNumber),
                    lastSubmittedPrompt: normalizedPrompt,
                    pendingLaunchPrompt: normalizedPrompt,
                    column: sourceCard.column,
                    orderIndex: nextOrderIndex,
                    agent: .claude
                )
            )
            nextOrderIndex -= 1
        }

        boards[bi].cards.append(contentsOf: clonedCards)
        scheduleSave()

        if let repositoryPath = boards[bi].repositoryPath,
           GitService.isGitRepository(path: repositoryPath) {
            for clonedCard in clonedCards {
                Task {
                    await createWorktreeForCard(
                        clonedCard.id,
                        in: boardID,
                        repositoryPath: repositoryPath
                    )
                }
            }
        } else {
            for clonedCard in clonedCards {
                cmuxHost?.prewarmWorkspaceForBackgroundLaunch(for: clonedCard, boardID: boardID)
            }
        }
    }

    func updateFileBrowserSession(_ cardID: UUID, in boardID: UUID, session: FileBrowserSessionState?) {
        guard let (bi, ci) = cardIndices(cardID: cardID, boardID: boardID) else { return }
        boards[bi].cards[ci].fileBrowserSession = session
        scheduleSave()
    }

    func requestDeleteSelectedCard() {
        guard let board = selectedBoard, let card = selectedCard else { return }
        deleteConfirmationRequest = .card(boardID: board.id, card: card)
    }

    func requestDeleteColumn(_ column: Column, in boardID: UUID) {
        guard column.supportsBulkDelete,
              let board = board(for: boardID) else { return }

        let cards = board.cards(in: column)
        guard !cards.isEmpty else { return }

        deleteConfirmationRequest = .column(boardID: boardID, column: column, cards: cards)
    }

    func confirmDeleteRequest() {
        guard let request = deleteConfirmationRequest else { return }
        deleteConfirmationRequest = nil

        switch request.target {
        case .card(let boardID, let cardID, _):
            deleteCard(cardID, from: boardID)
        case .column(let boardID, let column, let snapshotCardIDs):
            let selectedCardDeletionContext = deleteSelectionContext(
                boardID: boardID,
                deletedCardIDs: Set(snapshotCardIDs),
                fallbackColumn: column
            )
            deleteCards(
                Set(snapshotCardIDs),
                from: boardID,
                selectionContext: selectedCardDeletionContext
            )
        }
    }

    func cancelDeleteRequest() {
        deleteConfirmationRequest = nil
    }

    func deleteCard(_ cardID: UUID, from boardID: UUID) {
        let selectionContext = deleteSelectionContext(
            boardID: boardID,
            deletedCardIDs: Set([cardID]),
            fallbackColumn: nil
        )
        deleteCards(Set([cardID]), from: boardID, selectionContext: selectionContext)
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

    private struct DeleteSelectionContext {
        let column: Column
        let deletedIndex: Int
    }

    // MARK: - O(1) Lookup Cache

    private func invalidateLookupCache() {
        boardIndexCache = nil
        _sortedBoardsCache = nil
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

    private func deleteSelectionContext(
        boardID: UUID,
        deletedCardIDs: Set<UUID>,
        fallbackColumn: Column?
    ) -> DeleteSelectionContext? {
        guard let selectedCardID,
              let board = board(for: boardID) else { return nil }

        guard deletedCardIDs.contains(selectedCardID),
              let selectedCard = board.cards.first(where: { $0.id == selectedCardID }) else {
            return nil
        }

        let column = fallbackColumn ?? selectedCard.column
        guard let deletedIndex = board.cards(in: column).firstIndex(where: { $0.id == selectedCardID }) else {
            return nil
        }

        return DeleteSelectionContext(column: column, deletedIndex: deletedIndex)
    }

    private func deleteCards(
        _ cardIDs: Set<UUID>,
        from boardID: UUID,
        selectionContext: DeleteSelectionContext? = nil
    ) {
        guard let boardIndex = boardIndex(for: boardID) else { return }

        guard !cardIDs.isEmpty else { return }

        let cardsToDelete = boards[boardIndex].cards.filter { cardIDs.contains($0.id) }
        guard !cardsToDelete.isEmpty else { return }

        let repoPath = boards[boardIndex].repositoryPath
        let shouldAdjustSelection = selectedCardID.map { cardIDs.contains($0) } ?? false

        if let overlayCardID = overlayState.cardID, cardIDs.contains(overlayCardID) {
            overlayState = .none
        }
        if let request = deleteConfirmationRequest, request.affectsAnyCard(in: cardIDs) {
            deleteConfirmationRequest = nil
        }
        if let draggedCardID, cardIDs.contains(draggedCardID) {
            self.draggedCardID = nil
        }

        for card in cardsToDelete {
            cmuxHost?.removeWorkspace(for: card.id)
            cmuxHost?.forgetCardRuntimeState(for: card.id)
            onCardDeleted?(card.id)
        }

        boards[boardIndex].cards.removeAll { cardIDs.contains($0.id) }

        if shouldAdjustSelection {
            if let selectionContext {
                selectNextCardAfterDeletion(
                    boardIndex: boardIndex,
                    column: selectionContext.column,
                    deletedIndex: selectionContext.deletedIndex
                )
            } else {
                selectedCardID = nil
            }
        }

        scheduleSave()

        if let repoPath,
           GitService.isGitRepository(path: repoPath) {
            for card in cardsToDelete where card.worktreePath != nil {
                let cardID = card.id
                Task {
                    await deleteWorktreeForCard(cardID, repositoryPath: repoPath)
                }
            }
        }
    }

    private func fanOutCloneTitle(for title: String, copyNumber: Int) -> String {
        "\(title) (\(copyNumber))"
    }

    // MARK: - Worktree Operations

    private func createWorktreeForCard(_ cardID: UUID, in boardID: UUID, repositoryPath: String) async {
        do {
            let worktreePath = try await GitService.createWorktree(cardID: cardID, repositoryPath: repositoryPath)
            guard let (bi, ci) = cardIndices(cardID: cardID, boardID: boardID) else { return }
            boards[bi].cards[ci].worktreePath = worktreePath
            let updatedCard = boards[bi].cards[ci]
            if selectedBoardID == boardID, selectedCardID == cardID {
                cmuxHost?.syncSelection(card: updatedCard, boardID: boardID)
            } else if updatedCard.pendingLaunchPrompt != nil {
                cmuxHost?.prewarmWorkspaceForBackgroundLaunch(for: updatedCard, boardID: boardID)
            }
            scheduleSave()
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
        guard persistenceEnabled else { return }
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
