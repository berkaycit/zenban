import Foundation

enum AgentLaunchReason: String {
    case initialLaunch
    case worktreeReady
    case agentSwitch
}

struct AgentLaunchPlan: Equatable {
    let agent: Agent
    let command: String
    let workingDirectory: String?
    let environment: [String: String]
    let reason: AgentLaunchReason

    var shellCommand: String {
        let envAssignments = environment.keys.sorted().compactMap { key -> String? in
            guard let value = environment[key] else { return nil }
            return "\(key)=\(Self.quoteForShell(value))"
        }

        let prefixedCommand: String
        if envAssignments.isEmpty {
            prefixedCommand = "env -u CLAUDECODE \(command)"
        } else {
            prefixedCommand = "env -u CLAUDECODE \(envAssignments.joined(separator: " ")) \(command)"
        }

        guard let workingDirectory,
              !workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return prefixedCommand
        }

        return "cd -- \(Self.quoteForShell(workingDirectory)) && \(prefixedCommand)"
    }

    private static func quoteForShell(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

enum AgentLauncher {
    static func plan(
        for agent: Agent,
        cardID: UUID,
        boardID: UUID,
        workingDirectory: String?,
        reason: AgentLaunchReason
    ) -> AgentLaunchPlan {
        AgentLaunchPlan(
            agent: agent,
            command: baseCommand(for: agent),
            workingDirectory: workingDirectory,
            environment: [
                "ZENBAN_AGENT": agent.runtimeID,
                "ZENBAN_AGENT_CARD_ID": cardID.uuidString,
                "ZENBAN_AGENT_BOARD_ID": boardID.uuidString,
                "ZENBAN_AGENT_LAUNCH_REASON": reason.rawValue,
            ],
            reason: reason
        )
    }

    @MainActor
    static func launch(_ plan: AgentLaunchPlan, on panel: TerminalPanel) async -> Bool {
        await TmuxSessionManager.shared.unsetEnvironment(
            sessionID: panel.tmuxSessionID,
            names: ["CLAUDECODE"]
        )
        await TmuxSessionManager.shared.setEnvironment(
            sessionID: panel.tmuxSessionID,
            variables: plan.environment
        )

        if plan.reason == .agentSwitch {
            guard TmuxSessionManager.shared.sendText(sessionID: panel.tmuxSessionID, text: "\u{03}") else {
                return false
            }
            try? await Task.sleep(for: .milliseconds(300))
            guard TmuxSessionManager.shared.sendText(sessionID: panel.tmuxSessionID, text: "\u{03}") else {
                return false
            }
            try? await Task.sleep(for: .seconds(2))
        }

        return TmuxSessionManager.shared.sendText(
            sessionID: panel.tmuxSessionID,
            text: plan.shellCommand + "\n"
        )
    }

    private static func baseCommand(for agent: Agent) -> String {
        switch agent {
        case .claude:
            "claude --dangerously-skip-permissions"
        case .codex:
            "codex --yolo"
        case .gemini:
            "gemini --yolo"
        }
    }
}

enum AgentRawStatus: Equatable {
    case running
    case waiting
    case idle
    case error
    case stopped

    var establishesReadyBaseline: Bool {
        switch self {
        case .idle, .waiting, .error:
            true
        case .running, .stopped:
            false
        }
    }
}

struct AgentSessionSnapshot: Equatable {
    let cardID: UUID
    let boardID: UUID
    let cardTitle: String
    let column: Column
    let agent: Agent
    let tmuxSessionID: String

    var tmuxSessionName: String {
        TmuxSessionManager.shared.sessionName(for: tmuxSessionID)
    }
}

private struct AgentParsedStatus {
    let rawStatus: AgentRawStatus
    let shouldTrustActivity: Bool
}

enum AgentStatusParser {
    private static let spinnerCharacters = [
        "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏", "✳", "✽", "✶", "✢",
    ]

    private static let claudeBusyPatterns = [
        #"ctrl\+c to interrupt"#,
        #"….*tokens"#,
    ]

    private static let claudeWaitingPatterns = [
        #"Do you want to proceed\?"#,
        #"\d\.\s*Yes\b"#,
        #"Esc to cancel.*Tab to amend"#,
        #"Enter to select.*to navigate"#,
        #"\(Y\/n\)"#,
        #"Continue\?"#,
        #"Approve this plan\?"#,
        #"\[Y\/n\]"#,
        #"\[y\/N\]"#,
        #"Yes,? allow once"#,
        #"Allow always"#,
        #"No,? and tell Claude"#,
    ]

    private static let claudeStoppedPatterns = [
        #"Resume this session with:"#,
        #"claude --resume"#,
        #"Press Ctrl-C again to exit"#,
    ]

    private static let genericWaitingPatterns = [
        #"\? \(y\/n\)"#,
        #"\[Y\/n\]"#,
        #"Press enter to continue"#,
        #"waiting for.*input"#,
        #"do you want to"#,
    ]

    private static let genericErrorPatterns = [
        #"error:"#,
        #"failed:"#,
        #"exception:"#,
        #"traceback"#,
        #"panic:"#,
    ]

    static func stripANSI(from text: String) -> String {
        text
            .replacingOccurrences(of: #"\x1b\[[0-9;]*[a-zA-Z]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\x1b\][^\x07]*\x07"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\x1b[PX^_][^\x1b]*\x1b\\"#, with: "", options: .regularExpression)
    }

    static func parse(
        output: String,
        agent: Agent,
        isRecentActivity: Bool
    ) -> AgentRawStatus {
        let parsed = parse(output: output, agent: agent)

        switch parsed.rawStatus {
        case .waiting, .error, .stopped:
            return parsed.rawStatus
        case .running:
            return .running
        case .idle:
            return (parsed.shouldTrustActivity && isRecentActivity) ? .running : .idle
        }
    }

    private static func parse(output: String, agent: Agent) -> AgentParsedStatus {
        let cleaned = stripANSI(from: output)
        var relevantLines = cleaned.components(separatedBy: .newlines)
        while let last = relevantLines.last,
              last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            relevantLines.removeLast()
        }
        let lastLines = relevantLines.suffix(30).joined(separator: "\n")
        let lastFewLines = relevantLines.suffix(10).joined(separator: "\n")

        switch agent {
        case .claude:
            if matchesAny(patterns: claudeStoppedPatterns, in: lastLines) {
                return AgentParsedStatus(rawStatus: .stopped, shouldTrustActivity: false)
            }
            if matchesAny(patterns: claudeWaitingPatterns, in: lastLines) {
                return AgentParsedStatus(rawStatus: .waiting, shouldTrustActivity: false)
            }
            if matchesAny(patterns: genericErrorPatterns, in: lastLines) {
                return AgentParsedStatus(rawStatus: .error, shouldTrustActivity: false)
            }
            if matchesAny(patterns: claudeBusyPatterns, in: lastLines) || containsSpinner(in: lastFewLines) {
                return AgentParsedStatus(rawStatus: .running, shouldTrustActivity: true)
            }
            return AgentParsedStatus(rawStatus: .idle, shouldTrustActivity: true)

        case .codex, .gemini:
            if matchesAny(patterns: genericWaitingPatterns, in: lastLines) {
                return AgentParsedStatus(rawStatus: .waiting, shouldTrustActivity: false)
            }
            if matchesAny(patterns: genericErrorPatterns, in: lastLines) {
                return AgentParsedStatus(rawStatus: .error, shouldTrustActivity: false)
            }
            if containsSpinner(in: lastFewLines) {
                return AgentParsedStatus(rawStatus: .running, shouldTrustActivity: true)
            }
            return AgentParsedStatus(rawStatus: .idle, shouldTrustActivity: true)
        }
    }

    private static func containsSpinner(in text: String) -> Bool {
        spinnerCharacters.contains { text.contains($0) }
    }

    private static func matchesAny(patterns: [String], in text: String) -> Bool {
        patterns.contains { pattern in
            text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }
}

enum AgentTaskCycleState: Equatable {
    case bootstrapping
    case warmingUp
    case ready
    case activeTask
}

struct AgentTaskWorkflowOutcome: Equatable {
    enum Action: Equatable {
        case moveToTodo
        case complete
    }

    let action: Action?

    static let none = AgentTaskWorkflowOutcome(action: nil)
}

enum AgentCaptureFailureHeuristics {
    static let stopThreshold = 3

    static func rawStatus(
        afterConsecutiveFailures consecutiveFailures: Int,
        isRecentActivity: Bool
    ) -> AgentRawStatus {
        if consecutiveFailures >= stopThreshold {
            return .stopped
        }
        return isRecentActivity ? .running : .idle
    }
}

struct AgentTaskWorkflowReducer {
    private(set) var cycleStateByCardID: [UUID: AgentTaskCycleState] = [:]
    private(set) var lastRawStatusByCardID: [UUID: AgentRawStatus] = [:]

    mutating func registerLaunch(for cardID: UUID) {
        cycleStateByCardID[cardID] = .bootstrapping
        lastRawStatusByCardID.removeValue(forKey: cardID)
    }

    mutating func removeCard(_ cardID: UUID) {
        cycleStateByCardID.removeValue(forKey: cardID)
        lastRawStatusByCardID.removeValue(forKey: cardID)
    }

    mutating func prune(to cardIDs: Set<UUID>) {
        let staleCardIDs = cycleStateByCardID.keys.filter { !cardIDs.contains($0) }
        for cardID in staleCardIDs {
            removeCard(cardID)
        }
    }

    func cycleState(for cardID: UUID) -> AgentTaskCycleState {
        cycleStateByCardID[cardID] ?? .bootstrapping
    }

    func lastRawStatus(for cardID: UUID) -> AgentRawStatus? {
        lastRawStatusByCardID[cardID]
    }

    mutating func registerTaskSubmission(
        snapshot: AgentSessionSnapshot
    ) -> AgentTaskWorkflowOutcome {
        let cardID = snapshot.cardID
        let currentState = cycleState(for: cardID)

        guard snapshot.column != .done else {
            return .none
        }

        switch currentState {
        case .activeTask:
            return .none

        case .bootstrapping, .warmingUp, .ready:
            cycleStateByCardID[cardID] = .activeTask
            if snapshot.column == .inProgress {
                return AgentTaskWorkflowOutcome(action: .moveToTodo)
            }
            return .none
        }
    }

    mutating func apply(
        snapshot: AgentSessionSnapshot,
        rawStatus: AgentRawStatus
    ) -> AgentTaskWorkflowOutcome {
        let cardID = snapshot.cardID
        let currentState = cycleState(for: cardID)
        var nextState = currentState
        var outcome = AgentTaskWorkflowOutcome.none

        switch currentState {
        case .bootstrapping:
            if rawStatus.establishesReadyBaseline || rawStatus == .stopped {
                nextState = .warmingUp
            }

        case .warmingUp:
            switch rawStatus {
            case .idle, .stopped:
                nextState = .ready
            case .running, .waiting, .error:
                nextState = .warmingUp
            }

        case .ready:
            break

        case .activeTask:
            guard snapshot.column != .done else {
                if rawStatus == .idle || rawStatus == .stopped {
                    nextState = .ready
                }
                break
            }

            switch rawStatus {
            case .idle:
                nextState = .ready
                if snapshot.column == .todo {
                    outcome = AgentTaskWorkflowOutcome(action: .complete)
                }
            case .stopped:
                nextState = .ready
            case .running, .waiting, .error:
                nextState = .activeTask
            }
        }

        cycleStateByCardID[cardID] = nextState
        lastRawStatusByCardID[cardID] = rawStatus
        return outcome
    }
}

@MainActor
final class AgentSessionMonitor {
    weak var boardStore: BoardStore?
    weak var terminalManager: TerminalManager?

    private var pollingTask: Task<Void, Never>?
    private var reducer = AgentTaskWorkflowReducer()
    private var lastActivityBySessionName: [String: Int] = [:]
    private var consecutiveCaptureFailuresBySessionName: [String: Int] = [:]

    func connect(boardStore: BoardStore, terminalManager: TerminalManager) {
        self.boardStore = boardStore
        self.terminalManager = terminalManager
    }

    func start() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func registerLaunch(for cardID: UUID) {
        reducer.registerLaunch(for: cardID)
    }

    func registerTaskSubmission(for cardID: UUID) {
        guard let terminalManager,
              let boardStore,
              let snapshot = terminalManager.agentSessionSnapshot(for: cardID) else {
            return
        }

        let outcome = reducer.registerTaskSubmission(snapshot: snapshot)
        handle(outcome: outcome, snapshot: snapshot, boardStore: boardStore)
    }

    func removeCard(_ cardID: UUID) {
        reducer.removeCard(cardID)
    }

    private func pollOnce() async {
        guard let terminalManager, let boardStore else { return }

        let snapshots = terminalManager.allAgentSessionSnapshots()
        let trackedCardIDs = Set(snapshots.map(\.cardID))
        reducer.prune(to: trackedCardIDs)

        let activityBySessionName = await TmuxSessionManager.shared.refreshSessionActivityCache()

        for snapshot in snapshots {
            let sessionName = snapshot.tmuxSessionName
            let currentActivity = activityBySessionName[sessionName]
            let previousActivity = lastActivityBySessionName[sessionName]

            let rawStatus: AgentRawStatus
            if let currentActivity {
                let shouldCapture =
                    previousActivity != currentActivity ||
                    reducer.cycleState(for: snapshot.cardID) != .ready ||
                    reducer.lastRawStatus(for: snapshot.cardID) == nil

                if shouldCapture {
                    rawStatus = await captureAndParseStatus(
                        snapshot: snapshot,
                        activityTimestamp: currentActivity
                    )
                } else if let cachedStatus = reducer.lastRawStatus(for: snapshot.cardID) {
                    rawStatus = cachedStatus
                } else {
                    rawStatus = TmuxSessionManager.shared.isRecentActivity(currentActivity) ? .running : .idle
                }

                lastActivityBySessionName[sessionName] = currentActivity
            } else {
                rawStatus = .stopped
                lastActivityBySessionName.removeValue(forKey: sessionName)
                consecutiveCaptureFailuresBySessionName.removeValue(forKey: sessionName)
            }

            let outcome = reducer.apply(snapshot: snapshot, rawStatus: rawStatus)
            handle(outcome: outcome, snapshot: snapshot, boardStore: boardStore)
        }

        let activeSessionNames = Set(snapshots.map(\.tmuxSessionName))
        lastActivityBySessionName = lastActivityBySessionName.filter { activeSessionNames.contains($0.key) }
        consecutiveCaptureFailuresBySessionName = consecutiveCaptureFailuresBySessionName.filter {
            activeSessionNames.contains($0.key)
        }
    }

    private func captureAndParseStatus(
        snapshot: AgentSessionSnapshot,
        activityTimestamp: Int
    ) async -> AgentRawStatus {
        let sessionName = snapshot.tmuxSessionName
        do {
            let output = try await TmuxSessionManager.shared.capturePane(sessionID: snapshot.tmuxSessionID)
            consecutiveCaptureFailuresBySessionName[sessionName] = 0
            return AgentStatusParser.parse(
                output: output,
                agent: snapshot.agent,
                isRecentActivity: TmuxSessionManager.shared.isRecentActivity(activityTimestamp)
            )
        } catch {
            let nextFailureCount = (consecutiveCaptureFailuresBySessionName[sessionName] ?? 0) + 1
            consecutiveCaptureFailuresBySessionName[sessionName] = nextFailureCount
            return AgentCaptureFailureHeuristics.rawStatus(
                afterConsecutiveFailures: nextFailureCount,
                isRecentActivity: TmuxSessionManager.shared.isRecentActivity(activityTimestamp)
            )
        }
    }

    private func handle(
        outcome: AgentTaskWorkflowOutcome,
        snapshot: AgentSessionSnapshot,
        boardStore: BoardStore
    ) {
        switch outcome.action {
        case .none:
            return

        case .moveToTodo:
            boardStore.moveCard(snapshot.cardID, to: .todo, in: snapshot.boardID)

        case .complete:
            boardStore.moveCard(snapshot.cardID, to: .inProgress, in: snapshot.boardID)
            NotificationService.shared.showNotification(
                title: snapshot.cardTitle,
                body: "Task completed",
                cardID: snapshot.cardID,
                boardID: snapshot.boardID
            )
        }
    }
}
