import Foundation
import Testing
@testable import zenban

@MainActor
struct ZellijSessionManagerTests {
    private enum WaitError: Error {
        case timedOut
    }

    private actor PreparationProbe {
        private(set) var started = false
        private(set) var cancelled = false

        func markStarted() {
            started = true
        }

        func markCancelled() {
            cancelled = true
        }
    }

    private actor SessionCleanupProbe {
        private(set) var cleanedSessionNames: [String] = []

        func record(_ sessionNames: Set<String>) {
            cleanedSessionNames = sessionNames.sorted()
        }
    }

    @Test
    func killRuntimeCancelsInFlightPreparationAndClearsLaunchRequest() async throws {
        let manager = ZellijSessionManager.shared
        manager.resetTestingHooks()
        manager.killAllSessions()
        defer {
            manager.resetTestingHooks()
            manager.killAllSessions()
        }

        let workspaceID = UUID()
        let registration = try manager.registerWorkspace(
            workspaceId: workspaceID,
            panelId: UUID(),
            portOrdinal: 0,
            workingDirectory: "/tmp/runtime-cancel"
        )
        try manager.queueLaunchRequest(
            for: workspaceID,
            token: "runtime-timeout-token",
            command: "codex"
        )

        let launchFilePath = try #require(registration.startupEnvironment["CMUX_ZELLIJ_LAUNCH_FILE"])
        let probe = PreparationProbe()
        manager.configureBackgroundSessionHookForTesting { _ in
            await probe.markStarted()
            do {
                try await Task.sleep(for: .seconds(60))
            } catch is CancellationError {
                await probe.markCancelled()
                throw CancellationError()
            }
        }
        manager.configureDeleteSessionHookForTesting { _ in }

        let task = Task {
            try await manager.prepareBackgroundSession(workspaceId: workspaceID)
        }

        try await waitUntil { await probe.started }
        #expect(manager.hasBackgroundCreationTaskForTesting(workspaceId: workspaceID))

        manager.killRuntime(for: workspaceID)

        try await waitUntil {
            await probe.cancelled &&
            !FileManager.default.fileExists(atPath: launchFilePath) &&
            !manager.hasBackgroundCreationTaskForTesting(workspaceId: workspaceID)
        }

        #expect(FileManager.default.fileExists(atPath: registration.attachCommand))
        #expect(manager.isManagedWorkspace(workspaceID))
        _ = await task.result
    }

    @Test
    func killSessionRemovesArtifactsAndRegistration() async throws {
        let manager = ZellijSessionManager.shared
        manager.resetTestingHooks()
        manager.killAllSessions()
        defer {
            manager.resetTestingHooks()
            manager.killAllSessions()
        }

        let workspaceID = UUID()
        let registration = try manager.registerWorkspace(
            workspaceId: workspaceID,
            panelId: UUID(),
            portOrdinal: 1,
            workingDirectory: "/tmp/kill-session"
        )
        try manager.queueLaunchRequest(
            for: workspaceID,
            token: "kill-session-token",
            command: "gemini"
        )

        let launchFilePath = try #require(registration.startupEnvironment["CMUX_ZELLIJ_LAUNCH_FILE"])
        manager.configureDeleteSessionHookForTesting { _ in }

        #expect(FileManager.default.fileExists(atPath: launchFilePath))
        #expect(FileManager.default.fileExists(atPath: registration.attachCommand))

        manager.killSession(for: workspaceID)

        try await waitUntil {
            !manager.isManagedWorkspace(workspaceID) &&
            !FileManager.default.fileExists(atPath: launchFilePath) &&
            !FileManager.default.fileExists(atPath: registration.attachCommand)
        }

        #expect((try? manager.startupEnvironment(for: workspaceID)) == nil)
        #expect((try? manager.attachCommand(for: workspaceID)) == nil)
    }

