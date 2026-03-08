import Foundation

enum OutputSource: Equatable {
    case serverStdout
    case serverStderr
}

struct OutputLine: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let source: OutputSource
    let timestamp: Date

    var isError: Bool {
        source == .serverStderr
    }

    init(text: String, source: OutputSource, timestamp: Date = Date()) {
        self.text = text
        self.source = source
        self.timestamp = timestamp
    }

    init(text: String, isError: Bool, timestamp: Date = Date()) {
        self.text = text
        self.source = isError ? .serverStderr : .serverStdout
        self.timestamp = timestamp
    }
}

/// Manages dev server processes for cards.
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
    private var expectedTerminatedProcesses: Set<ObjectIdentifier> = []
    private var partialLineBuffers: [UUID: (stdout: String, stderr: String)] = [:]

    private let maxOutputLines = 1000
    private let uiUpdateInterval: TimeInterval = 0.15

    // MARK: - Public API

    func state(for cardID: UUID) -> ServerState {
        serverStates[cardID] ?? .idle
    }

    func output(for cardID: UUID) -> String {
        let lines = outputLines[cardID] ?? []
        return lines.map(\.text).joined(separator: "\n")
    }

    func outputLinesArray(for cardID: UUID) -> [OutputLine] {
        outputLines[cardID] ?? []
    }

    func runSetup(
        for cardID: UUID,
        command: String,
        directory: String
    ) async throws {
        stopAllServers()

        serverStates[cardID] = .runningSetup(output: "")
        outputLines[cardID] = []
        partialLineBuffers[cardID] = (stdout: "", stderr: "")

        try await runCommandToCompletion(
            for: cardID,
            command: command,
            directory: directory,
            stateBuilder: { output in .runningSetup(output: output) },
            timeout: 300
        )
    }

    func startDevServer(
        for cardID: UUID,
        command: String,
        directory: String
    ) async throws -> URL {
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

    func stopServer(for cardID: UUID) {
        if let pipe = stdoutPipes[cardID] {
            pipe.fileHandleForReading.readabilityHandler = nil
            stdoutPipes[cardID] = nil
        }
        if let pipe = stderrPipes[cardID] {
            pipe.fileHandleForReading.readabilityHandler = nil
            stderrPipes[cardID] = nil
        }

        if let process = processes[cardID] {
            expectedTerminatedProcesses.insert(ObjectIdentifier(process))
            killProcessTree(process)
            processes[cardID] = nil
        }

        serverStates[cardID] = .idle
        outputLines[cardID] = nil
        outputVersion[cardID] = nil
        pendingUIUpdates[cardID] = nil
        partialLineBuffers[cardID] = nil
    }

    func stopAllServers() {
        for (_, pipe) in stdoutPipes {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
        for (_, pipe) in stderrPipes {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
        stdoutPipes.removeAll()
        stderrPipes.removeAll()

        for (cardID, process) in processes {
            expectedTerminatedProcesses.insert(ObjectIdentifier(process))
            killProcessTree(process)
            serverStates[cardID] = .idle
        }
        processes.removeAll()
        outputLines.removeAll()
        outputVersion.removeAll()
        pendingUIUpdates.removeAll()
        partialLineBuffers.removeAll()
    }

    func isServerRunning(for cardID: UUID) -> Bool {
        switch serverStates[cardID] {
        case .ready, .startingServer, .detectingPort:
            true
        case .idle, .runningSetup, .error, nil:
            false
        }
    }

    // MARK: - Private

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

    private func appendOutput(_ str: String, for cardID: UUID, isError: Bool) {
        var currentLines = outputLines[cardID] ?? []
        var buffers = partialLineBuffers[cardID] ?? (stdout: "", stderr: "")

        let partialBuffer = isError ? buffers.stderr : buffers.stdout
        let fullText = partialBuffer + str
        var lines = fullText.components(separatedBy: "\n")

        let newPartial = (!str.hasSuffix("\n") && !lines.isEmpty) ? lines.removeLast() : ""
        if isError {
            buffers.stderr = newPartial
        } else {
            buffers.stdout = newPartial
        }
        partialLineBuffers[cardID] = buffers

        let timestamp = Date()
        let newLines = lines
            .filter { !$0.isEmpty }
            .map { OutputLine(text: $0, isError: isError, timestamp: timestamp) }

        currentLines.append(contentsOf: newLines)

        if currentLines.count > maxOutputLines {
            let truncatedCount = currentLines.count - maxOutputLines
            currentLines = Array(currentLines.suffix(maxOutputLines))
            let marker = OutputLine(
                text: "[...\(truncatedCount) lines truncated...]",
                isError: false,
                timestamp: timestamp
            )
            currentLines.insert(marker, at: 0)
        }

        outputLines[cardID] = currentLines
        scheduleUIUpdate(for: cardID)
    }

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

    private func scheduleUIUpdate(for cardID: UUID) {
        guard pendingUIUpdates[cardID] != true else { return }
        pendingUIUpdates[cardID] = true

        DispatchQueue.main.asyncAfter(deadline: .now() + uiUpdateInterval) { [weak self] in
            guard let self else { return }
            self.pendingUIUpdates[cardID] = false
            self.outputVersion[cardID, default: 0] += 1
        }
    }

    private func flushOutput(for cardID: UUID) {
        pendingUIUpdates[cardID] = false
        outputVersion[cardID, default: 0] += 1
    }

    private func killProcessTree(_ process: Process) {
        guard process.isRunning else { return }

        process.terminate()

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            if process.isRunning {
                let pid = process.processIdentifier
                kill(-pid, SIGKILL)
            }
        }
    }

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

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                DispatchQueue.main.sync {
                    self.processes[cardID] = process
                    self.stdoutPipes[cardID] = stdoutPipe
                    self.stderrPipes[cardID] = stderrPipe
                }

                let group = DispatchGroup()
                group.enter()

                stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let self else { return }
                    guard let str = self.decodeOutput(data) else { return }

                    DispatchQueue.main.async {
                        self.appendOutput(str, for: cardID, isError: false)
                        self.serverStates[cardID] = stateBuilder(self.output(for: cardID))
                    }
                }

                stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let self else { return }
                    guard let str = self.decodeOutput(data) else { return }

                    DispatchQueue.main.async {
                        self.appendOutput(str, for: cardID, isError: true)
                        self.serverStates[cardID] = stateBuilder(self.output(for: cardID))
                    }
                }

                process.terminationHandler = { _ in
                    group.leave()
                }

                do {
                    try process.run()
                } catch {
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
                let wasExpectedTermination = DispatchQueue.main.sync {
                    self.expectedTerminatedProcesses.remove(ObjectIdentifier(process)) != nil
                }
                let finalStdoutData = stdoutPipe.fileHandleForReading.availableData
                let finalStderrData = stderrPipe.fileHandleForReading.availableData

                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                if wasExpectedTermination {
                    DispatchQueue.main.sync {
                        self.stdoutPipes[cardID] = nil
                        self.stderrPipes[cardID] = nil
                        self.processes[cardID] = nil
                    }
                    continuation.resume(throwing: DevServerError.cancelled)
                    return
                }

                DispatchQueue.main.sync {
                    if !finalStdoutData.isEmpty, let str = self.decodeOutput(finalStdoutData) {
                        self.appendOutput(str, for: cardID, isError: false)
                    }
                    if !finalStderrData.isEmpty, let str = self.decodeOutput(finalStderrData) {
                        self.appendOutput(str, for: cardID, isError: true)
                    }

                    self.flushPartialBuffers(for: cardID)
                    self.stdoutPipes[cardID] = nil
                    self.stderrPipes[cardID] = nil
                    self.processes[cardID] = nil
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
        final class ContinuationState {
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

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                DispatchQueue.main.sync {
                    self.processes[cardID] = process
                    self.stdoutPipes[cardID] = stdoutPipe
                    self.stderrPipes[cardID] = stderrPipe
                }

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

                stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let self else { return }
                    guard let str = self.decodeOutput(data) else { return }
                    handleOutput(str, false)
                }

                stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let self else { return }
                    guard let str = self.decodeOutput(data) else { return }
                    handleOutput(str, true)
                }

                process.terminationHandler = { [weak self] _ in
                    guard let self else { return }

                    let finalStdoutData = stdoutPipe.fileHandleForReading.availableData
                    let finalStderrData = stderrPipe.fileHandleForReading.availableData

                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil

                    DispatchQueue.main.async {
                        let wasExpectedTermination =
                            self.expectedTerminatedProcesses.remove(ObjectIdentifier(process)) != nil

                        self.processes[cardID] = nil
                        self.stdoutPipes[cardID] = nil
                        self.stderrPipes[cardID] = nil

                        guard !wasExpectedTermination else { return }

                        if !finalStdoutData.isEmpty, let str = self.decodeOutput(finalStdoutData) {
                            self.appendOutput(str, for: cardID, isError: false)
                        }
                        if !finalStderrData.isEmpty, let str = self.decodeOutput(finalStderrData) {
                            self.appendOutput(str, for: cardID, isError: true)
                        }

                        self.flushPartialBuffers(for: cardID)
                        self.flushOutput(for: cardID)

                        let output = self.output(for: cardID)
                        self.serverStates[cardID] = .error(message: "Server stopped unexpectedly:\n\(output)")

                        if !state.isResumed {
                            state.isResumed = true
                            continuation.resume(throwing: DevServerError.serverCrashed(output))
                        }
                    }
                }

                do {
                    try process.run()
                } catch {
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

                DispatchQueue.global().asyncAfter(deadline: .now() + 30) { [weak self] in
                    guard let self, !state.isResumed else { return }
                    DispatchQueue.main.async {
                        guard !state.isResumed else { return }
                        state.isResumed = true
                        let output = self.output(for: cardID)
                        self.serverStates[cardID] = .error(message: "Could not detect server port:\n\(output)")

                        if let pipe = self.stdoutPipes[cardID] {
                            pipe.fileHandleForReading.readabilityHandler = nil
                            self.stdoutPipes[cardID] = nil
                        }
                        if let pipe = self.stderrPipes[cardID] {
                            pipe.fileHandleForReading.readabilityHandler = nil
                            self.stderrPipes[cardID] = nil
                        }
                        if let process = self.processes[cardID] {
                            self.expectedTerminatedProcesses.insert(ObjectIdentifier(process))
                            self.killProcessTree(process)
                            self.processes[cardID] = nil
                        }

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

    private static func parsePortFromOutput(_ output: String) -> Int? {
        let scanLimit = 2048
        let searchRange: String
        if output.count > scanLimit {
            let startIdx = output.index(output.endIndex, offsetBy: -scanLimit)
            searchRange = String(output[startIdx...])
        } else {
            searchRange = output
        }

        for regex in compiledPortPatterns {
            if let match = regex.firstMatch(
                in: searchRange,
                range: NSRange(searchRange.startIndex..., in: searchRange)
            ),
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
