import Foundation

@MainActor
final class ZellijSessionManager {
    private static let sessionPrefix = "zenban-ws-"

    struct ShutdownResult: Equatable, Sendable {
        let completedBeforeTimeout: Bool
        let remainingSessionNames: [String]

        static let completed = ShutdownResult(
            completedBeforeTimeout: true,
            remainingSessionNames: []
        )
    }

    struct SessionSpec: Sendable {
        let workspaceId: UUID
        let panelId: UUID
        let portOrdinal: Int
        let workingDirectory: String?
        let sessionName: String
    }

    struct RegistrationResult {
        let attachCommand: String
        let startupEnvironment: [String: String]
        let didChangeStartup: Bool
    }

    enum SessionLookupError: Error, LocalizedError {
        case missingPanelSession

        var errorDescription: String? {
            switch self {
            case .missingPanelSession:
                return "Zellij panel session metadata is missing."
            }
        }
    }

    private struct TerminalSessionDescriptor: Equatable {
        let attachCommand: String
        let startupEnvironment: [String: String]
        let workingDirectory: String?
    }

    private enum SessionOwner: Hashable {
        case workspaceRoot(UUID)
        case panel(UUID)
    }

    private struct RegisteredSession {
        var spec: SessionSpec
        var descriptor: TerminalSessionDescriptor
    }

    private struct BackgroundCreationTaskRecord {
        let id: UUID
        let task: Task<Void, Error>
    }

    private enum ShutdownTimeoutError: Error {
        case timedOut
    }

    enum SessionError: Error, LocalizedError {
        case missingSessionSpec
        case missingBundledBinary
        case missingBundledConfig
        case missingBundledWrapper
        case processFailed(command: String, status: Int32, output: String)

        var errorDescription: String? {
            switch self {
            case .missingSessionSpec:
                return "Zellij session metadata is missing."
            case .missingBundledBinary:
                return "Bundled zellij binary is missing."
            case .missingBundledConfig:
                return "Bundled zellij config is missing."
            case .missingBundledWrapper:
                return "Bundled zellij shell wrapper is missing."
            case .processFailed(let command, let status, let output):
                return "Zellij command failed (\(status)): \(command)\n\(output)"
            }
        }
    }

    static let shared = ZellijSessionManager()

    private let fileManager = FileManager.default
    private let runner = ZellijProcessRunner()
    private var sessionByOwner: [SessionOwner: RegisteredSession] = [:]
    private var backgroundCreationTasks: [UUID: BackgroundCreationTaskRecord] = [:]
    private var startupCleanupTask: Task<Void, Never>?
    private var appTerminationShutdownTask: Task<ShutdownResult, Never>?
#if DEBUG
    private var prepareBackgroundSessionHookForTesting: (@Sendable (SessionSpec) async throws -> Void)?
    private var deleteSessionHookForTesting: (@Sendable (String) async throws -> Void)?
    private var cleanupSessionsHookForTesting: (@Sendable (Set<String>) async throws -> Void)?
    private var sessionNamesHookForTesting: (@Sendable () async throws -> [String])?
#endif

    private init() {
        startStartupCleanup()
    }

    func registerWorkspace(
        workspaceId: UUID,
        panelId: UUID,
        portOrdinal: Int,
        workingDirectory: String?
    ) throws -> RegistrationResult {
        let spec = SessionSpec(
            workspaceId: workspaceId,
            panelId: panelId,
            portOrdinal: portOrdinal,
            workingDirectory: normalizedDirectory(workingDirectory),
            sessionName: Self.sessionName(for: workspaceId)
        )
        return try registerSession(
            owner: .workspaceRoot(workspaceId),
            spec: spec,
            currentDescriptor: rootRegistration(for: workspaceId)?.descriptor
        )
    }

    func reassignWorkspacePanel(
        workspaceId: UUID,
        panelId: UUID,
        portOrdinal: Int
    ) throws -> RegistrationResult {
        guard var registration = rootRegistration(for: workspaceId) else {
            throw SessionError.missingSessionSpec
        }

        let currentDescriptor = registration.descriptor
        registration.spec = SessionSpec(
            workspaceId: registration.spec.workspaceId,
            panelId: panelId,
            portOrdinal: portOrdinal,
            workingDirectory: registration.spec.workingDirectory,
            sessionName: registration.spec.sessionName
        )
        sessionByOwner[.workspaceRoot(workspaceId)] = registration
        let result = try registerSession(
            owner: .workspaceRoot(workspaceId),
            spec: registration.spec,
            currentDescriptor: currentDescriptor
        )
        return result
    }