    @Test
    func registerPanelSessionTracksPanelSpecificArtifacts() throws {
        let manager = ZellijSessionManager.shared
        manager.resetTestingHooks()
        manager.killAllSessions()
        defer {
            manager.resetTestingHooks()
            manager.killAllSessions()
        }

        let workspaceID = UUID()
        let rootRegistration = try manager.registerWorkspace(
            workspaceId: workspaceID,
            panelId: UUID(),
            portOrdinal: 5,
            workingDirectory: "/tmp/panel-session-root"
        )
        let panelID = UUID()
        let panelRegistration = try manager.registerPanelSession(
            workspaceId: workspaceID,
            panelId: panelID,
            portOrdinal: 5,
            workingDirectory: "/tmp/panel-session-extra"
        )

        #expect(manager.hasManagedPanelSession(panelID))
        #expect(panelRegistration.attachCommand != rootRegistration.attachCommand)
        #expect(try manager.attachCommand(forPanelId: panelID) == panelRegistration.attachCommand)
        #expect(try manager.startupEnvironment(forPanelId: panelID) == panelRegistration.startupEnvironment)
    }

    @Test
    func killWorkspaceSessionRemovesAssociatedPanelSessions() async throws {
        let manager = ZellijSessionManager.shared
        manager.resetTestingHooks()
        manager.killAllSessions()
        defer {
            manager.resetTestingHooks()
            manager.killAllSessions()
        }

        let workspaceID = UUID()
        _ = try manager.registerWorkspace(
            workspaceId: workspaceID,
            panelId: UUID(),
            portOrdinal: 6,
            workingDirectory: "/tmp/panel-session-cleanup"
        )
        let panelID = UUID()
        let panelRegistration = try manager.registerPanelSession(
            workspaceId: workspaceID,
            panelId: panelID,
            portOrdinal: 6,
            workingDirectory: "/tmp/panel-session-cleanup-extra"
        )
        manager.configureDeleteSessionHookForTesting { _ in }

        manager.killSession(for: workspaceID)

        try await waitUntil {
            !manager.isManagedWorkspace(workspaceID) &&
            !manager.hasManagedPanelSession(panelID) &&
            !FileManager.default.fileExists(atPath: panelRegistration.attachCommand)
        }

        #expect((try? manager.attachCommand(forPanelId: panelID)) == nil)
        #expect((try? manager.startupEnvironment(forPanelId: panelID)) == nil)
    }

    @Test
    func killAllSessionsCancelsInFlightPreparationAndRemovesArtifacts() async throws {
        let manager = ZellijSessionManager.shared
        manager.resetTestingHooks()
        manager.killAllSessions()
        defer {
            manager.resetTestingHooks()
            manager.killAllSessions()
        }

        let workspaceID = UUID()
        let registration = try manager.registerWorkspace(
            workspaceId: workspaceID,
            panelId: UUID(),
            portOrdinal: 2,
            workingDirectory: "/tmp/kill-all"
        )
        try manager.queueLaunchRequest(
            for: workspaceID,
            token: "kill-all-token",
            command: "codex"
        )

        let launchFilePath = try #require(registration.startupEnvironment["CMUX_ZELLIJ_LAUNCH_FILE"])
        let probe = PreparationProbe()
        manager.configureBackgroundSessionHookForTesting { _ in
            await probe.markStarted()
            do {
                try await Task.sleep(for: .seconds(60))
            } catch is CancellationError {
                await probe.markCancelled()
                throw CancellationError()
            }
        }
        manager.configureCleanupSessionsHookForTesting { _ in }

        let task = Task {
            try await manager.prepareBackgroundSession(workspaceId: workspaceID)
        }

        try await waitUntil { await probe.started }
        #expect(manager.hasBackgroundCreationTaskForTesting(workspaceId: workspaceID))

        manager.killAllSessions()

        try await waitUntil {
            await probe.cancelled &&
            !manager.isManagedWorkspace(workspaceID) &&
            !FileManager.default.fileExists(atPath: launchFilePath) &&
            !FileManager.default.fileExists(atPath: registration.attachCommand) &&
            !manager.hasBackgroundCreationTaskForTesting(workspaceId: workspaceID)
        }

        #expect((try? manager.startupEnvironment(for: workspaceID)) == nil)
        #expect((try? manager.attachCommand(for: workspaceID)) == nil)
        _ = await task.result
    }

