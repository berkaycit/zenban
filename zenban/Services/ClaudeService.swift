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
        ["/opt/homebrew/bin/claude", "/usr/local/bin/claude", "/usr/bin/claude"]
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Build PATH environment variable that includes common locations for node, homebrew, etc.
    private static func buildEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let commonPaths = [
            "/opt/homebrew/bin",           // Apple Silicon homebrew
            "/usr/local/bin",              // Intel homebrew / standard
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            "\(home)/.local/bin",          // pip/npm local installs
            "\(home)/.npm-global/bin",     // npm global
            "/opt/local/bin",              // MacPorts
        ]

        // Get current PATH if available
        let currentPath = env["PATH"] ?? ""

        // Find actual nvm node path if exists
        var nvmNodePath: String?
        let nvmDir = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmDir) {
            if let latestVersion = versions.sorted().last {
                let binPath = "\(nvmDir)/\(latestVersion)/bin"
                if FileManager.default.fileExists(atPath: binPath) {
                    nvmNodePath = binPath
                }
            }
        }

        var allPaths = commonPaths
        if let nvmPath = nvmNodePath {
            allPaths.insert(nvmPath, at: 0)
        }

        // Combine with current PATH, avoiding duplicates
        let pathSet = Set(currentPath.split(separator: ":").map(String.init))
        let newPaths = allPaths.filter { !pathSet.contains($0) }

        env["PATH"] = (newPaths + [currentPath]).joined(separator: ":")
        return env
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
                process.environment = buildEnvironment()

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