    func registerPanelSession(
        workspaceId: UUID,
        panelId: UUID,
        portOrdinal: Int,
        workingDirectory: String?
    ) throws -> RegistrationResult {
        let normalizedWorkingDirectory = normalizedDirectory(workingDirectory)
        let spec = SessionSpec(
            workspaceId: workspaceId,
            panelId: panelId,
            portOrdinal: portOrdinal,
            workingDirectory: normalizedWorkingDirectory,
            sessionName: Self.panelSessionName(for: panelId)
        )
        return try registerSession(
            owner: .panel(panelId),
            spec: spec,
            currentDescriptor: panelRegistration(for: panelId)?.descriptor
        )
    }

    func sessionPanelId(for workspaceId: UUID) -> UUID? {
        rootRegistration(for: workspaceId)?.spec.panelId
    }

    func isManagedWorkspace(_ workspaceId: UUID) -> Bool {
        rootRegistration(for: workspaceId) != nil
    }

    func hasManagedPanelSession(_ panelId: UUID) -> Bool {
        panelRegistration(for: panelId) != nil
    }

    func attachCommand(for workspaceId: UUID) throws -> String {
        guard let registration = rootRegistration(for: workspaceId) else {
            throw SessionError.missingSessionSpec
        }
        if !fileManager.fileExists(atPath: registration.descriptor.attachCommand) {
            try writeAttachScript(for: registration.spec, descriptor: registration.descriptor)
        }
        return registration.descriptor.attachCommand
    }

    func startupEnvironment(for workspaceId: UUID) throws -> [String: String] {
        guard let registration = rootRegistration(for: workspaceId) else {
            throw SessionError.missingSessionSpec
        }
        return registration.descriptor.startupEnvironment
    }

    func attachCommand(forPanelId panelId: UUID) throws -> String {
        guard let registration = panelRegistration(for: panelId) else {
            throw SessionLookupError.missingPanelSession
        }
        if !fileManager.fileExists(atPath: registration.descriptor.attachCommand) {
            try writeAttachScript(for: registration.spec, descriptor: registration.descriptor)
        }
        return registration.descriptor.attachCommand
    }

    func startupEnvironment(forPanelId panelId: UUID) throws -> [String: String] {
        guard let registration = panelRegistration(for: panelId) else {
            throw SessionLookupError.missingPanelSession
        }
        return registration.descriptor.startupEnvironment
    }

    func queueLaunchRequest(
        for workspaceId: UUID,
        token: String,
        command: String
    ) throws {
        guard let spec = rootRegistration(for: workspaceId)?.spec else {
            throw SessionError.missingSessionSpec
        }
        try writeLaunchRequest(token: token, command: command, for: spec)
    }

    func queueLaunchRequest(
        forPanelId panelId: UUID,
        token: String,
        command: String
    ) throws {
        guard let spec = panelRegistration(for: panelId)?.spec else {
            throw SessionLookupError.missingPanelSession
        }
        try writeLaunchRequest(token: token, command: command, for: spec)
    }

    func clearLaunchRequest(for workspaceId: UUID) {
        guard let spec = rootRegistration(for: workspaceId)?.spec else { return }
        try? removeLaunchRequestFile(for: spec)
    }

    func clearLaunchRequest(forPanelId panelId: UUID) {
        guard let spec = panelRegistration(for: panelId)?.spec else { return }
        try? removeLaunchRequestFile(for: spec)
    }

