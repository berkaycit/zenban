import Foundation

@MainActor
final class ZellijSessionManager {
    private static let sessionPrefix = "zenban-ws-"

    struct SessionSpec {
        let workspaceId: UUID
        let panelId: UUID
        let portOrdinal: Int
        let workingDirectory: String?
        let sessionName: String
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
    private var sessionSpecByWorkspaceId: [UUID: SessionSpec] = [:]
    private var backgroundCreationTasks: [UUID: Task<Void, Error>] = [:]

    private init() {
        try? cleanupStaleSessionsSynchronously()
    }

    func registerWorkspace(
        workspaceId: UUID,
        panelId: UUID,
        portOrdinal: Int,
        workingDirectory: String?
    ) {
        sessionSpecByWorkspaceId[workspaceId] = SessionSpec(
            workspaceId: workspaceId,
            panelId: panelId,
            portOrdinal: portOrdinal,
            workingDirectory: normalizedDirectory(workingDirectory),
            sessionName: Self.sessionName(for: workspaceId)
        )
    }

    func sessionPanelId(for workspaceId: UUID) -> UUID? {
        sessionSpecByWorkspaceId[workspaceId]?.panelId
    }

    func isManagedWorkspace(_ workspaceId: UUID) -> Bool {
        sessionSpecByWorkspaceId[workspaceId] != nil
    }

    func attachCommand(for workspaceId: UUID) throws -> String {
        guard let spec = sessionSpecByWorkspaceId[workspaceId] else {
            throw SessionError.missingSessionSpec
        }
        return try writeAttachScript(for: spec).path
    }

    func startupEnvironment(for workspaceId: UUID) throws -> [String: String] {
        guard let spec = sessionSpecByWorkspaceId[workspaceId] else {
            throw SessionError.missingSessionSpec
        }
        return launchRequestEnvironment(for: spec)
    }

    func queueLaunchRequest(
        for workspaceId: UUID,
        token: String,
        command: String
    ) throws {
        guard let spec = sessionSpecByWorkspaceId[workspaceId] else {
            throw SessionError.missingSessionSpec
        }
        try ensureRuntimeDirectories()
        let launchRequest = "\(token)\n\(command)\n"
        try launchRequest.write(
            to: launchRequestFileURL(for: spec),
            atomically: true,
            encoding: .utf8
        )
    }

    func clearLaunchRequest(for workspaceId: UUID) {
        guard let spec = sessionSpecByWorkspaceId[workspaceId] else { return }
        try? removeLaunchRequestFile(for: spec)
    }

    func prepareBackgroundSession(
        workspaceId: UUID
    ) async throws {
        guard let spec = sessionSpecByWorkspaceId[workspaceId] else { return }
        if let task = backgroundCreationTasks[workspaceId] {
            return try await task.value
        }

        let task = Task<Void, Error> { @MainActor in
            defer { self.backgroundCreationTasks.removeValue(forKey: workspaceId) }
            let environment = self.backgroundEnvironment(for: spec)
            var args = try self.baseArguments()
            args += ["attach", "-b", spec.sessionName, "options", "--default-shell", try self.wrapperPath()]
            if let workingDirectory = spec.workingDirectory {
                args += ["--default-cwd", workingDirectory]
            }
            try self.runSynchronously(arguments: args, environment: environment, ignoredExitStatuses: [])
            try self.waitForSessionAvailability(spec.sessionName)
        }
        backgroundCreationTasks[workspaceId] = task
        return try await task.value
    }

    func killSession(for workspaceId: UUID) {
        guard let spec = sessionSpecByWorkspaceId[workspaceId] else { return }
        try? removeLaunchRequestFile(for: spec)
        try? removeAttachScript(for: spec)
        try? deleteSessionSynchronously(spec.sessionName)
        sessionSpecByWorkspaceId.removeValue(forKey: workspaceId)
    }

    func killRuntime(for workspaceId: UUID) {
        guard let spec = sessionSpecByWorkspaceId[workspaceId] else { return }
        try? deleteSessionSynchronously(spec.sessionName)
    }

    func killAllSessions() {
        let knownSessionNames = Set(sessionSpecByWorkspaceId.values.map(\.sessionName))
        try? cleanupStaleSessionsSynchronously(additionalSessionNames: knownSessionNames)
        sessionSpecByWorkspaceId.removeAll(keepingCapacity: false)
    }

    private func writeAttachScript(for spec: SessionSpec) throws -> URL {
        try ensureRuntimeDirectories()
        let scriptURL = attachScriptURL(for: spec)
        var components = try baseArguments().map(Self.shellQuoted)
        components += ["attach", "-c", Self.shellQuoted(spec.sessionName), "options", "--default-shell", Self.shellQuoted(try wrapperPath())]
        if let workingDirectory = spec.workingDirectory {
            components += ["--default-cwd", Self.shellQuoted(workingDirectory)]
        }
        let exports = launchRequestEnvironment(for: spec)
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
        return scriptURL
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

    private func removeAttachScript(for spec: SessionSpec) throws {
        let scriptURL = attachScriptURL(for: spec)
        guard fileManager.fileExists(atPath: scriptURL.path) else { return }
        try fileManager.removeItem(at: scriptURL)
    }

    private func deleteSessionSynchronously(_ sessionName: String) throws {
        var args = try baseArguments()
        args += ["delete-session", "-f", sessionName]
        try runSynchronously(arguments: args, environment: nil, ignoredExitStatuses: [1])
    }

    private func cleanupStaleSessionsSynchronously(
        additionalSessionNames: Set<String> = []
    ) throws {
        let sessionNamesToDelete = try currentSessionNamesSynchronously()
            .filter { $0.hasPrefix(Self.sessionPrefix) || additionalSessionNames.contains($0) }
        for sessionName in sessionNamesToDelete {
            try deleteSessionSynchronously(sessionName)
        }
    }

    private func currentSessionNamesSynchronously() throws -> [String] {
        var args = try baseArguments()
        args += ["list-sessions", "--short"]
        let result = try runAndCaptureSynchronously(arguments: args, environment: nil)
        if result.status != 0,
           result.output.localizedCaseInsensitiveContains("No active zellij sessions found") {
            return []
        }
        if result.status != 0 && result.output.isEmpty {
            return []
        }
        if result.status != 0 {
            throw SessionError.processFailed(
                command: args.joined(separator: " "),
                status: result.status,
                output: result.output
            )
        }
        return result.output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func waitForSessionAvailability(_ sessionName: String) throws {
        for _ in 0..<40 {
            if try currentSessionNamesSynchronously().contains(sessionName) {
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw SessionError.processFailed(
            command: "wait-for-session \(sessionName)",
            status: 1,
            output: "Timed out waiting for session metadata."
        )
    }

    private func runSynchronously(
        arguments: [String],
        environment: [String: String]?,
        ignoredExitStatuses: Set<Int32>
    ) throws {
        let result = try runAndCaptureSynchronously(arguments: arguments, environment: environment)
        if result.status == 0 || ignoredExitStatuses.contains(result.status) {
            return
        }
        throw SessionError.processFailed(
            command: arguments.joined(separator: " "),
            status: result.status,
            output: result.output
        )
    }

    private func runAndCaptureSynchronously(
        arguments: [String],
        environment: [String: String]?
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = mergedEnvironment(overrides: environment)

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        var combinedOutput = Data()
        combinedOutput.append(stdoutData)
        combinedOutput.append(stderrData)
        let output = String(data: combinedOutput, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process.terminationStatus, output)
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