    @Test
    func shutdownAllSessionsForAppTerminationCancelsPreparationAndRemovesArtifacts() async throws {
        let manager = ZellijSessionManager.shared
        manager.resetTestingHooks()
        manager.killAllSessions()
        defer {
            manager.resetTestingHooks()
            manager.killAllSessions()
        }

        let workspaceID = UUID()
        let registration = try manager.registerWorkspace(
            workspaceId: workspaceID,
            panelId: UUID(),
            portOrdinal: 3,
            workingDirectory: "/tmp/shutdown-termination"
        )
        try manager.queueLaunchRequest(
            for: workspaceID,
            token: "termination-cleanup-token",
            command: "codex"
        )

        let launchFilePath = try #require(registration.startupEnvironment["CMUX_ZELLIJ_LAUNCH_FILE"])
        let preparationProbe = PreparationProbe()
        let cleanupProbe = SessionCleanupProbe()
        manager.configureBackgroundSessionHookForTesting { _ in
            await preparationProbe.markStarted()
            do {
                try await Task.sleep(for: .seconds(60))
            } catch is CancellationError {
                await preparationProbe.markCancelled()
                throw CancellationError()
            }
        }
        manager.configureSessionNamesHookForTesting { [] }
        manager.configureCleanupSessionsHookForTesting { sessionNames in
            await cleanupProbe.record(sessionNames)
        }

        let task = Task {
            try await manager.prepareBackgroundSession(workspaceId: workspaceID)
        }

        try await waitUntil { await preparationProbe.started }
        #expect(manager.hasBackgroundCreationTaskForTesting(workspaceId: workspaceID))

        let shutdownResult = await manager.shutdownAllSessionsForAppTermination(timeout: 0.1)

        #expect(shutdownResult.completedBeforeTimeout)
        #expect(shutdownResult.remainingSessionNames.isEmpty)
        #expect(await cleanupProbe.cleanedSessionNames == ["zenban-ws-\(workspaceID.uuidString.lowercased())"])
        #expect(await preparationProbe.cancelled)
        #expect(!manager.isManagedWorkspace(workspaceID))
        #expect(!FileManager.default.fileExists(atPath: launchFilePath))
        #expect(!FileManager.default.fileExists(atPath: registration.attachCommand))
        #expect(!manager.hasBackgroundCreationTaskForTesting(workspaceId: workspaceID))
        _ = await task.result
    }

    @Test
    func shutdownAllSessionsForAppTerminationTimesOutButStillClearsLocalState() async throws {
        let manager = ZellijSessionManager.shared
        manager.resetTestingHooks()
        manager.killAllSessions()
        defer {
            manager.resetTestingHooks()
            manager.killAllSessions()
        }

        let workspaceID = UUID()
        let registration = try manager.registerWorkspace(
            workspaceId: workspaceID,
            panelId: UUID(),
            portOrdinal: 4,
            workingDirectory: "/tmp/shutdown-timeout"
        )
        try manager.queueLaunchRequest(
            for: workspaceID,
            token: "termination-timeout-token",
            command: "gemini"
        )

        let launchFilePath = try #require(registration.startupEnvironment["CMUX_ZELLIJ_LAUNCH_FILE"])
        manager.configureSessionNamesHookForTesting { [] }
        manager.configureCleanupSessionsHookForTesting { _ in
            try await Task.sleep(for: .seconds(60))
        }

        let shutdownResult = await manager.shutdownAllSessionsForAppTermination(timeout: 0.01)

        #expect(!shutdownResult.completedBeforeTimeout)
        #expect(shutdownResult.remainingSessionNames == ["zenban-ws-\(workspaceID.uuidString.lowercased())"])
        #expect(!manager.isManagedWorkspace(workspaceID))
        #expect(!FileManager.default.fileExists(atPath: launchFilePath))
        #expect(!FileManager.default.fileExists(atPath: registration.attachCommand))
        #expect((try? manager.startupEnvironment(for: workspaceID)) == nil)
        #expect((try? manager.attachCommand(for: workspaceID)) == nil)
    }

    private func waitUntil(
        timeout: Duration = .seconds(3),
        condition: @escaping @MainActor () async -> Bool
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
}