    func prepareBackgroundSession(
        workspaceId: UUID
    ) async throws {
        guard let spec = rootRegistration(for: workspaceId)?.spec else { return }
        await startupCleanupTask?.value
        if let task = backgroundCreationTasks[workspaceId]?.task {
            return try await task.value
        }

        let configuration = try runnerConfiguration()
        let environment = backgroundEnvironment(for: spec)
        let wrapperPath = try wrapperPath()
        let taskID = UUID()
        #if DEBUG
        let testingHook = prepareBackgroundSessionHookForTesting
        #endif
        let task = Task.detached(priority: nil) { [runner, configuration, environment, wrapperPath, spec] in
#if DEBUG
            if let testingHook {
                try await testingHook(spec)
                return
            }
#endif
            try await runner.prepareBackgroundSession(
                configuration: configuration,
                sessionName: spec.sessionName,
                environment: environment,
                wrapperPath: wrapperPath,
                workingDirectory: spec.workingDirectory
            )
        }
        backgroundCreationTasks[workspaceId] = BackgroundCreationTaskRecord(id: taskID, task: task)
        do {
            try await task.value
        } catch {
            if backgroundCreationTasks[workspaceId]?.id == taskID {
                backgroundCreationTasks.removeValue(forKey: workspaceId)
            }
            throw error
        }
        if backgroundCreationTasks[workspaceId]?.id == taskID {
            backgroundCreationTasks.removeValue(forKey: workspaceId)
        }
    }

    func killSession(for workspaceId: UUID) {
        cancelBackgroundCreationTask(for: workspaceId)
        cleanupAndScheduleDeletion(
            for: removeRegistrations(for: workspaceId),
            removeAttachScriptFiles: true
        )
    }

    func killRuntime(for workspaceId: UUID) {
        cancelBackgroundCreationTask(for: workspaceId)
        cleanupAndScheduleDeletion(
            for: sessionSpecs(for: workspaceId),
            removeAttachScriptFiles: false
        )
    }

    func killPanelSession(for panelId: UUID) {
        guard let registration = panelRegistration(for: panelId) else { return }
        removePanelRegistration(for: panelId)
        cleanupAndScheduleDeletion(
            for: [registration.spec],
            removeAttachScriptFiles: true
        )
    }

    func killAllSessions() {
        appTerminationShutdownTask?.cancel()
        appTerminationShutdownTask = nil
        let knownSessionNames = knownSessionNames()
        startupCleanupTask?.cancel()
        startupCleanupTask = nil
        for workspaceId in Array(backgroundCreationTasks.keys) {
            cancelBackgroundCreationTask(for: workspaceId)
        }
        for spec in sessionByOwner.values.map(\.spec) {
            cleanupWorkspaceArtifacts(for: spec, removeAttachScriptFile: true)
        }
        sessionByOwner.removeAll(keepingCapacity: false)
        Task { [runner] in
            do {
                let configuration = try self.runnerConfiguration()
#if DEBUG
                if let cleanupSessionsHookForTesting {
                    try await cleanupSessionsHookForTesting(knownSessionNames)
                    return
                }
#endif
                try await runner.cleanupStaleSessions(
                    configuration: configuration,
                    sessionPrefix: Self.sessionPrefix,
                    additionalSessionNames: knownSessionNames
                )
            } catch {
                NSLog("Failed to clean up zellij sessions: %@", String(describing: error))
            }
        }
    }

