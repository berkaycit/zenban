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
        #expect(reducer.cycleState(for: snapshot.cardID) == .ready)
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
        #expect(reducer.cycleState(for: cardID) == .ready)
    }

    @Test
    func workflowMovesInReviewCardsBackToTodoWhenWorkStarts() {
        var reducer = AgentTaskWorkflowReducer()
        let cardID = UUID()
        let boardID = UUID()

        reducer.registerLaunch(for: cardID)
        _ = reducer.apply(
            snapshot: AgentSessionSnapshot(
                cardID: cardID,
                boardID: boardID,
                cardTitle: "cc-2",
                column: .inProgress,
                agent: .claude,
                tmuxSessionID: UUID().uuidString
            ),
            rawStatus: .idle
        )

        let outcome = reducer.apply(
            snapshot: AgentSessionSnapshot(
                cardID: cardID,
                boardID: boardID,
                cardTitle: "cc-2",
                column: .inProgress,
                agent: .claude,
                tmuxSessionID: UUID().uuidString
            ),
            rawStatus: .running
        )

        #expect(outcome == AgentTaskWorkflowOutcome(action: .moveToTodo))
        #expect(reducer.cycleState(for: cardID) == .activeTask)
    }

    @Test
    func workflowCompletesTodoCardsWhenActiveTaskReturnsToIdle() {
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
        _ = reducer.apply(snapshot: baseline, rawStatus: .waiting)

        let outcome = reducer.apply(snapshot: baseline, rawStatus: .idle)

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
        let outcome = reducer.apply(snapshot: snapshot, rawStatus: .running)

        #expect(outcome == .none)
        #expect(reducer.cycleState(for: cardID) == .ready)
    }
}
