import AppKit
import Foundation
import Testing
@testable import zenban

struct AgentRuntimeTests {
    @Test
    func launchPlanBuildsExpectedShellCommand() {
        let cardID = UUID()
        let boardID = UUID()

        let plan = AgentLauncher.plan(
            for: .claude,
            cardID: cardID,
            boardID: boardID,
            workingDirectory: "/tmp/demo project",
            reason: .worktreeReady
        )

        #expect(plan.command == "claude --dangerously-skip-permissions")
        #expect(plan.shellCommand.contains("cd -- '/tmp/demo project' &&"))
        #expect(plan.shellCommand.contains("env -u CLAUDECODE"))
        #expect(plan.shellCommand.contains("ZENBAN_AGENT='claude'"))
        #expect(plan.shellCommand.contains("ZENBAN_AGENT_LAUNCH_REASON='worktreeReady'"))
    }

    @Test
    func parserDetectsClaudeWaitingAndBusyStates() {
        let waitingOutput = """
        Do you want to proceed?
          1. Yes
          2. No
        Esc to cancel · Tab to amend
        """
        let waitingStatus = AgentStatusParser.parse(
            output: waitingOutput,
            agent: .claude,
            isRecentActivity: true
        )
        #expect(waitingStatus == .waiting)

        let busyStatus = AgentStatusParser.parse(
            output: "⠹ Working on your request...",
            agent: .claude,
            isRecentActivity: true
        )
        #expect(busyStatus == .running)

        let idleStatus = AgentStatusParser.parse(
            output: "Claude finished the task.\n  ? for shortcuts",
            agent: .claude,
            isRecentActivity: false
        )
        #expect(idleStatus == .idle)
    }

    @Test
    func parserDetectsGenericWaitingAndErrors() {
        let waitingStatus = AgentStatusParser.parse(
            output: "Install packages? [Y/n]",
            agent: .codex,
            isRecentActivity: true
        )
        #expect(waitingStatus == .waiting)

        let errorStatus = AgentStatusParser.parse(
            output: "panic: runtime error",
            agent: .gemini,
            isRecentActivity: true
        )
        #expect(errorStatus == .error)
    }

