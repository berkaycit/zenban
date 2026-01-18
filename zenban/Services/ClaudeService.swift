import Foundation

/// Claude Code CLI service implementation
struct ClaudeService: AIProvider {

    // MARK: - AIProvider Protocol

    static var isAvailable: Bool { executablePath != nil }

    static var providerName: String { "Claude Code CLI" }

    static func generate(
        prompt: String,
        context: String,
        workingDirectory: String,
        config: AIProviderConfig
    ) async throws -> String {
        guard isAvailable else {
            throw AIProviderError.providerNotAvailable(providerName)
        }

        return try await runCLI(
            prompt: prompt,
            stdinContent: context,
            directory: workingDirectory,
            timeout: config.timeout
        )
    }

    // MARK: - Path Resolution

    private static var executablePath: String? {
        DependencyCheckService.shared.claudePath()
    }

    // MARK: - CLI Execution

    private static func runCLI(
        prompt: String,
        stdinContent: String,
        directory: String,
        timeout: TimeInterval
    ) async throws -> String {
        guard let path = executablePath else {
            throw AIProviderError.providerNotAvailable(providerName)
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = ["-p", prompt, "--output-format", "text", "--allowedTools", ""]
                process.currentDirectoryURL = URL(fileURLWithPath: directory)
                process.environment = ProcessEnvironment.buildWithNodeSupport()

                let inputPipe = Pipe()
                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.standardInput = inputPipe
                process.standardOutput = outputPipe
                process.standardError = errorPipe

                func cleanup() {
                    try? inputPipe.fileHandleForReading.close()
                    try? inputPipe.fileHandleForWriting.close()
                    try? outputPipe.fileHandleForReading.close()
                    try? outputPipe.fileHandleForWriting.close()
                    try? errorPipe.fileHandleForReading.close()
                    try? errorPipe.fileHandleForWriting.close()
                }

                do {
                    let group = DispatchGroup()
                    group.enter()

                    process.terminationHandler = { _ in
                        group.leave()
                    }

                    try process.run()

                    // Write stdin content and close
                    if let inputData = stdinContent.data(using: .utf8) {
                        inputPipe.fileHandleForWriting.write(inputData)
                    }
                    try? inputPipe.fileHandleForWriting.close()

                    // Wait with timeout
                    let result = group.wait(timeout: .now() + timeout)

                    if result == .timedOut {
                        process.terminate()
                        cleanup()
                        continuation.resume(throwing: AIProviderError.timeout)
                        return
                    }

                    if process.terminationStatus == 0 {
                        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                        cleanup()
                        continuation.resume(returning: String(data: outputData, encoding: .utf8) ?? "")
                    } else {
                        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                        let errorMsg = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                        cleanup()
                        continuation.resume(throwing: AIProviderError.executionFailed(errorMsg))
                    }
                } catch {
                    cleanup()
                    continuation.resume(throwing: AIProviderError.executionFailed(error.localizedDescription))
                }
            }
        }
    }
}
