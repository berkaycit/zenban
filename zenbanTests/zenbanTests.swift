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

    @MainActor
    @Test
    func failedWorktreeCreationReleasesWorkspaceWait() async throws {
        let parentDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parentDirectory) }

        let repositoryPath = try await GitService.createRepository(
            name: "empty-repository",
            parentPath: parentDirectory.path
        )
        let board = Board(name: "Empty Git", repositoryPath: repositoryPath, agent: .claude)
        let store = BoardStore(initialBoards: [board], persistenceEnabled: false)
        let hostStore = CmuxHostStore()
        store.cmuxHost = hostStore
        hostStore.attach(boardStore: store)
        store.selectedBoardID = board.id

        store.addCardWithAutoName(to: board.id)

        let createdCardID = try #require(store.board(for: board.id)?.cards.first?.id)
        try await waitUntil {
            !store.isWorktreeCreationPending(for: createdCardID)
        }

        let updatedCard = try #require(store.board(for: board.id)?.cards.first)
        #expect(updatedCard.worktreePath == nil)
        #expect(!hostStore.isWaitingForWorktree(for: updatedCard, boardID: board.id))
        #expect(hostStore.workspace(for: updatedCard.id) != nil)
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

        #expect(cards.map(\.title) == ["Login bug (1)", "Login bug (2)", "Login bug (3)", "Login bug"])
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

    @Test
    func zenbanGhosttyDiskConfigPathsUseAppScopedConfigAndAppendEmbeddedOverrideLast() throws {
        let resourceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let appSupportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: resourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
        let overrideURL = resourceDirectory
            .appendingPathComponent("ghostty-embedded-performance", isDirectory: false)
            .appendingPathExtension("config")
        try """
        scrollback-limit = 8000000
        image-storage-limit = 8000000
        background-blur = false
        """.write(to: overrideURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: resourceDirectory)
            try? FileManager.default.removeItem(at: appSupportDirectory)
        }

        let configPaths = GhosttyConfig.configPathsForDiskLoad(
            currentBundleIdentifier: "com.berkaycit.zenban.tests",
            bundleResourceURL: resourceDirectory,
            appSupportDirectory: appSupportDirectory
        )
        let expectedConfigURL = appSupportDirectory
            .appendingPathComponent("com.berkaycit.zenban.tests", isDirectory: true)
            .appendingPathComponent("config.ghostty", isDirectory: false)

        #expect(configPaths.last == overrideURL.path)
        #expect(configPaths.first == expectedConfigURL.path)
        #expect(!configPaths.contains(NSString(string: "~/.config/ghostty/config").expandingTildeInPath))
    }

    @Test
    func zenbanGhosttyBootstrapSeedsDefaultConfigIntoAppSupport() throws {
        let appSupportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: appSupportDirectory) }

        let configURL = try #require(GhosttyConfig.ensureAppScopedConfigExists(
            currentBundleIdentifier: "com.berkaycit.zenban.tests",
            appSupportDirectory: appSupportDirectory
        ))
        let contents = try String(contentsOf: configURL, encoding: .utf8)

        #expect(configURL.path == appSupportDirectory
            .appendingPathComponent("com.berkaycit.zenban.tests", isDirectory: true)
            .appendingPathComponent("config.ghostty", isDirectory: false)
            .path)
        #expect(contents.contains("theme = Catppuccin Mocha"))
        #expect(contents.contains("keybind = alt+shift+left=previous_tab"))
        #expect(contents.contains("keybind = cmd+d=new_split:right"))
    }

    @Test
    func ghosttySurfaceOcclusionVisibilityRequiresUiAndWindowVisibility() {
        #expect(GhosttyNSView.effectiveSurfaceOcclusionVisibility(
            visibleInUI: true,
            hiddenInHierarchy: false,
            windowVisible: true
        ))
        #expect(!GhosttyNSView.effectiveSurfaceOcclusionVisibility(
            visibleInUI: false,
            hiddenInHierarchy: false,
            windowVisible: true
        ))
        #expect(!GhosttyNSView.effectiveSurfaceOcclusionVisibility(
            visibleInUI: true,
            hiddenInHierarchy: true,
            windowVisible: true
        ))
        #expect(!GhosttyNSView.effectiveSurfaceOcclusionVisibility(
            visibleInUI: true,
            hiddenInHierarchy: false,
            windowVisible: false
        ))
    }

    private func waitUntil(
        timeout: Duration = .seconds(3),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if await condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        throw WaitError.timedOut
    }

    private enum WaitError: Error {
        case timedOut
    }
}