    func shutdownAllSessionsForAppTermination(timeout: TimeInterval) async -> ShutdownResult {
        if let task = appTerminationShutdownTask {
            return await task.value
        }

        let knownSessionNames = resetManagedSessionState(removeAttachScriptFiles: true)
        let configuration: ZellijProcessConfiguration?
        do {
            configuration = try runnerConfiguration()
        } catch {
            if !knownSessionNames.isEmpty {
                NSLog(
                    "Failed to build zellij shutdown configuration during app termination: %@",
                    String(describing: error)
                )
            }
            return ShutdownResult(
                completedBeforeTimeout: knownSessionNames.isEmpty,
                remainingSessionNames: knownSessionNames.sorted()
            )
        }

        let task = Task<ShutdownResult, Never> {
            guard let configuration else {
                return ShutdownResult(
                    completedBeforeTimeout: knownSessionNames.isEmpty,
                    remainingSessionNames: knownSessionNames.sorted()
                )
            }

            let snapshotSessionNames: Set<String>
            do {
                snapshotSessionNames = try await self.managedSessionNamesForTermination(
                    configuration: configuration,
                    knownSessionNames: knownSessionNames
                )
            } catch {
                NSLog(
                    "Failed to list zellij sessions during app termination: %@",
                    String(describing: error)
                )
                snapshotSessionNames = knownSessionNames
            }

            guard !snapshotSessionNames.isEmpty else {
                return .completed
            }

            let completedBeforeTimeout = await self.deleteSessionsForAppTermination(
                snapshotSessionNames,
                configuration: configuration,
                timeout: timeout
            )

            let remainingSessionNames: [String]
            do {
                let remaining = try await self.managedSessionNamesForTermination(
                    configuration: configuration,
                    knownSessionNames: completedBeforeTimeout ? [] : snapshotSessionNames
                )
                if !completedBeforeTimeout && remaining.isEmpty {
                    remainingSessionNames = snapshotSessionNames.sorted()
                } else {
                    remainingSessionNames = remaining.sorted()
                }
            } catch {
                NSLog(
                    "Failed to verify remaining zellij sessions during app termination: %@",
                    String(describing: error)
                )
                remainingSessionNames = completedBeforeTimeout ? [] : snapshotSessionNames.sorted()
            }

            if !completedBeforeTimeout || !remainingSessionNames.isEmpty {
                NSLog(
                    "App termination zellij cleanup completed=%d remaining=%@",
                    completedBeforeTimeout ? 1 : 0,
                    remainingSessionNames.joined(separator: ",")
                )
            }

            return ShutdownResult(
                completedBeforeTimeout: completedBeforeTimeout,
                remainingSessionNames: remainingSessionNames
            )
        }
        appTerminationShutdownTask = task
        return await task.value
    }

    func forgetWorkspace(_ workspaceId: UUID) {
        cancelBackgroundCreationTask(for: workspaceId)
        cleanupAndScheduleDeletion(
            for: removeRegistrations(for: workspaceId),
            removeAttachScriptFiles: true
        )
    }

    private func startStartupCleanup() {
        startupCleanupTask = Task { [weak self] in
            guard let self else { return }
            do {
                let configuration = try self.runnerConfiguration()
                try await self.runner.cleanupStaleSessions(
                    configuration: configuration,
                    sessionPrefix: Self.sessionPrefix
                )
            } catch {
                NSLog("Failed initial zellij cleanup: %@", String(describing: error))
            }
        }
    }

    private func terminalSessionDescriptor(for spec: SessionSpec) -> TerminalSessionDescriptor {
        TerminalSessionDescriptor(
            attachCommand: attachScriptURL(for: spec).path,
            startupEnvironment: launchRequestEnvironment(for: spec),
            workingDirectory: spec.workingDirectory
        )
    }

    private func registerSession(
        owner: SessionOwner,
        spec: SessionSpec,
        currentDescriptor: TerminalSessionDescriptor? = nil
    ) throws -> RegistrationResult {
        let descriptor = terminalSessionDescriptor(for: spec)
        let needsStartupRefresh =
            currentDescriptor != descriptor ||
            !fileManager.fileExists(atPath: descriptor.attachCommand)

        if needsStartupRefresh {
            try writeAttachScript(for: spec, descriptor: descriptor)
        }

        sessionByOwner[owner] = RegisteredSession(spec: spec, descriptor: descriptor)

        return RegistrationResult(
            attachCommand: descriptor.attachCommand,
            startupEnvironment: descriptor.startupEnvironment,
            didChangeStartup: needsStartupRefresh
        )
    }

