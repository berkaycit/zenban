import Foundation

#if DEBUG
private let agentLifecycleDebugLogURL = URL(fileURLWithPath: "/tmp/zenban-agent-lifecycle.log")
private let agentLifecycleDebugLogLock = NSLock()
private let agentLifecycleDebugTimestampFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

func agentLifecycleDebugLog(_ message: @autoclosure () -> String) {
    let line = "\(agentLifecycleDebugTimestampFormatter.string(from: Date())) [app] \(message())\n"
    guard let data = line.data(using: .utf8) else { return }
    agentLifecycleDebugLogLock.lock()
    defer { agentLifecycleDebugLogLock.unlock() }

    let url = agentLifecycleDebugLogURL
    let fileManager = FileManager.default
    if !fileManager.fileExists(atPath: url.path) {
        fileManager.createFile(atPath: url.path, contents: nil)
    }
    guard let handle = try? FileHandle(forWritingTo: url) else { return }
    defer { try? handle.close() }
    do {
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    } catch {
        return
    }
}
#else
@inline(__always)
func agentLifecycleDebugLog(_ message: @autoclosure () -> String) {}
#endif

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
        panelID: UUID,
        workingDirectory: String?,
        reason: AgentLaunchReason
    ) -> AgentLaunchPlan {
        var environment: [String: String] = [
            "CMUX_PANEL_ID": panelID.uuidString,
            "CMUX_SOCKET_AUTH_TOKEN": TerminalController.shared.socketAuthToken(),
            "CMUX_SOCKET_PATH": SocketControlSettings.socketPath(),
            "CMUX_SURFACE_ID": panelID.uuidString,
            "CMUX_TAB_ID": cardID.uuidString,
            "CMUX_WORKSPACE_ID": cardID.uuidString,
            "ZENBAN_AGENT": agent.runtimeID,
            "ZENBAN_AGENT_BOARD_ID": boardID.uuidString,
            "ZENBAN_AGENT_CARD_ID": cardID.uuidString,
            "ZENBAN_AGENT_LAUNCH_REASON": reason.rawValue,
            "ZENBAN_TERMINAL": "1",
        ]
        if let bundleID = Bundle.main.bundleIdentifier,
           !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            environment["CMUX_BUNDLE_ID"] = bundleID
        }
        if !ClaudeCodeIntegrationSettings.hooksEnabled() {
            environment["CMUX_CLAUDE_HOOKS_DISABLED"] = "1"
        }

        return AgentLaunchPlan(
            agent: agent,
            command: baseCommand(for: agent),
            workingDirectory: workingDirectory,
            environment: environment,
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

extension Agent {
    static func fromRuntimeID(_ rawValue: String) -> Agent? {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allCases.first { $0.runtimeID == normalized }
    }
}

enum AgentRuntimeSignal: String {
    case started
    case completed

    init?(legacyClaudeHook rawValue: String) {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "prompt-submit":
            self = .started
        case "stop", "idle":
            self = .completed
        default:
            return nil
        }
    }

    static func shouldIgnoreLegacyClaudeHook(_ rawValue: String) -> Bool {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "session-start", "active", "notification", "notify":
            true
        default:
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
}

struct AgentTaskWorkflowOutcome: Equatable {
    enum Action: Equatable {
        case moveToTodo
        case complete
    }

    let action: Action?

    static let none = AgentTaskWorkflowOutcome(action: nil)
}

struct AgentTaskWorkflowReducer {
    private(set) var activeTaskCardIDs: Set<UUID> = []

    mutating func registerLaunch(for cardID: UUID) {
        activeTaskCardIDs.remove(cardID)
    }

    mutating func removeCard(_ cardID: UUID) {
        activeTaskCardIDs.remove(cardID)
    }

    mutating func prune(to cardIDs: Set<UUID>) {
        activeTaskCardIDs = activeTaskCardIDs.intersection(cardIDs)
    }

    func hasActiveTask(for cardID: UUID) -> Bool {
        activeTaskCardIDs.contains(cardID)
    }

    mutating func apply(
        signal: AgentRuntimeSignal,
        snapshot: AgentSessionSnapshot
    ) -> AgentTaskWorkflowOutcome {
        switch signal {
        case .started:
            guard snapshot.column != .done else {
                activeTaskCardIDs.remove(snapshot.cardID)
                return .none
            }
            let inserted = activeTaskCardIDs.insert(snapshot.cardID).inserted
            guard inserted else { return .none }
            if snapshot.column == .inProgress {
                return AgentTaskWorkflowOutcome(action: .moveToTodo)
            }
            return .none

        case .completed:
            let wasActive = activeTaskCardIDs.remove(snapshot.cardID) != nil
            guard wasActive, snapshot.column != .done else {
                return .none
            }
            return AgentTaskWorkflowOutcome(action: .complete)
        }
    }
}

@MainActor
final class AgentSessionMonitor {
    weak var boardStore: BoardStore?
    weak var terminalManager: TerminalManager?

    private var reducer = AgentTaskWorkflowReducer()

    func connect(boardStore: BoardStore, terminalManager: TerminalManager) {
        self.boardStore = boardStore
        self.terminalManager = terminalManager
    }

    func registerLaunch(for cardID: UUID) {
        synchronizeTrackedCards()
        reducer.registerLaunch(for: cardID)
        agentLifecycleDebugLog(
            "runtime.launch card=\(cardID.uuidString) activeCount=\(reducer.activeTaskCardIDs.count)"
        )
    }

    func registerRuntimeSignal(_ signal: AgentRuntimeSignal, for cardID: UUID) {
        synchronizeTrackedCards()

        guard let terminalManager,
              let boardStore,
              let snapshot = terminalManager.agentSessionSnapshot(for: cardID) else {
            agentLifecycleDebugLog(
                "runtime.signal.missingSnapshot signal=\(signal.rawValue) card=\(cardID.uuidString)"
            )
            return
        }

        let outcome = reducer.apply(signal: signal, snapshot: snapshot)
        agentLifecycleDebugLog(
            "runtime.signal signal=\(signal.rawValue) card=\(snapshot.cardID.uuidString) " +
            "board=\(snapshot.boardID.uuidString) agent=\(snapshot.agent.runtimeID) " +
            "column=\(snapshot.column.rawValue) outcome=\(String(describing: outcome.action)) " +
            "active=\(reducer.hasActiveTask(for: snapshot.cardID) ? 1 : 0)"
        )
        handle(outcome: outcome, snapshot: snapshot, boardStore: boardStore)
    }

    func removeCard(_ cardID: UUID) {
        reducer.removeCard(cardID)
    }

    private func synchronizeTrackedCards() {
        guard let terminalManager else { return }
        let trackedCardIDs = Set(terminalManager.allAgentSessionSnapshots().map(\.cardID))
        reducer.prune(to: trackedCardIDs)
    }

    private func handle(
        outcome: AgentTaskWorkflowOutcome,
        snapshot: AgentSessionSnapshot,
        boardStore: BoardStore
    ) {
        switch outcome.action {
        case .none:
            agentLifecycleDebugLog(
                "runtime.handle.none card=\(snapshot.cardID.uuidString) agent=\(snapshot.agent.runtimeID)"
            )
            return

        case .moveToTodo:
            agentLifecycleDebugLog(
                "runtime.handle.moveToTodo card=\(snapshot.cardID.uuidString) board=\(snapshot.boardID.uuidString)"
            )
            boardStore.moveCard(snapshot.cardID, to: .todo, in: snapshot.boardID)

        case .complete:
            let didMoveToInReview = boardStore.moveCard(
                snapshot.cardID,
                to: .inProgress,
                in: snapshot.boardID
            )
            agentLifecycleDebugLog(
                "runtime.handle.complete card=\(snapshot.cardID.uuidString) board=\(snapshot.boardID.uuidString) " +
                "didMoveToInReview=\(didMoveToInReview ? 1 : 0)"
            )
            guard didMoveToInReview else { return }
            NotificationService.shared.showNotification(
                title: snapshot.cardTitle,
                body: "Task completed",
                cardID: snapshot.cardID,
                boardID: snapshot.boardID
            )
        }
    }
}
