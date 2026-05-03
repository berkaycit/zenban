import Foundation
import Testing
@testable import zenban

@Suite(.serialized)
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
        let workspaceRegistration = try manager.registerWorkspace(
            workspaceId: workspaceID,
            panelId: UUID(),
            portOrdinal: 6,
            workingDirectory: "/tmp/panel-session-cleanup"
        )
        let firstPanelID = UUID()
        let firstPanelRegistration = try manager.registerPanelSession(
            workspaceId: workspaceID,
            panelId: firstPanelID,
            portOrdinal: 6,
            workingDirectory: "/tmp/panel-session-cleanup-extra"
        )
        let secondPanelID = UUID()
        let secondPanelRegistration = try manager.registerPanelSession(
            workspaceId: workspaceID,
            panelId: secondPanelID,
            portOrdinal: 6,
            workingDirectory: "/tmp/panel-session-cleanup-second"
        )
        manager.configureDeleteSessionHookForTesting { _ in }

        manager.killSession(for: workspaceID)

        try await waitUntil {
            !manager.isManagedWorkspace(workspaceID) &&
            !manager.hasManagedPanelSession(firstPanelID) &&
            !manager.hasManagedPanelSession(secondPanelID) &&
            !FileManager.default.fileExists(atPath: workspaceRegistration.attachCommand) &&
            !FileManager.default.fileExists(atPath: firstPanelRegistration.attachCommand) &&
            !FileManager.default.fileExists(atPath: secondPanelRegistration.attachCommand)
        }

        #expect((try? manager.attachCommand(forPanelId: firstPanelID)) == nil)
        #expect((try? manager.startupEnvironment(forPanelId: firstPanelID)) == nil)
        #expect((try? manager.attachCommand(forPanelId: secondPanelID)) == nil)
        #expect((try? manager.startupEnvironment(forPanelId: secondPanelID)) == nil)
    }

    @Test
    func forgetWorkspaceRemovesAssociatedPanelSessionsAndArtifacts() async throws {
        let manager = ZellijSessionManager.shared
        manager.resetTestingHooks()
        manager.killAllSessions()
        defer {
            manager.resetTestingHooks()
            manager.killAllSessions()
        }

        let workspaceID = UUID()
        let workspaceRegistration = try manager.registerWorkspace(
            workspaceId: workspaceID,
            panelId: UUID(),
            portOrdinal: 7,
            workingDirectory: "/tmp/forget-workspace"
        )
        let panelID = UUID()
        let panelRegistration = try manager.registerPanelSession(
            workspaceId: workspaceID,
            panelId: panelID,
            portOrdinal: 7,
            workingDirectory: "/tmp/forget-workspace-panel"
        )
        try manager.queueLaunchRequest(
            for: workspaceID,
            token: "forget-workspace-root",
            command: "codex"
        )
        try manager.queueLaunchRequest(
            forPanelId: panelID,
            token: "forget-workspace-panel",
            command: "codex"
        )
        manager.configureDeleteSessionHookForTesting { _ in }

        let workspaceLaunchFilePath = try #require(
            workspaceRegistration.startupEnvironment["CMUX_ZELLIJ_LAUNCH_FILE"]
        )
        let panelLaunchFilePath = try #require(
            panelRegistration.startupEnvironment["CMUX_ZELLIJ_LAUNCH_FILE"]
        )

        manager.forgetWorkspace(workspaceID)

        try await waitUntil {
            !manager.isManagedWorkspace(workspaceID) &&
            !manager.hasManagedPanelSession(panelID) &&
            !FileManager.default.fileExists(atPath: workspaceLaunchFilePath) &&
            !FileManager.default.fileExists(atPath: panelLaunchFilePath) &&
            !FileManager.default.fileExists(atPath: workspaceRegistration.attachCommand) &&
            !FileManager.default.fileExists(atPath: panelRegistration.attachCommand)
        }

        #expect((try? manager.attachCommand(for: workspaceID)) == nil)
        #expect((try? manager.startupEnvironment(for: workspaceID)) == nil)
        #expect((try? manager.attachCommand(forPanelId: panelID)) == nil)
        #expect((try? manager.startupEnvironment(forPanelId: panelID)) == nil)
    }

    @Test
    func registerPanelSessionIsStableAcrossRepeatedAttachments() throws {
        let manager = ZellijSessionManager.shared
        manager.resetTestingHooks()
        manager.killAllSessions()
        defer {
            manager.resetTestingHooks()
            manager.killAllSessions()
        }

        let workspaceID = UUID()
        let panelID = UUID()
        let initialRegistration = try manager.registerPanelSession(
            workspaceId: workspaceID,
            panelId: panelID,
            portOrdinal: 8,
            workingDirectory: "/tmp/reattach-stability"
        )

        #expect(initialRegistration.didChangeStartup)
        let attachCommand = initialRegistration.attachCommand
        let startupEnvironment = initialRegistration.startupEnvironment
        try FileManager.default.removeItem(atPath: attachCommand)
        #expect(!FileManager.default.fileExists(atPath: attachCommand))

        let reattachedCommand = try manager.attachCommand(forPanelId: panelID)
        #expect(reattachedCommand == attachCommand)
        #expect(FileManager.default.fileExists(atPath: attachCommand))
        #expect(try manager.startupEnvironment(forPanelId: panelID) == startupEnvironment)

        let secondRegistration = try manager.registerPanelSession(
            workspaceId: workspaceID,
            panelId: panelID,
            portOrdinal: 8,
            workingDirectory: "/tmp/reattach-stability"
        )

        #expect(secondRegistration.attachCommand == attachCommand)
        #expect(secondRegistration.startupEnvironment == startupEnvironment)
        #expect(!secondRegistration.didChangeStartup)
        #expect(manager.hasManagedPanelSession(panelID))
    }

    @Test
    func killRuntimePreservesRegistrationsWhileClearingLaunchRequests() async throws {
        let manager = ZellijSessionManager.shared
        manager.resetTestingHooks()
        manager.killAllSessions()
        defer {
            manager.resetTestingHooks()
            manager.killAllSessions()
        }

        let workspaceID = UUID()
        let workspaceRegistration = try manager.registerWorkspace(
            workspaceId: workspaceID,
            panelId: UUID(),
            portOrdinal: 9,
            workingDirectory: "/tmp/runtime-reclaim"
        )
        let panelID = UUID()
        let panelRegistration = try manager.registerPanelSession(
            workspaceId: workspaceID,
            panelId: panelID,
            portOrdinal: 9,
            workingDirectory: "/tmp/runtime-reclaim-panel"
        )
        try manager.queueLaunchRequest(
            for: workspaceID,
            token: "runtime-reclaim-workspace",
            command: "codex"
        )
        try manager.queueLaunchRequest(
            forPanelId: panelID,
            token: "runtime-reclaim-panel",
            command: "gemini"
        )

        let workspaceLaunchFilePath = try #require(workspaceRegistration.startupEnvironment["CMUX_ZELLIJ_LAUNCH_FILE"])
        let panelLaunchFilePath = try #require(panelRegistration.startupEnvironment["CMUX_ZELLIJ_LAUNCH_FILE"])

        manager.killRuntime(for: workspaceID)

        try await waitUntil {
            manager.isManagedWorkspace(workspaceID) &&
            manager.hasManagedPanelSession(panelID) &&
            !FileManager.default.fileExists(atPath: workspaceLaunchFilePath) &&
            !FileManager.default.fileExists(atPath: panelLaunchFilePath)
        }

        #expect(try manager.startupEnvironment(for: workspaceID) == workspaceRegistration.startupEnvironment)
        #expect(try manager.startupEnvironment(forPanelId: panelID) == panelRegistration.startupEnvironment)
        #expect(FileManager.default.fileExists(atPath: workspaceRegistration.attachCommand))
        #expect(FileManager.default.fileExists(atPath: panelRegistration.attachCommand))
    }

    @Test
    func killPanelSessionOnlyRemovesThatPanelRegistration() async throws {
        let manager = ZellijSessionManager.shared
        manager.resetTestingHooks()
        manager.killAllSessions()
        defer {
            manager.resetTestingHooks()
            manager.killAllSessions()
        }

        let workspaceID = UUID()
        let workspaceRegistration = try manager.registerWorkspace(
            workspaceId: workspaceID,
            panelId: UUID(),
            portOrdinal: 10,
            workingDirectory: "/tmp/panel-cleanup-isolated"
        )
        let survivingPanelID = UUID()
        let survivingPanelRegistration = try manager.registerPanelSession(
            workspaceId: workspaceID,
            panelId: survivingPanelID,
            portOrdinal: 10,
            workingDirectory: "/tmp/panel-cleanup-isolated-survivor"
        )
        let panelID = UUID()
        let panelRegistration = try manager.registerPanelSession(
            workspaceId: workspaceID,
            panelId: panelID,
            portOrdinal: 10,
            workingDirectory: "/tmp/panel-cleanup-isolated-target"
        )

        manager.killPanelSession(for: panelID)

        try await waitUntil {
            manager.isManagedWorkspace(workspaceID) &&
            manager.hasManagedPanelSession(survivingPanelID) &&
            !manager.hasManagedPanelSession(panelID) &&
            FileManager.default.fileExists(atPath: workspaceRegistration.attachCommand) &&
            FileManager.default.fileExists(atPath: survivingPanelRegistration.attachCommand) &&
            !FileManager.default.fileExists(atPath: panelRegistration.attachCommand)
        }

        #expect(try manager.startupEnvironment(for: workspaceID) == workspaceRegistration.startupEnvironment)
        #expect(try manager.startupEnvironment(forPanelId: survivingPanelID) == survivingPanelRegistration.startupEnvironment)
        #expect((try? manager.startupEnvironment(forPanelId: panelID)) == nil)
        #expect((try? manager.attachCommand(forPanelId: panelID)) == nil)
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
