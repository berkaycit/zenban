import AppKit
import Foundation
import Testing
@testable import zenban

struct AgentRuntimeTests {
    @Test
    func launchPlanBuildsExpectedShellCommand() {
        let cardID = UUID()
        let boardID = UUID()
        let panelID = UUID()

        let plan = AgentLauncher.plan(
            for: .claude,
            cardID: cardID,
            boardID: boardID,
            panelID: panelID,
            workingDirectory: "/tmp/demo project",
            reason: .worktreeReady
        )

        #expect(plan.command == "claude --dangerously-skip-permissions")
        #expect(plan.shellCommand.contains("cd -- '/tmp/demo project' &&"))
        #expect(plan.shellCommand.contains("env -u CLAUDECODE"))
        #expect(plan.shellCommand.contains("CMUX_WORKSPACE_ID='\(cardID.uuidString)'"))
        #expect(plan.shellCommand.contains("CMUX_SURFACE_ID='\(panelID.uuidString)'"))
        #expect(plan.shellCommand.contains("ZENBAN_AGENT='claude'"))
        #expect(plan.shellCommand.contains("ZENBAN_AGENT_LAUNCH_REASON='worktreeReady'"))
        #expect(plan.interruptExisting == false)
    }

    @Test
    func runtimeAgentLookupUsesRuntimeIDs() {
        #expect(Agent.fromRuntimeID("claude") == .claude)
        #expect(Agent.fromRuntimeID("codex") == .codex)
        #expect(Agent.fromRuntimeID("gemini") == .gemini)
        #expect(Agent.fromRuntimeID("Claude") == .claude)
        #expect(Agent.fromRuntimeID("unknown") == nil)
    }

    @Test
    func legacyClaudeHookSignalsMapToSimpleLifecycle() {
        #expect(AgentRuntimeSignal(legacyClaudeHook: "prompt-submit") == .started)
        #expect(AgentRuntimeSignal(legacyClaudeHook: "stop") == .completed)
        #expect(AgentRuntimeSignal(legacyClaudeHook: "idle") == .completed)
        #expect(AgentRuntimeSignal(legacyClaudeHook: "notification") == nil)
        #expect(AgentRuntimeSignal.shouldIgnoreLegacyClaudeHook("session-start"))
        #expect(AgentRuntimeSignal.shouldIgnoreLegacyClaudeHook("active"))
        #expect(AgentRuntimeSignal.shouldIgnoreLegacyClaudeHook("notification"))
        #expect(AgentRuntimeSignal.shouldIgnoreLegacyClaudeHook("notify"))
        #expect(!AgentRuntimeSignal.shouldIgnoreLegacyClaudeHook("prompt-submit"))
    }

