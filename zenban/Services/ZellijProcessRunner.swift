import Foundation

struct ZellijProcessConfiguration: Sendable {
    let baseArguments: [String]
    let environment: [String: String]
}

actor ZellijProcessRunner {
    func cleanupStaleSessions(
        configuration: ZellijProcessConfiguration,
        sessionPrefix: String,
        additionalSessionNames: Set<String> = []
    ) async throws {
        let sessionNamesToDelete = try await currentSessionNames(configuration: configuration)
            .filter { $0.hasPrefix(sessionPrefix) || additionalSessionNames.contains($0) }
        for sessionName in sessionNamesToDelete {
            try await deleteSession(
                configuration: configuration,
                sessionName: sessionName,
                ignoredExitStatuses: [1]
            )
        }
    }

    func prepareBackgroundSession(
        configuration: ZellijProcessConfiguration,
        sessionName: String,
        environment: [String: String],
        wrapperPath: String,
        workingDirectory: String?
    ) async throws {
        var args = configuration.baseArguments
        args += ["attach", "-b", sessionName, "options", "--default-shell", wrapperPath]
        if let workingDirectory {
            args += ["--default-cwd", workingDirectory]
        }
        try await run(
            arguments: args,
            environment: mergedEnvironment(
                baseEnvironment: configuration.environment,
                overrides: environment
            ),
            ignoredExitStatuses: []
        )
        try await waitForSessionAvailability(
            sessionName,
            configuration: configuration
        )
    }

    func deleteSession(
        configuration: ZellijProcessConfiguration,
        sessionName: String,
        ignoredExitStatuses: Set<Int32>
    ) async throws {
        var args = configuration.baseArguments
        args += ["delete-session", "-f", sessionName]
        try await run(
            arguments: args,
            environment: configuration.environment,
            ignoredExitStatuses: ignoredExitStatuses
        )
    }

    func currentSessionNames(
        configuration: ZellijProcessConfiguration
    ) async throws -> [String] {
        var args = configuration.baseArguments
        args += ["list-sessions", "--short"]
        let result = try await runAndCapture(
            arguments: args,
            environment: configuration.environment
        )
        if result.status != 0,
           result.output.localizedCaseInsensitiveContains("No active zellij sessions found") {
            return []
        }
        if result.status != 0 && result.output.isEmpty {
            return []
        }
        if result.status != 0 {
            throw ZellijSessionManager.SessionError.processFailed(
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

    private func waitForSessionAvailability(
        _ sessionName: String,
        configuration: ZellijProcessConfiguration
    ) async throws {
        for _ in 0..<40 {
            try Task.checkCancellation()
            if try await currentSessionNames(configuration: configuration).contains(sessionName) {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ZellijSessionManager.SessionError.processFailed(
            command: "wait-for-session \(sessionName)",
            status: 1,
            output: "Timed out waiting for session metadata."
        )
    }

    private func run(
        arguments: [String],
        environment: [String: String],
        ignoredExitStatuses: Set<Int32>
    ) async throws {
        let result = try await runAndCapture(arguments: arguments, environment: environment)
        if result.status == 0 || ignoredExitStatuses.contains(result.status) {
            return
        }
        throw ZellijSessionManager.SessionError.processFailed(
            command: arguments.joined(separator: " "),
            status: result.status,
            output: result.output
        )
    }

    private func runAndCapture(
        arguments: [String],
        environment: [String: String]
    ) async throws -> (status: Int32, output: String) {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = environment

        return try await withTaskCancellationHandler(operation: {
            try process.run()
            while process.isRunning {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(50))
            }

            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            var combinedOutput = Data()
            combinedOutput.append(stdoutData)
            combinedOutput.append(stderrData)
            let output = String(data: combinedOutput, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (process.terminationStatus, output)
        }, onCancel: {
            if process.isRunning {
                process.terminate()
            }
        })
    }

    private func mergedEnvironment(
        baseEnvironment: [String: String],
        overrides: [String: String]
    ) -> [String: String] {
        var environment = baseEnvironment
        environment.merge(overrides) { _, newValue in newValue }
        return environment
    }
}
