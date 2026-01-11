import Foundation

/// Source of output line
enum OutputSource: Equatable {
    case serverStdout    // Dev server process stdout
    case serverStderr    // Dev server process stderr (errors/warnings)
    case browserLog      // Browser console.log
    case browserWarn     // Browser console.warn
    case browserError    // Browser console.error / uncaught errors
    case browserInfo     // Browser console.info
    case browserDebug    // Browser console.debug
}

/// Represents a single line of output from dev server or browser console
struct OutputLine: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let source: OutputSource
    let timestamp: Date

    /// Whether this line should be displayed as an error (red color)
    var isError: Bool {
        source == .serverStderr || source == .browserError
    }

    /// Whether this line is a warning (orange color)
    var isWarning: Bool {
        source == .browserWarn
    }

    /// Whether this is from browser console (not server process)
    var isBrowser: Bool {
        switch source {
        case .browserLog, .browserWarn, .browserError, .browserInfo, .browserDebug:
            true
        case .serverStdout, .serverStderr:
            false
        }
    }

    /// Prefix to show the source of the message
    var prefix: String {
        switch source {
        case .serverStdout, .serverStderr:
            return ""
        case .browserLog:
            return "[log] "
        case .browserWarn:
            return "[warn] "
        case .browserError:
            return "[error] "
        case .browserInfo:
            return "[info] "
        case .browserDebug:
            return "[debug] "
        }
    }

    init(text: String, source: OutputSource, timestamp: Date = Date()) {
        self.text = text
        self.source = source
        self.timestamp = timestamp
    }

    /// Convenience initializer for server output
    init(text: String, isError: Bool, timestamp: Date = Date()) {
        self.text = text
        self.source = isError ? .serverStderr : .serverStdout
        self.timestamp = timestamp
    }
}

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
    private(set) var outputVersion: [UUID: Int] = [:]
    private var processes: [UUID: Process] = [:]
    private var stdoutPipes: [UUID: Pipe] = [:]
    private var stderrPipes: [UUID: Pipe] = [:]
    private var outputLines: [UUID: [OutputLine]] = [:]
    private var pendingUIUpdates: [UUID: Bool] = [:]
    /// Partial line buffer for incomplete lines (stdout/stderr)
    private var partialLineBuffers: [UUID: (stdout: String, stderr: String)] = [:]

    /// Maximum number of output lines to keep
    private let maxOutputLines = 1000
    /// UI update throttle interval
    private let uiUpdateInterval: TimeInterval = 0.15

    // MARK: - Public API

    func state(for cardID: UUID) -> ServerState {
        serverStates[cardID] ?? .idle
    }

    /// Get raw output string (for state builders and error messages)
    func output(for cardID: UUID) -> String {
        let lines = outputLines[cardID] ?? []
        return lines.map { $0.text }.joined(separator: "\n")
    }

    /// Get structured output lines with error distinction
    func outputLinesArray(for cardID: UUID) -> [OutputLine] {
        outputLines[cardID] ?? []
    }

    /// Clear output lines for a card (used for browser refresh)
    func clearOutput(for cardID: UUID) {
        outputLines[cardID] = []
        outputVersion[cardID] = (outputVersion[cardID] ?? 0) + 1
    }

    /// Add a browser console message to the output
    func addBrowserConsoleMessage(for cardID: UUID, level: String, message: String) {
        let source: OutputSource = switch level {
        case "warn": .browserWarn
        case "error": .browserError
        case "info": .browserInfo
        case "debug": .browserDebug
        default: .browserLog
        }

        let line = OutputLine(text: message, source: source, timestamp: Date())
        var currentLines = outputLines[cardID] ?? []
        currentLines.append(line)

        // Truncate if needed
        if currentLines.count > maxOutputLines {
            let truncatedCount = currentLines.count - maxOutputLines
            currentLines = Array(currentLines.suffix(maxOutputLines))
            let marker = OutputLine(text: "[...\(truncatedCount) lines truncated...]", source: .serverStdout)
            currentLines.insert(marker, at: 0)
        }

        outputLines[cardID] = currentLines
        scheduleUIUpdate(for: cardID)
    }

    /// Decode data to string with UTF-8 fallback to Latin1
    private func decodeOutput(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }

        if let str = String(data: data, encoding: .utf8) {
            return str
        }
        if let str = String(data: data, encoding: .isoLatin1) {
            return str
        }
        return "[Binary data: \(data.count) bytes]"
    }

    /// Append output to buffer with line-based truncation and throttled UI updates
    private func appendOutput(_ str: String, for cardID: UUID, isError: Bool) {
        var currentLines = outputLines[cardID] ?? []
        var buffers = partialLineBuffers[cardID] ?? (stdout: "", stderr: "")

        // Get the appropriate partial buffer
        let partialBuffer = isError ? buffers.stderr : buffers.stdout
        let fullText = partialBuffer + str

        // Split into lines
        var lines = fullText.components(separatedBy: "\n")

        // If string doesn't end with newline, keep last part as partial; otherwise clear buffer
        let newPartial = (!str.hasSuffix("\n") && !lines.isEmpty) ? lines.removeLast() : ""
        if isError {
            buffers.stderr = newPartial
        } else {
            buffers.stdout = newPartial
        }

        partialLineBuffers[cardID] = buffers

        // Create OutputLine objects for complete lines
        let timestamp = Date()
        let newLines = lines
            .filter { !$0.isEmpty }
            .map { OutputLine(text: $0, isError: isError, timestamp: timestamp) }

        currentLines.append(contentsOf: newLines)

        // Truncate to max lines
        if currentLines.count > maxOutputLines {
            let truncatedCount = currentLines.count - maxOutputLines
            currentLines = Array(currentLines.suffix(maxOutputLines))
            // Add truncation marker at the beginning
            let marker = OutputLine(text: "[...\(truncatedCount) lines truncated...]", isError: false, timestamp: timestamp)
            currentLines.insert(marker, at: 0)
        }

        outputLines[cardID] = currentLines
        scheduleUIUpdate(for: cardID)
    }

    /// Flush any remaining partial line buffers
    private func flushPartialBuffers(for cardID: UUID) {
        guard let buffers = partialLineBuffers[cardID] else { return }

        let timestamp = Date()
        var currentLines = outputLines[cardID] ?? []

        if !buffers.stdout.isEmpty {
            currentLines.append(OutputLine(text: buffers.stdout, isError: false, timestamp: timestamp))
        }
        if !buffers.stderr.isEmpty {
            currentLines.append(OutputLine(text: buffers.stderr, isError: true, timestamp: timestamp))
        }

        outputLines[cardID] = currentLines
        partialLineBuffers[cardID] = (stdout: "", stderr: "")
    }

    /// Throttled UI update via version increment
    private func scheduleUIUpdate(for cardID: UUID) {
        guard pendingUIUpdates[cardID] != true else { return }
        pendingUIUpdates[cardID] = true

        DispatchQueue.main.asyncAfter(deadline: .now() + uiUpdateInterval) { [weak self] in
            guard let self else { return }
            self.pendingUIUpdates[cardID] = false
            self.outputVersion[cardID, default: 0] += 1
        }
    }

    /// Force immediate UI update
    private func flushOutput(for cardID: UUID) {
        pendingUIUpdates[cardID] = false
        outputVersion[cardID, default: 0] += 1
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
        outputLines[cardID] = []
        partialLineBuffers[cardID] = (stdout: "", stderr: "")

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
        outputLines[cardID] = []
        partialLineBuffers[cardID] = (stdout: "", stderr: "")

        return try await runDevServerProcess(
            for: cardID,
            command: command,
            directory: directory
        )
    }

    /// Stop server for a specific card
    func stopServer(for cardID: UUID) {
        // Clean up pipe handlers first to prevent retain cycles
        if let pipe = stdoutPipes[cardID] {
            pipe.fileHandleForReading.readabilityHandler = nil
            stdoutPipes[cardID] = nil
        }
        if let pipe = stderrPipes[cardID] {
            pipe.fileHandleForReading.readabilityHandler = nil
            stderrPipes[cardID] = nil
        }

        // Kill the process and its children (process group)
        if let process = processes[cardID] {
            killProcessTree(process)
            processes[cardID] = nil
        }

        serverStates[cardID] = .idle
        outputLines[cardID] = nil
        outputVersion[cardID] = nil
        pendingUIUpdates[cardID] = nil
        partialLineBuffers[cardID] = nil
    }

    /// Stop all running servers
    func stopAllServers() {
        // Clean up all pipe handlers first
        for (_, pipe) in stdoutPipes {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
        for (_, pipe) in stderrPipes {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
        stdoutPipes.removeAll()
        stderrPipes.removeAll()

        // Kill all processes and their children
        for (cardID, process) in processes {
            killProcessTree(process)
            serverStates[cardID] = .idle
        }
        processes.removeAll()
        outputLines.removeAll()
        outputVersion.removeAll()
        pendingUIUpdates.removeAll()
        partialLineBuffers.removeAll()
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
            true
        case .idle, .runningSetup, .error, nil:
            false
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

                // Separate pipes for stdout and stderr
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                // Store references for cleanup (must be on main thread for thread safety)
                DispatchQueue.main.sync {
                    self.processes[cardID] = process
                    self.stdoutPipes[cardID] = stdoutPipe
                    self.stderrPipes[cardID] = stderrPipe
                }

                let group = DispatchGroup()
                group.enter()

                // Handler for stdout (normal output)
                stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let self else { return }
                    guard let str = self.decodeOutput(data) else { return }

                    DispatchQueue.main.async {
                        self.appendOutput(str, for: cardID, isError: false)
                        let newOutput = self.output(for: cardID)
                        self.serverStates[cardID] = stateBuilder(newOutput)
                    }
                }

                // Handler for stderr (error output)
                stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let self else { return }
                    guard let str = self.decodeOutput(data) else { return }

                    DispatchQueue.main.async {
                        self.appendOutput(str, for: cardID, isError: true)
                        let newOutput = self.output(for: cardID)
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
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    DispatchQueue.main.sync {
                        self.processes[cardID] = nil
                        self.stdoutPipes[cardID] = nil
                        self.stderrPipes[cardID] = nil
                        self.serverStates[cardID] = .error(message: error.localizedDescription)
                    }
                    continuation.resume(throwing: error)
                    return
                }

                let result = group.wait(timeout: .now() + timeout)

                // FIX: Read any remaining data before clearing handlers (race condition fix)
                let finalStdoutData = stdoutPipe.fileHandleForReading.availableData
                let finalStderrData = stderrPipe.fileHandleForReading.availableData

                // Clean up pipe handlers (must be on main thread for thread safety)
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                DispatchQueue.main.sync {
                    // Append final data if any
                    if !finalStdoutData.isEmpty, let str = self.decodeOutput(finalStdoutData) {
                        self.appendOutput(str, for: cardID, isError: false)
                    }
                    if !finalStderrData.isEmpty, let str = self.decodeOutput(finalStderrData) {
                        self.appendOutput(str, for: cardID, isError: true)
                    }

                    // Flush partial line buffers
                    self.flushPartialBuffers(for: cardID)

                    self.stdoutPipes[cardID] = nil
                    self.stderrPipes[cardID] = nil
                    self.processes[cardID] = nil
                    // Flush final output to UI
                    self.flushOutput(for: cardID)
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
                    // Read output on main thread for thread safety
                    var output = ""
                    DispatchQueue.main.sync {
                        output = self.output(for: cardID)
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

                // Separate pipes for stdout and stderr
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                // Store references for cleanup (must be on main thread for thread safety)
                DispatchQueue.main.sync {
                    self.processes[cardID] = process
                    self.stdoutPipes[cardID] = stdoutPipe
                    self.stderrPipes[cardID] = stderrPipe
                }

                // Helper to handle output and port detection
                let handleOutput: (String, Bool) -> Void = { str, isError in
                    DispatchQueue.main.async {
                        self.appendOutput(str, for: cardID, isError: isError)
                        let newOutput = self.output(for: cardID)

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

                // Handler for stdout (normal output)
                stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let self else { return }
                    guard let str = self.decodeOutput(data) else { return }
                    handleOutput(str, false)
                }

                // Handler for stderr (error output)
                stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let self else { return }
                    guard let str = self.decodeOutput(data) else { return }
                    handleOutput(str, true)
                }

                process.terminationHandler = { [weak self] _ in
                    guard let self else { return }

                    // FIX: Read any remaining data before clearing handlers (race condition fix)
                    let finalStdoutData = stdoutPipe.fileHandleForReading.availableData
                    let finalStderrData = stderrPipe.fileHandleForReading.availableData

                    // Clean up pipe handlers
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil

                    DispatchQueue.main.async {
                        // Append final data if any
                        if !finalStdoutData.isEmpty, let str = self.decodeOutput(finalStdoutData) {
                            self.appendOutput(str, for: cardID, isError: false)
                        }
                        if !finalStderrData.isEmpty, let str = self.decodeOutput(finalStderrData) {
                            self.appendOutput(str, for: cardID, isError: true)
                        }

                        // Flush partial line buffers
                        self.flushPartialBuffers(for: cardID)

                        self.stdoutPipes[cardID] = nil
                        self.stderrPipes[cardID] = nil
                        // Flush final output to UI
                        self.flushOutput(for: cardID)

                        if !state.portDetected && !state.isResumed {
                            state.isResumed = true
                            let output = self.output(for: cardID)
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
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    var shouldResume = false
                    DispatchQueue.main.sync {
                        self.processes[cardID] = nil
                        self.stdoutPipes[cardID] = nil
                        self.stderrPipes[cardID] = nil
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
                        let output = self.output(for: cardID)
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

    private static let compiledPortPatterns: [NSRegularExpression] = {
        let patterns = [
            #"(?:localhost|127\.0\.0\.1|0\.0\.0\.0):(\d+)"#,
            #"Local:\s+https?://[^:]+:(\d+)"#,
            #"ready.*(?:localhost|127\.0\.0\.1):(\d+)"#,
            #"https?://(?:localhost|127\.0\.0\.1):(\d+)"#,
            #"http://\[?::1\]?:(\d+)"#,
            #"listening on.*:(\d+)"#,
            #"started at.*:(\d+)"#
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
    }()

    /// Parse port from recent output only (last 2KB is enough for port detection)
    private static func parsePortFromOutput(_ output: String) -> Int? {
        // Only scan last 2KB - ports appear near when server starts
        let scanLimit = 2048
        let searchRange: String
        if output.count > scanLimit {
            let startIdx = output.index(output.endIndex, offsetBy: -scanLimit)
            searchRange = String(output[startIdx...])
        } else {
            searchRange = output
        }

        for regex in compiledPortPatterns {
            if let match = regex.firstMatch(in: searchRange, range: NSRange(searchRange.startIndex..., in: searchRange)),
               let portRange = Range(match.range(at: 1), in: searchRange),
               let port = Int(searchRange[portRange]),
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