    @Test
    func notificationAuthorizationHelpersMapAndDeferAsExpected() {
        #expect(NotificationService.authorizationState(from: .notDetermined) == .notDetermined)
        #expect(NotificationService.authorizationState(from: .denied) == .denied)
        #expect(NotificationService.authorizationState(from: .authorized) == .authorized)
        #expect(NotificationService.authorizationState(from: .provisional) == .provisional)
        #expect(
            NotificationService.shouldDeferAutomaticAuthorizationRequest(
                status: .notDetermined,
                isAppActive: false
            )
        )
        #expect(
            !NotificationService.shouldDeferAutomaticAuthorizationRequest(
                status: .notDetermined,
                isAppActive: true
            )
        )
        #expect(
            !NotificationService.shouldDeferAutomaticAuthorizationRequest(
                status: .authorized,
                isAppActive: false
            )
        )
    }

    @Test
    func workflowStartedArmsTodoCard() {
        var reducer = AgentTaskWorkflowReducer()
        let snapshot = AgentSessionSnapshot(
            cardID: UUID(),
            boardID: UUID(),
            cardTitle: "codex-1",
            column: .todo,
            agent: .codex,
            tmuxSessionID: UUID().uuidString
        )

        reducer.registerLaunch(for: snapshot.cardID)
        let outcome = reducer.apply(signal: .started, snapshot: snapshot)

        #expect(outcome == .none)
        #expect(reducer.hasActiveTask(for: snapshot.cardID))
    }

    @Test
    func workflowMovesInReviewCardsBackToTodoOnStart() {
        var reducer = AgentTaskWorkflowReducer()
        let snapshot = AgentSessionSnapshot(
            cardID: UUID(),
            boardID: UUID(),
            cardTitle: "claude-1",
            column: .inProgress,
            agent: .claude,
            tmuxSessionID: UUID().uuidString
        )

        reducer.registerLaunch(for: snapshot.cardID)
        let outcome = reducer.apply(signal: .started, snapshot: snapshot)

        #expect(outcome == AgentTaskWorkflowOutcome(action: .moveToTodo))
        #expect(reducer.hasActiveTask(for: snapshot.cardID))
    }

    @Test
    func workflowIgnoresSecondStartWhileAlreadyActive() {
        var reducer = AgentTaskWorkflowReducer()
        let snapshot = AgentSessionSnapshot(
            cardID: UUID(),
            boardID: UUID(),
            cardTitle: "gemini-1",
            column: .todo,
            agent: .gemini,
            tmuxSessionID: UUID().uuidString
        )

        reducer.registerLaunch(for: snapshot.cardID)
        _ = reducer.apply(signal: .started, snapshot: snapshot)
        let outcome = reducer.apply(signal: .started, snapshot: snapshot)

        #expect(outcome == .none)
        #expect(reducer.hasActiveTask(for: snapshot.cardID))
    }

    @Test
    func workflowCompletesOnlyAfterStarted() {
        var reducer = AgentTaskWorkflowReducer()
        let snapshot = AgentSessionSnapshot(
            cardID: UUID(),
            boardID: UUID(),
            cardTitle: "claude-2",
            column: .todo,
            agent: .claude,
            tmuxSessionID: UUID().uuidString
        )

        reducer.registerLaunch(for: snapshot.cardID)
        _ = reducer.apply(signal: .started, snapshot: snapshot)
        let outcome = reducer.apply(signal: .completed, snapshot: snapshot)

        #expect(outcome == AgentTaskWorkflowOutcome(action: .complete))
        #expect(!reducer.hasActiveTask(for: snapshot.cardID))
    }

    @Test
    func workflowIgnoresCompletionWithoutActiveTask() {
        var reducer = AgentTaskWorkflowReducer()
        let snapshot = AgentSessionSnapshot(
            cardID: UUID(),
            boardID: UUID(),
            cardTitle: "codex-2",
            column: .todo,
            agent: .codex,
            tmuxSessionID: UUID().uuidString
        )

        reducer.registerLaunch(for: snapshot.cardID)
        let outcome = reducer.apply(signal: .completed, snapshot: snapshot)

        #expect(outcome == .none)
        #expect(!reducer.hasActiveTask(for: snapshot.cardID))
    }

    @Test
    func workflowCompletionOnlyFiresOnce() {
        var reducer = AgentTaskWorkflowReducer()
        let snapshot = AgentSessionSnapshot(
            cardID: UUID(),
            boardID: UUID(),
            cardTitle: "gemini-2",
            column: .todo,
            agent: .gemini,
            tmuxSessionID: UUID().uuidString
        )

        reducer.registerLaunch(for: snapshot.cardID)
        _ = reducer.apply(signal: .started, snapshot: snapshot)
        let firstOutcome = reducer.apply(signal: .completed, snapshot: snapshot)
        let secondOutcome = reducer.apply(signal: .completed, snapshot: snapshot)

        #expect(firstOutcome == AgentTaskWorkflowOutcome(action: .complete))
        #expect(secondOutcome == .none)
    }

    @Test
    func workflowLeavesDoneCardsUntouched() {
        var reducer = AgentTaskWorkflowReducer()
        let snapshot = AgentSessionSnapshot(
            cardID: UUID(),
            boardID: UUID(),
            cardTitle: "done-card",
            column: .done,
            agent: .gemini,
            tmuxSessionID: UUID().uuidString
        )

        reducer.registerLaunch(for: snapshot.cardID)
        let startedOutcome = reducer.apply(signal: .started, snapshot: snapshot)
        let completedOutcome = reducer.apply(signal: .completed, snapshot: snapshot)

        #expect(startedOutcome == .none)
        #expect(completedOutcome == .none)
        #expect(!reducer.hasActiveTask(for: snapshot.cardID))
    }

    @Test
    func registerLaunchClearsPreviouslyActiveTask() {
        var reducer = AgentTaskWorkflowReducer()
        let cardID = UUID()
        let snapshot = AgentSessionSnapshot(
            cardID: cardID,
            boardID: UUID(),
            cardTitle: "restart-card",
            column: .todo,
            agent: .claude,
            tmuxSessionID: UUID().uuidString
        )

        reducer.registerLaunch(for: cardID)
        _ = reducer.apply(signal: .started, snapshot: snapshot)
        reducer.registerLaunch(for: cardID)

        #expect(!reducer.hasActiveTask(for: cardID))
    }

    @Test
    @MainActor
    func boardSelectionChangeKeepsMatchingCardSelection() {
        let boardID = UUID()
        let card = Card(id: UUID(), title: "task")
        let store = BoardStore()
        store.boards = [Board(id: boardID, name: "Board", cards: [card])]
        store.selectedBoardID = boardID
        store.selectedCardID = card.id

        store.clearSelectedCardIfNeededForSelectedBoardChange()

        #expect(store.selectedCardID == card.id)
    }

    @Test
    @MainActor
    func boardSelectionChangeClearsStaleCardSelection() {
        let boardID = UUID()
        let store = BoardStore()
        store.boards = [Board(id: boardID, name: "Board", cards: [])]
        store.selectedBoardID = boardID
        store.selectedCardID = UUID()

        store.clearSelectedCardIfNeededForSelectedBoardChange()

        #expect(store.selectedCardID == nil)
    }

    @Test
    @MainActor
    func moveCardReturnsTrueOnlyForRealColumnTransitions() {
        let boardID = UUID()
        let card = Card(id: UUID(), title: "task", column: .todo, orderIndex: 0)
        let store = BoardStore()
        store.boards = [Board(id: boardID, name: "Board", cards: [card])]

        let firstMove = store.moveCard(card.id, to: .inProgress, in: boardID)
        let secondMove = store.moveCard(card.id, to: .inProgress, in: boardID)

        #expect(firstMove)
        #expect(!secondMove)
        #expect(store.boards[0].cards[0].column == .inProgress)
    }

    @Test
    func submitHeuristicsDetectKeyboardSubmit() {
        #expect(
            TerminalUserSubmitHeuristics.isKeyboardSubmit(
                keyCode: 36,
                modifierFlags: [],
                isRepeat: false,
                isComposing: false
            )
        )
        #expect(
            !TerminalUserSubmitHeuristics.isKeyboardSubmit(
                keyCode: 36,
                modifierFlags: [.command],
                isRepeat: false,
                isComposing: false
            )
        )
        #expect(
            !TerminalUserSubmitHeuristics.isKeyboardSubmit(
                keyCode: 36,
                modifierFlags: [],
                isRepeat: false,
                isComposing: true
            )
        )
    }

    @Test
    func submitHeuristicsDetectMeaningfulDraftsAndTrailingNewlines() {
        #expect(TerminalUserSubmitHeuristics.hasMeaningfulDraftInput("fix the failing test"))
        #expect(!TerminalUserSubmitHeuristics.hasMeaningfulDraftInput("   "))
        #expect(TerminalUserSubmitHeuristics.textTriggersSubmit("run it\n"))
        #expect(TerminalUserSubmitHeuristics.textTriggersSubmit("run it\r"))
        #expect(!TerminalUserSubmitHeuristics.textTriggersSubmit("run it"))
    }
}
