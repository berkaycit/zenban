import Foundation

/// Manages dev server processes for cards
@Observable
final class DevServerManager {

    enum ServerState: Equatable {
        case idle
        case runningSetup(output: String)
        case startingServer(output: String)
        case detectingPort(output: String)
        case ready(url: URL)
        case error(message: String)
    }

    private(set) var serverStates: [UUID: ServerState] = [:]
    private var processes: [UUID: Process] = [:]
    private var outputPipes: [UUID: Pipe] = [:]
    private var outputBuffers: [UUID: String] = [:]

    // MARK: - Public API

    func state(for cardID: UUID) -> ServerState {
        serverStates[cardID] ?? .idle
    }

    /// Run setup command (npm install etc.) and wait for completion
    func runSetup(
        for cardID: UUID,
        command: String,
        directory: String
    ) async throws {
        // Stop ALL servers including this card (prevents orphaned processes from rapid clicks)
        stopAllServers()

        serverStates[cardID] = .runningSetup(output: "")
        outputBuffers[cardID] = ""

        try await runCommandToCompletion(
            for: cardID,
            command: command,
            directory: directory,
            stateBuilder: { output in .runningSetup(output: output) },
            timeout: 300 // 5 minutes for setup
        )
    }

    /// Start dev server and detect port
    func startDevServer(
        for cardID: UUID,
        command: String,
        directory: String
    ) async throws -> URL {
        // Stop ALL servers including this card (prevents orphaned processes from rapid clicks)
        stopAllServers()

        serverStates[cardID] = .startingServer(output: "")
        outputBuffers[cardID] = ""

        return try await runDevServerProcess(
            for: cardID,
            command: command,
            directory: directory
        )
    }

    /// Stop server for a specific card
    func stopServer(for cardID: UUID) {
        // Clean up pipe handler first to prevent retain cycles
        if let pipe = outputPipes[cardID] {
            pipe.fileHandleForReading.readabilityHandler = nil
            outputPipes[cardID] = nil
        }

        // Kill the process and its children (process group)
        if let process = processes[cardID] {
            killProcessTree(process)
            processes[cardID] = nil
        }

        serverStates[cardID] = .idle
        outputBuffers[cardID] = nil
    }

    /// Stop all running servers
    func stopAllServers() {
        // Clean up all pipe handlers first
        for (_, pipe) in outputPipes {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
        outputPipes.removeAll()

        // Kill all processes and their children
        for (cardID, process) in processes {
            killProcessTree(process)
            serverStates[cardID] = .idle
        }
        processes.removeAll()
        outputBuffers.removeAll()
    }

    /// Kill process and all its child processes
    private func killProcessTree(_ process: Process) {
        guard process.isRunning else { return }

        // First try SIGTERM for graceful shutdown
        process.terminate()

        // Give it a moment to clean up
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            if process.isRunning {
                // If still running, force kill the process group
                let pid = process.processIdentifier
                // Kill entire process group (negative pid)
                kill(-pid, SIGKILL)
            }
        }
    }

    /// Check if a server is running for a card
    func isServerRunning(for cardID: UUID) -> Bool {
        switch serverStates[cardID] {
        case .ready, .startingServer, .detectingPort:
            return true
        default:
            return false
        }
    }

    // MARK: - Private

