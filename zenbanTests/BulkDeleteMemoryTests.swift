import AppKit
import Foundation
import Testing
@testable import zenban

@MainActor
struct BulkDeleteMemoryTests {
    private enum WaitError: Error {
        case timedOut
    }

    @Test
    func bulkDeleteReleasesDeletedCardRuntimeObjects() async throws {
        let appDelegate = AppDelegate()
        let deletedA = Card(title: "todo-a", column: .todo, orderIndex: 0, agent: .claude, worktreePath: "/tmp/todo-a")
        let survivor = Card(title: "done", column: .done, orderIndex: 0, agent: .claude, worktreePath: "/tmp/done")
        let deletedB = Card(title: "todo-b", column: .todo, orderIndex: 1, agent: .claude, worktreePath: "/tmp/todo-b")
        let board = Board(
            name: "Bulk Delete Memory",
            cards: [deletedA, survivor, deletedB],
            repositoryPath: "/tmp/repo",
            agent: .claude
        )
        let store = BoardStore(initialBoards: [board], persistenceEnabled: false)
        let hostStore = CmuxHostStore()
        let window = makeWindow()

        defer {
            window.close()
            _ = appDelegate
        }

        store.selectedBoardID = board.id
        store.selectedCardID = deletedA.id
        store.cmuxHost = hostStore
        hostStore.attach(boardStore: store)
        hostStore.registerMainWindow(window)

        hostStore.syncSelection(card: deletedA, boardID: board.id)
        hostStore.syncSelection(card: deletedB, boardID: board.id)
        hostStore.ensureBrowserSurface(
            for: deletedA,
            boardID: board.id,
            url: try #require(URL(string: "about:blank"))
        )

        weak var deletedWorkspaceA: Workspace?
        weak var deletedWorkspaceB: Workspace?
        weak var deletedTerminalA: TerminalPanel?
        weak var deletedTerminalB: TerminalPanel?
        weak var deletedBrowserPanel: BrowserPanel?

        do {
            let workspaceA = try #require(hostStore.workspace(for: deletedA.id))
            let workspaceB = try #require(hostStore.workspace(for: deletedB.id))

            deletedWorkspaceA = workspaceA
            deletedWorkspaceB = workspaceB
            deletedTerminalA = try #require(workspaceA.focusedTerminalPanel)
            deletedTerminalB = try #require(workspaceB.focusedTerminalPanel)
            deletedBrowserPanel = try #require(hostStore.browserSurface(for: deletedA.id)?.panel)
        }

        store.requestDeleteColumn(.todo, in: board.id)
        store.confirmDeleteRequest()

        try await waitUntil {
            store.card(id: deletedA.id) == nil
                && store.card(id: deletedB.id) == nil
                && store.card(id: survivor.id) != nil
                && hostStore.workspace(for: deletedA.id) == nil
                && hostStore.workspace(for: deletedB.id) == nil
                && deletedWorkspaceA == nil
                && deletedWorkspaceB == nil
                && deletedTerminalA == nil
                && deletedTerminalB == nil
                && deletedBrowserPanel == nil
        }
    }

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(3),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        throw WaitError.timedOut
    }
}