    @Test
    func captureFailureHeuristicsEscalateToStoppedAfterThreshold() {
        #expect(
            AgentCaptureFailureHeuristics.rawStatus(
                afterConsecutiveFailures: AgentCaptureFailureHeuristics.stopThreshold - 1,
                isRecentActivity: true
            ) == .running
        )
        #expect(
            AgentCaptureFailureHeuristics.rawStatus(
                afterConsecutiveFailures: AgentCaptureFailureHeuristics.stopThreshold,
                isRecentActivity: true
            ) == .stopped
        )
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
    func workflowRequiresBaselineBeforeAnyCompletion() {
        var reducer = AgentTaskWorkflowReducer()
        let snapshot = AgentSessionSnapshot(
            cardID: UUID(),
            boardID: UUID(),
            cardTitle: "cc-1",
            column: .todo,
            agent: .claude,
            tmuxSessionID: UUID().uuidString
        )

        reducer.registerLaunch(for: snapshot.cardID)
        let outcome = reducer.apply(snapshot: snapshot, rawStatus: .idle)

        #expect(outcome == .none)
        #expect(reducer.cycleState(for: snapshot.cardID) == .warmingUp)
    }

    @Test
    func workflowIgnoresStartupActivityBeforeBaseline() {
        var reducer = AgentTaskWorkflowReducer()
        let cardID = UUID()
        let snapshot = AgentSessionSnapshot(
            cardID: cardID,
            boardID: UUID(),
            cardTitle: "cc-startup",
            column: .todo,
            agent: .claude,
            tmuxSessionID: UUID().uuidString
        )

        reducer.registerLaunch(for: cardID)
        let runningOutcome = reducer.apply(snapshot: snapshot, rawStatus: .running)
        let idleOutcome = reducer.apply(snapshot: snapshot, rawStatus: .idle)

        #expect(runningOutcome == .none)
        #expect(idleOutcome == .none)
        #expect(reducer.cycleState(for: cardID) == .warmingUp)
    }

    @Test
    func workflowRequiresWarmupIdleBeforeArmingCompletion() {
        var reducer = AgentTaskWorkflowReducer()
        let cardID = UUID()
        let snapshot = AgentSessionSnapshot(
            cardID: cardID,
            boardID: UUID(),
            cardTitle: "claude-warmup",
            column: .todo,
            agent: .claude,
            tmuxSessionID: UUID().uuidString
        )

        reducer.registerLaunch(for: cardID)
        let baselineOutcome = reducer.apply(snapshot: snapshot, rawStatus: .idle)
        let startupActivityOutcome = reducer.apply(snapshot: snapshot, rawStatus: .running)
        let startupIdleOutcome = reducer.apply(snapshot: snapshot, rawStatus: .idle)

        #expect(baselineOutcome == .none)
        #expect(startupActivityOutcome == .none)
        #expect(startupIdleOutcome == .none)
        #expect(reducer.cycleState(for: cardID) == .ready)
    }

    @Test
    func workflowStaysReadyWithoutSubmissionWhenActivityAppears() {
        var reducer = AgentTaskWorkflowReducer()
        let cardID = UUID()
        let snapshot = AgentSessionSnapshot(
            cardID: cardID,
            boardID: UUID(),
            cardTitle: "cc-no-submit",
            column: .todo,
            agent: .claude,
            tmuxSessionID: UUID().uuidString
        )

        reducer.registerLaunch(for: cardID)
        _ = reducer.apply(snapshot: snapshot, rawStatus: .idle)
        _ = reducer.apply(snapshot: snapshot, rawStatus: .idle)

        let outcome = reducer.apply(snapshot: snapshot, rawStatus: .running)

        #expect(outcome == .none)
        #expect(reducer.cycleState(for: cardID) == .ready)
    }

    @Test
    func workflowMovesInReviewCardsBackToTodoOnExplicitSubmission() {
        var reducer = AgentTaskWorkflowReducer()
        let cardID = UUID()
        let boardID = UUID()
        let snapshot = AgentSessionSnapshot(
            cardID: cardID,
            boardID: boardID,
            cardTitle: "cc-2",
            column: .inProgress,
            agent: .claude,
            tmuxSessionID: UUID().uuidString
        )

        reducer.registerLaunch(for: cardID)
        _ = reducer.apply(snapshot: snapshot, rawStatus: .idle)
        _ = reducer.apply(snapshot: snapshot, rawStatus: .idle)

        let outcome = reducer.registerTaskSubmission(snapshot: snapshot)

        #expect(outcome == AgentTaskWorkflowOutcome(action: .moveToTodo))
        #expect(reducer.cycleState(for: cardID) == .activeTask)
    }

    @Test
    func workflowCompletesTodoCardsOnlyAfterExplicitSubmissionReturnsToIdle() {
        var reducer = AgentTaskWorkflowReducer()
        let cardID = UUID()
        let boardID = UUID()

        reducer.registerLaunch(for: cardID)
        let baseline = AgentSessionSnapshot(
            cardID: cardID,
            boardID: boardID,
            cardTitle: "codex-1",
            column: .todo,
            agent: .codex,
            tmuxSessionID: UUID().uuidString
        )
        _ = reducer.apply(snapshot: baseline, rawStatus: .idle)
        _ = reducer.apply(snapshot: baseline, rawStatus: .idle)
        let submissionOutcome = reducer.registerTaskSubmission(snapshot: baseline)
        _ = reducer.apply(snapshot: baseline, rawStatus: .waiting)
        let outcome = reducer.apply(snapshot: baseline, rawStatus: .idle)

        #expect(submissionOutcome == .none)
        #expect(outcome == AgentTaskWorkflowOutcome(action: .complete))
        #expect(reducer.cycleState(for: cardID) == .ready)
    }

    @Test
    func workflowCompletesActiveTaskOnExplicitCompletionSignal() {
        var reducer = AgentTaskWorkflowReducer()
        let cardID = UUID()
        let snapshot = AgentSessionSnapshot(
            cardID: cardID,
            boardID: UUID(),
            cardTitle: "claude-hook",
            column: .todo,
            agent: .claude,
            tmuxSessionID: UUID().uuidString
        )

        reducer.registerLaunch(for: cardID)
        _ = reducer.apply(snapshot: snapshot, rawStatus: .idle)
        _ = reducer.apply(snapshot: snapshot, rawStatus: .idle)
        _ = reducer.registerTaskSubmission(snapshot: snapshot)

        let outcome = reducer.registerCompletionSignal(snapshot: snapshot)

        #expect(outcome == AgentTaskWorkflowOutcome(action: .complete))
        #expect(reducer.cycleState(for: cardID) == .ready)
    }

    @Test
    func workflowIgnoresExplicitCompletionSignalWithoutActiveTask() {
        var reducer = AgentTaskWorkflowReducer()
        let cardID = UUID()
        let snapshot = AgentSessionSnapshot(
            cardID: cardID,
            boardID: UUID(),
            cardTitle: "claude-hook-idle",
            column: .todo,
            agent: .claude,
            tmuxSessionID: UUID().uuidString
        )

        reducer.registerLaunch(for: cardID)
        _ = reducer.apply(snapshot: snapshot, rawStatus: .idle)
        _ = reducer.apply(snapshot: snapshot, rawStatus: .idle)

        let outcome = reducer.registerCompletionSignal(snapshot: snapshot)

        #expect(outcome == .none)
        #expect(reducer.cycleState(for: cardID) == .ready)
    }

    @Test
    func workflowAllowsSubmissionDuringWarmupWithoutMissingCompletion() {
        var reducer = AgentTaskWorkflowReducer()
        let cardID = UUID()
        let snapshot = AgentSessionSnapshot(
            cardID: cardID,
            boardID: UUID(),
            cardTitle: "warmup-submit",
            column: .todo,
            agent: .claude,
            tmuxSessionID: UUID().uuidString
        )

        reducer.registerLaunch(for: cardID)
        _ = reducer.apply(snapshot: snapshot, rawStatus: .idle)
        let submitOutcome = reducer.registerTaskSubmission(snapshot: snapshot)
        let outcome = reducer.apply(snapshot: snapshot, rawStatus: .idle)

        #expect(submitOutcome == .none)
        #expect(outcome == AgentTaskWorkflowOutcome(action: .complete))
        #expect(reducer.cycleState(for: cardID) == .ready)
    }

    @Test
    func workflowLeavesDoneCardsUntouched() {
        var reducer = AgentTaskWorkflowReducer()
        let cardID = UUID()
        let snapshot = AgentSessionSnapshot(
            cardID: cardID,
            boardID: UUID(),
            cardTitle: "gemini-1",
            column: .done,
            agent: .gemini,
            tmuxSessionID: UUID().uuidString
        )

        reducer.registerLaunch(for: cardID)
        _ = reducer.apply(snapshot: snapshot, rawStatus: .idle)
        _ = reducer.apply(snapshot: snapshot, rawStatus: .idle)
        let submitOutcome = reducer.registerTaskSubmission(snapshot: snapshot)
        let outcome = reducer.apply(snapshot: snapshot, rawStatus: .running)

        #expect(submitOutcome == .none)
        #expect(outcome == .none)
        #expect(reducer.cycleState(for: cardID) == .ready)
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