    private func writeAttachScript(
        for spec: SessionSpec,
        descriptor: TerminalSessionDescriptor
    ) throws {
        try ensureRuntimeDirectories()
        let scriptURL = attachScriptURL(for: spec)
        var components = try baseArguments().map(Self.shellQuoted)
        components += ["attach", "-c", Self.shellQuoted(spec.sessionName), "options", "--default-shell", Self.shellQuoted(try wrapperPath())]
        if let workingDirectory = descriptor.workingDirectory {
            components += ["--default-cwd", Self.shellQuoted(workingDirectory)]
        }
        let exports = descriptor.startupEnvironment
            .sorted { $0.key < $1.key }
            .map { "export \($0.key)=\(Self.shellQuoted($0.value))" }
            .joined(separator: "\n")
        let script = """
        #!/bin/sh
        \(exports)
        exec \(components.joined(separator: " "))
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    private func backgroundEnvironment(for spec: SessionSpec) -> [String: String] {
        var environment = TerminalProcessEnvironment.resolvedEnvironment(
            panelId: spec.panelId,
            workspaceId: spec.workspaceId,
            portOrdinal: spec.portOrdinal
        )
        environment.merge(launchRequestEnvironment(for: spec)) { _, newValue in newValue }
        return environment
    }

    private func launchRequestEnvironment(for spec: SessionSpec) -> [String: String] {
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return [
            "CMUX_ZELLIJ_LAUNCH_FILE": launchRequestFileURL(for: spec).path,
            "CMUX_ZELLIJ_SHELL": shellPath,
        ]
    }

    private func runnerConfiguration() throws -> ZellijProcessConfiguration {
        ZellijProcessConfiguration(
            baseArguments: try baseArguments(),
            environment: mergedEnvironment(overrides: nil)
        )
    }

    private func baseArguments() throws -> [String] {
        guard fileManager.fileExists(atPath: zellijBinaryURL.path) else {
            throw SessionError.missingBundledBinary
        }
        guard fileManager.fileExists(atPath: configFileURL.path) else {
            throw SessionError.missingBundledConfig
        }
        try ensureRuntimeDirectories()
        return [
            zellijBinaryURL.path,
            "--config", configFileURL.path,
            "--config-dir", zellijConfigDirectoryURL.path,
            "--data-dir", zellijDataDirectoryURL.path,
        ]
    }

    private func wrapperPath() throws -> String {
        let wrapper = zellijConfigDirectoryURL.appendingPathComponent("zenban-shell.sh")
        guard fileManager.fileExists(atPath: wrapper.path) else {
            throw SessionError.missingBundledWrapper
        }
        return wrapper.path
    }

    private func ensureRuntimeDirectories() throws {
        try fileManager.createDirectory(at: runtimeRootDirectoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: zellijDataDirectoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: launchFilesDirectoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: attachScriptsDirectoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: zellijSocketDirectoryURL, withIntermediateDirectories: true)
    }

    private func removeLaunchRequestFile(for spec: SessionSpec) throws {
        let launchRequestFile = launchRequestFileURL(for: spec)
        guard fileManager.fileExists(atPath: launchRequestFile.path) else { return }
        try fileManager.removeItem(at: launchRequestFile)
    }

    private func writeLaunchRequest(
        token: String,
        command: String,
        for spec: SessionSpec
    ) throws {
        try ensureRuntimeDirectories()
        let launchRequest = "\(token)\n\(command)\n"
        try launchRequest.write(
            to: launchRequestFileURL(for: spec),
            atomically: true,
            encoding: .utf8
        )
    }

    private func removeAttachScript(for spec: SessionSpec) throws {
        let scriptURL = attachScriptURL(for: spec)
        guard fileManager.fileExists(atPath: scriptURL.path) else { return }
        try fileManager.removeItem(at: scriptURL)
    }

    private func removePanelRegistration(for panelId: UUID) {
        guard let owner = sessionByOwner.keys.first(where: { owner in
            if case .panel(let ownerPanelId) = owner {
                return ownerPanelId == panelId
            }
            return false
        }) else {
            return
        }
        sessionByOwner.removeValue(forKey: owner)
    }

    private func resetManagedSessionState(removeAttachScriptFiles: Bool) -> Set<String> {
        startupCleanupTask?.cancel()
        startupCleanupTask = nil
        for workspaceId in Array(backgroundCreationTasks.keys) {
            cancelBackgroundCreationTask(for: workspaceId)
        }
        let knownSessionNames = knownSessionNames()
        for spec in sessionByOwner.values.map(\.spec) {
            cleanupWorkspaceArtifacts(
                for: spec,
                removeAttachScriptFile: removeAttachScriptFiles
            )
        }
        sessionByOwner.removeAll(keepingCapacity: false)
        return knownSessionNames
    }

    private func knownSessionNames() -> Set<String> {
        Set(sessionByOwner.values.map(\.spec.sessionName))
    }

    private func rootRegistration(for workspaceId: UUID) -> RegisteredSession? {
        sessionByOwner[.workspaceRoot(workspaceId)]
    }

    private func panelRegistration(for panelId: UUID) -> RegisteredSession? {
        sessionByOwner.first { owner, _ in
            if case .panel(let ownerPanelId) = owner {
                return ownerPanelId == panelId
            }
            return false
        }?.value
    }

    private func sessionSpecs(for workspaceId: UUID) -> [SessionSpec] {
        sessionByOwner.compactMap { owner, registration in
            switch owner {
            case .workspaceRoot(let ownerWorkspaceId) where ownerWorkspaceId == workspaceId:
                return registration.spec
            case .panel where registration.spec.workspaceId == workspaceId:
                return registration.spec
            default:
                return nil
            }
        }
    }

    private func removeRegistrations(for workspaceId: UUID) -> [SessionSpec] {
        let owners = sessionByOwner.compactMap { owner, registration -> SessionOwner? in
            switch owner {
            case .workspaceRoot(let ownerWorkspaceId) where ownerWorkspaceId == workspaceId:
                return owner
            case .panel where registration.spec.workspaceId == workspaceId:
                return owner
            default:
                return nil
            }
        }
        return owners.compactMap { owner in
            sessionByOwner.removeValue(forKey: owner)?.spec
        }
    }

    private func cleanupAndScheduleDeletion(
        for specs: [SessionSpec],
        removeAttachScriptFiles: Bool
    ) {
        for spec in specs {
            cleanupWorkspaceArtifacts(for: spec, removeAttachScriptFile: removeAttachScriptFiles)
            scheduleSessionDeletion(sessionName: spec.sessionName)
        }
    }

    private func cleanupWorkspaceArtifacts(for spec: SessionSpec, removeAttachScriptFile: Bool) {
        try? removeLaunchRequestFile(for: spec)
        guard removeAttachScriptFile else { return }
        try? removeAttachScript(for: spec)
    }

    private func cancelBackgroundCreationTask(for workspaceId: UUID) {
        backgroundCreationTasks[workspaceId]?.task.cancel()
        backgroundCreationTasks.removeValue(forKey: workspaceId)
    }

    private func scheduleSessionDeletion(sessionName: String) {
        Task { [runner] in
            do {
                let configuration = try self.runnerConfiguration()
#if DEBUG
                if let deleteSessionHookForTesting {
                    try await deleteSessionHookForTesting(sessionName)
                    return
                }
#endif
                try await runner.deleteSession(
                    configuration: configuration,
                    sessionName: sessionName,
                    ignoredExitStatuses: [1]
                )
            } catch is CancellationError {
            } catch {
                NSLog(
                    "Failed to delete zellij session %@: %@",
                    sessionName,
                    String(describing: error)
                )
            }
        }
    }

    private func managedSessionNamesForTermination(
        configuration: ZellijProcessConfiguration,
        knownSessionNames: Set<String>
    ) async throws -> Set<String> {
        let listedSessionNames: [String]
#if DEBUG
        if let sessionNamesHookForTesting {
            listedSessionNames = try await sessionNamesHookForTesting()
        } else {
            listedSessionNames = try await runner.currentSessionNames(configuration: configuration)
        }
#else
        listedSessionNames = try await runner.currentSessionNames(configuration: configuration)
#endif
        let managedSessionNames = listedSessionNames
            .filter { $0.hasPrefix(Self.sessionPrefix) }
        return Set(managedSessionNames).union(knownSessionNames)
    }

    private func deleteSessionsForAppTermination(
        _ sessionNames: Set<String>,
        configuration: ZellijProcessConfiguration,
        timeout: TimeInterval
    ) async -> Bool {
        let cleanupTask = Task<Void, Error> { [runner] in
#if DEBUG
            if let cleanupSessionsHookForTesting {
                try await cleanupSessionsHookForTesting(sessionNames)
                return
            }
#endif
            for sessionName in sessionNames.sorted() {
#if DEBUG
                if let deleteSessionHookForTesting {
                    try await deleteSessionHookForTesting(sessionName)
                    continue
                }
#endif
                try await runner.deleteSession(
                    configuration: configuration,
                    sessionName: sessionName,
                    ignoredExitStatuses: [1]
                )
            }
        }

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await cleanupTask.value
                }
                group.addTask {
                    let timeoutDuration = max(timeout, 0)
                    try await Task.sleep(for: .seconds(timeoutDuration))
                    throw ShutdownTimeoutError.timedOut
                }
                _ = try await group.next()
                group.cancelAll()
            }
            return true
        } catch ShutdownTimeoutError.timedOut {
            cleanupTask.cancel()
            return false
        } catch is CancellationError {
            cleanupTask.cancel()
            return false
        } catch {
            cleanupTask.cancel()
            NSLog(
                "Failed to delete zellij sessions during app termination: %@",
                String(describing: error)
            )
            return false
        }
    }

    private func launchRequestFileURL(for spec: SessionSpec) -> URL {
        launchFilesDirectoryURL.appendingPathComponent("\(spec.sessionName).launch-request")
    }

    private func attachScriptURL(for spec: SessionSpec) -> URL {
        attachScriptsDirectoryURL.appendingPathComponent("\(spec.sessionName).sh")
    }

    private static func sessionName(for workspaceId: UUID) -> String {
        "\(sessionPrefix)\(workspaceId.uuidString.lowercased())"
    }

    private static func panelSessionName(for panelId: UUID) -> String {
        "\(sessionPrefix)panel-\(panelId.uuidString.lowercased())"
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private func normalizedDirectory(_ directory: String?) -> String? {
        let trimmed = directory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private var zellijBinaryURL: URL {
        Bundle.main.resourceURL?
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("zellij", isDirectory: false)
            ?? URL(fileURLWithPath: "/nonexistent")
    }

    private var zellijConfigDirectoryURL: URL {
        Bundle.main.resourceURL?
            .appendingPathComponent("zellij", isDirectory: true)
            ?? URL(fileURLWithPath: "/nonexistent")
    }

    private var configFileURL: URL {
        zellijConfigDirectoryURL.appendingPathComponent("config.kdl", isDirectory: false)
    }

    private var runtimeRootDirectoryURL: URL {
        let cachesURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return cachesURL
            .appendingPathComponent("Zenban", isDirectory: true)
            .appendingPathComponent("Zellij", isDirectory: true)
    }

    private var zellijDataDirectoryURL: URL {
        runtimeRootDirectoryURL.appendingPathComponent("data", isDirectory: true)
    }

    private var launchFilesDirectoryURL: URL {
        runtimeRootDirectoryURL.appendingPathComponent("launch", isDirectory: true)
    }

    private var attachScriptsDirectoryURL: URL {
        runtimeRootDirectoryURL.appendingPathComponent("attach", isDirectory: true)
    }

    private var zellijSocketDirectoryURL: URL {
        URL(fileURLWithPath: TerminalProcessEnvironment.zellijSocketDirectoryPath, isDirectory: true)
    }

    private func mergedEnvironment(overrides: [String: String]?) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["ZELLIJ_SOCKET_DIR"] = zellijSocketDirectoryURL.path
        if let overrides {
            environment.merge(overrides) { _, newValue in newValue }
        }
        return environment
    }
}

#if DEBUG
extension ZellijSessionManager {
    func configureBackgroundSessionHookForTesting(
        _ hook: (@Sendable (SessionSpec) async throws -> Void)? = nil
    ) {
        prepareBackgroundSessionHookForTesting = hook
    }

    func configureDeleteSessionHookForTesting(
        _ hook: (@Sendable (String) async throws -> Void)? = nil
    ) {
        deleteSessionHookForTesting = hook
    }

    func configureCleanupSessionsHookForTesting(
        _ hook: (@Sendable (Set<String>) async throws -> Void)? = nil
    ) {
        cleanupSessionsHookForTesting = hook
    }

    func configureSessionNamesHookForTesting(
        _ hook: (@Sendable () async throws -> [String])? = nil
    ) {
        sessionNamesHookForTesting = hook
    }

    func resetTestingHooks() {
        prepareBackgroundSessionHookForTesting = nil
        deleteSessionHookForTesting = nil
        cleanupSessionsHookForTesting = nil
        sessionNamesHookForTesting = nil
    }

    func hasBackgroundCreationTaskForTesting(workspaceId: UUID) -> Bool {
        backgroundCreationTasks[workspaceId] != nil
    }
}
#endif
