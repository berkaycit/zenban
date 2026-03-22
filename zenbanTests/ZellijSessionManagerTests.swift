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