    private func runCommandToCompletion(
        for cardID: UUID,
        command: String,
        directory: String,
        stateBuilder: @escaping (String) -> ServerState,
        timeout: TimeInterval
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: DevServerError.cancelled)
                    return
                }

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-c", command]
                process.currentDirectoryURL = URL(fileURLWithPath: directory)
                process.environment = ProcessEnvironment.buildWithNodeSupport()

                let outputPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = outputPipe

                // Store references for cleanup (must be on main thread for thread safety)
                DispatchQueue.main.sync {
                    self.processes[cardID] = process
                    self.outputPipes[cardID] = outputPipe
                }

                let group = DispatchGroup()
                group.enter()

                outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    guard !data.isEmpty,
                          let str = String(data: data, encoding: .utf8),
                          let self else { return }

                    DispatchQueue.main.async {
                        let currentOutput = self.outputBuffers[cardID] ?? ""
                        let newOutput = currentOutput + str
                        self.outputBuffers[cardID] = newOutput
                        self.serverStates[cardID] = stateBuilder(newOutput)
                    }
                }

                process.terminationHandler = { _ in
                    group.leave()
                }

                do {
                    try process.run()
                } catch {
                    // Clean up on error (must be on main thread for thread safety)
                    outputPipe.fileHandleForReading.readabilityHandler = nil
                    DispatchQueue.main.sync {
                        self.processes[cardID] = nil
                        self.outputPipes[cardID] = nil
                        self.serverStates[cardID] = .error(message: error.localizedDescription)
                    }
                    continuation.resume(throwing: error)
                    return
                }

                let result = group.wait(timeout: .now() + timeout)

                // Clean up pipe handler (must be on main thread for thread safety)
                outputPipe.fileHandleForReading.readabilityHandler = nil
                DispatchQueue.main.sync {
                    self.outputPipes[cardID] = nil
                    self.processes[cardID] = nil
                }

                if result == .timedOut {
                    self.killProcessTree(process)
                    DispatchQueue.main.async {
                        self.serverStates[cardID] = .error(message: "Setup timed out after \(Int(timeout)) seconds")
                    }
                    continuation.resume(throwing: DevServerError.timeout)
                    return
                }

                if process.terminationStatus != 0 {
                    // Read outputBuffers on main thread for thread safety
                    var output = ""
                    DispatchQueue.main.sync {
                        output = self.outputBuffers[cardID] ?? ""
                        self.serverStates[cardID] = .error(message: "Setup failed:\n\(output)")
                    }
                    continuation.resume(throwing: DevServerError.setupFailed(output))
                    return
                }

                continuation.resume()
            }
        }
    }

    private func runDevServerProcess(
        for cardID: UUID,
        command: String,
        directory: String
    ) async throws -> URL {
        // Use a class to track state across closures (reference semantics)
        class ContinuationState {
            var isResumed = false
            var portDetected = false
        }
        let state = ContinuationState()

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else {
                    if !state.isResumed {
                        state.isResumed = true
                        continuation.resume(throwing: DevServerError.cancelled)
                    }
                    return
                }

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-c", command]
                process.currentDirectoryURL = URL(fileURLWithPath: directory)
                process.environment = ProcessEnvironment.buildWithNodeSupport()

                let outputPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = outputPipe

                // Store references for cleanup (must be on main thread for thread safety)
                DispatchQueue.main.sync {
                    self.processes[cardID] = process
                    self.outputPipes[cardID] = outputPipe
                }

                outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    guard !data.isEmpty,
                          let str = String(data: data, encoding: .utf8),
                          let self else { return }

                    DispatchQueue.main.async {
                        let currentOutput = self.outputBuffers[cardID] ?? ""
                        let newOutput = currentOutput + str
                        self.outputBuffers[cardID] = newOutput

                        if !state.portDetected && !state.isResumed {
                            self.serverStates[cardID] = .detectingPort(output: newOutput)

                            if let port = Self.parsePortFromOutput(newOutput) {
                                state.portDetected = true
                                state.isResumed = true
                                let url = URL(string: "http://localhost:\(port)")!
                                self.serverStates[cardID] = .ready(url: url)
                                continuation.resume(returning: url)
                            }
                        }
                    }
                }

                process.terminationHandler = { [weak self] _ in
                    guard let self else { return }
                    DispatchQueue.main.async {
                        // Clean up pipe handler
                        outputPipe.fileHandleForReading.readabilityHandler = nil
                        self.outputPipes[cardID] = nil

                        if !state.portDetected && !state.isResumed {
                            state.isResumed = true
                            let output = self.outputBuffers[cardID] ?? ""
                            self.serverStates[cardID] = .error(message: "Server stopped unexpectedly:\n\(output)")
                            continuation.resume(throwing: DevServerError.serverCrashed(output))
                        }
                        self.processes[cardID] = nil
                    }
                }

                do {
                    try process.run()
                } catch {
                    // Clean up on error (must be on main thread for thread safety)
                    outputPipe.fileHandleForReading.readabilityHandler = nil
                    var shouldResume = false
                    DispatchQueue.main.sync {
                        self.processes[cardID] = nil
                        self.outputPipes[cardID] = nil
                        if !state.isResumed {
                            state.isResumed = true
                            shouldResume = true
                            self.serverStates[cardID] = .error(message: error.localizedDescription)
                        }
                    }
                    if shouldResume {
                        continuation.resume(throwing: error)
                    }
                    return
                }

                // Timeout for port detection (30 seconds)
                DispatchQueue.global().asyncAfter(deadline: .now() + 30) { [weak self] in
                    guard let self, !state.isResumed else { return }
                    DispatchQueue.main.async {
                        guard !state.isResumed else { return }
                        state.isResumed = true
                        let output = self.outputBuffers[cardID] ?? ""
                        self.serverStates[cardID] = .error(message: "Could not detect server port:\n\(output)")
                        // Kill the process since we're timing out
                        self.stopServer(for: cardID)
                        continuation.resume(throwing: DevServerError.portDetectionTimeout)
                    }
                }
            }
        }
    }

    // MARK: - Port Detection

    private static let portPatterns = [
        #"(?:localhost|127\.0\.0\.1|0\.0\.0\.0):(\d+)"#,
        #"Local:\s+https?://[^:]+:(\d+)"#,
        #"ready.*(?:localhost|127\.0\.0\.1):(\d+)"#,
        #"https?://(?:localhost|127\.0\.0\.1):(\d+)"#,
        #"http://\[?::1\]?:(\d+)"#,
        #"listening on.*:(\d+)"#,
        #"started at.*:(\d+)"#
    ]

    private static func parsePortFromOutput(_ output: String) -> Int? {
        for pattern in portPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
               let portRange = Range(match.range(at: 1), in: output),
               let port = Int(output[portRange]),
               port > 0 && port < 65536 {
                return port
            }
        }
        return nil
    }

}

// MARK: - Errors

enum DevServerError: LocalizedError {
    case cancelled
    case timeout
    case setupFailed(String)
    case serverCrashed(String)
    case portDetectionTimeout
    case alreadyRunning

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Operation was cancelled"
        case .timeout:
            return "Operation timed out"
        case .setupFailed(let output):
            return "Setup failed: \(output)"
        case .serverCrashed(let output):
            return "Server crashed: \(output)"
        case .portDetectionTimeout:
            return "Could not detect server port within timeout"
        case .alreadyRunning:
            return "Server is already running for this card"
        }
    }
}
