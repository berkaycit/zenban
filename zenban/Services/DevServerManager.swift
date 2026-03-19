import Darwin
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

    init(text: String, isError: Bool, timestamp: Date = Date()) {
        self.text = text
        self.source = isError ? .serverStderr : .serverStdout
        self.timestamp = timestamp
    }
}

/// Manages dev server processes for cards.
@Observable
final class DevServerManager {
    private struct PersistedOwnedProcessGroup: Codable, Equatable {
        let processGroupID: pid_t
        let directory: String
    }

    private struct ProcessSnapshotEntry: Equatable {
        let pid: pid_t
        let processGroupID: pid_t
        let command: String
    }

    nonisolated private static let ownedProcessGroupsDefaultsKey = "zenban.devServer.ownedProcessGroups.v2"

    enum ServerState: Equatable {
        case idle
        case runningSetup
        case startingServer
        case detectingPort
        case ready(url: URL)
        case error(message: String)
    }

    private(set) var serverStates: [UUID: ServerState] = [:]
    private(set) var outputVersion: [UUID: Int] = [:]
    private var processes: [UUID: Process] = [:]
    private var processDirectories: [UUID: String] = [:]
    private var stdoutPipes: [UUID: Pipe] = [:]
    private var stderrPipes: [UUID: Pipe] = [:]
    private var outputLines: [UUID: [OutputLine]] = [:]
    private var pendingUIUpdates: [UUID: Bool] = [:]
    private var expectedTerminatedProcesses: Set<ObjectIdentifier> = []
    private var partialLineBuffers: [UUID: (stdout: String, stderr: String)] = [:]
    private var outputTails: [UUID: String] = [:]
    private var activeRequestIDs: [UUID: UUID] = [:]

    private let maxOutputLines = 1000
    private let outputTailLimit = 4096
    private let uiUpdateInterval: TimeInterval = 0.15

    init() {
        Self.reapPersistedOwnedProcessGroupsFromPreviousLaunch()
    }

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

    func beginRequest(for cardID: UUID) -> UUID {
        stopAllServers()
        let requestID = UUID()
        activeRequestIDs[cardID] = requestID
        return requestID
    }

    func runSetup(
        for cardID: UUID,
        command: String,
        directory: String,
        requestID: UUID
    ) async throws {
        guard isRequestCurrent(requestID, for: cardID) else {
            throw DevServerError.cancelled
        }

        prepareOutputState(for: cardID, state: .runningSetup)

        try await runCommandToCompletion(
            for: cardID,
            command: command,
            directory: directory,
            activeState: .runningSetup,
            timeout: 300,
            requestID: requestID
        )
    }

    func startDevServer(
        for cardID: UUID,
        command: String,
        directory: String,
        requestID: UUID
    ) async throws -> URL {
        guard isRequestCurrent(requestID, for: cardID) else {
            throw DevServerError.cancelled
        }

        prepareOutputState(for: cardID, state: .startingServer)

        return try await runDevServerProcess(
            for: cardID,
            command: command,
            directory: directory,
            requestID: requestID
        )
    }

    func stopServer(for cardID: UUID) {
        activeRequestIDs.removeValue(forKey: cardID)

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
            terminateOwnedProcessGroup(for: process, directory: processDirectories[cardID])
            processes[cardID] = nil
        }
        processDirectories[cardID] = nil

        serverStates[cardID] = .idle
        outputLines[cardID] = nil
        outputVersion[cardID] = nil
        pendingUIUpdates[cardID] = nil
        partialLineBuffers[cardID] = nil
        outputTails[cardID] = nil
    }

    func stopRequest(for cardID: UUID, requestID: UUID) {
        guard isRequestCurrent(requestID, for: cardID) else { return }
        stopServer(for: cardID)
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
            terminateOwnedProcessGroup(for: process, directory: processDirectories[cardID])
            serverStates[cardID] = .idle
        }
        processes.removeAll()
        processDirectories.removeAll()
        outputLines.removeAll()
        outputVersion.removeAll()
        pendingUIUpdates.removeAll()
        partialLineBuffers.removeAll()
        outputTails.removeAll()
        activeRequestIDs.removeAll()
    }

    func shutdownForAppTermination() {
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
            terminateOwnedProcessGroupAndWait(for: process, directory: processDirectories[cardID])
            serverStates[cardID] = .idle
        }
        processes.removeAll()
        processDirectories.removeAll()
        outputLines.removeAll()
        outputVersion.removeAll()
        pendingUIUpdates.removeAll()
        partialLineBuffers.removeAll()
        outputTails.removeAll()
        activeRequestIDs.removeAll()
        Self.reapPersistedOwnedProcessGroupsFromPreviousLaunch()
    }

    // MARK: - Private

    private func prepareOutputState(for cardID: UUID, state: ServerState) {
        serverStates[cardID] = state
        outputLines[cardID] = []
        outputVersion[cardID] = 0
        pendingUIUpdates[cardID] = false
        partialLineBuffers[cardID] = (stdout: "", stderr: "")
        outputTails[cardID] = ""
    }

    private func isRequestCurrent(_ requestID: UUID, for cardID: UUID) -> Bool {
        activeRequestIDs[cardID] == requestID
    }

    private func registerProcessIfCurrent(
        _ process: Process,
        stdoutPipe: Pipe,
        stderrPipe: Pipe,
        directory: String,
        for cardID: UUID,
        requestID: UUID
    ) -> Bool {
        guard isRequestCurrent(requestID, for: cardID) else { return false }
        processes[cardID] = process
        processDirectories[cardID] = directory
        stdoutPipes[cardID] = stdoutPipe
        stderrPipes[cardID] = stderrPipe
        return true
    }

    private func clearRegisteredResourcesIfMatching(
        process: Process? = nil,
        stdoutPipe: Pipe? = nil,
        stderrPipe: Pipe? = nil,
        for cardID: UUID
    ) {
        if let process, processes[cardID] === process {
            processes[cardID] = nil
            processDirectories[cardID] = nil
        }
        if let stdoutPipe, stdoutPipes[cardID] === stdoutPipe {
            stdoutPipes[cardID] = nil
        }
        if let stderrPipe, stderrPipes[cardID] === stderrPipe {
            stderrPipes[cardID] = nil
        }
    }

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

    private func appendOutput(_ str: String, for cardID: UUID, isError: Bool, requestID: UUID? = nil) {
        if let requestID, !isRequestCurrent(requestID, for: cardID) {
            return
        }

        appendToOutputTail(str, for: cardID)

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
        scheduleUIUpdate(for: cardID, requestID: requestID)
    }

    private func appendToOutputTail(_ str: String, for cardID: UUID) {
        let updatedTail = (outputTails[cardID] ?? "") + str
        if updatedTail.count > outputTailLimit {
            outputTails[cardID] = String(updatedTail.suffix(outputTailLimit))
        } else {
            outputTails[cardID] = updatedTail
        }
    }

    private func flushPartialBuffers(for cardID: UUID, requestID: UUID? = nil) {
        if let requestID, !isRequestCurrent(requestID, for: cardID) {
            return
        }

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

    private func scheduleUIUpdate(for cardID: UUID, requestID: UUID? = nil) {
        guard pendingUIUpdates[cardID] != true else { return }
        pendingUIUpdates[cardID] = true

        DispatchQueue.main.asyncAfter(deadline: .now() + uiUpdateInterval) { [weak self] in
            guard let self else { return }
            if let requestID, !self.isRequestCurrent(requestID, for: cardID) {
                self.pendingUIUpdates[cardID] = false
                return
            }
            self.pendingUIUpdates[cardID] = false
            self.outputVersion[cardID, default: 0] += 1
        }
    }

    private func flushOutput(for cardID: UUID, requestID: UUID? = nil) {
        if let requestID, !isRequestCurrent(requestID, for: cardID) {
            return
        }
        pendingUIUpdates[cardID] = false
        outputVersion[cardID, default: 0] += 1
    }

    private func terminateOwnedProcessGroup(for process: Process, directory: String?) {
        let processGroupID = Self.processGroupID(for: process.processIdentifier) ?? process.processIdentifier
        guard let group = Self.ownedProcessGroup(processGroupID: processGroupID, directory: directory) else {
            return
        }

        Self.send(signal: SIGTERM, toProcessGroups: [group.processGroupID])
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            let snapshot = Self.processSnapshot()
            guard !Self.processEntries(inProcessGroup: group.processGroupID, snapshot: snapshot).isEmpty else {
                return
            }
            Self.send(signal: SIGKILL, toProcessGroups: [group.processGroupID])
        }
    }

    private func terminateOwnedProcessGroupAndWait(for process: Process, directory: String?) {
        let processGroupID = Self.processGroupID(for: process.processIdentifier) ?? process.processIdentifier
        guard let group = Self.ownedProcessGroup(processGroupID: processGroupID, directory: directory) else {
            return
        }

        if Self.terminateOwnedProcessGroups([group], requireDirectoryEvidence: false) {
            Self.removePersistedOwnedProcessGroup(processGroupID: group.processGroupID)
        }
    }

    nonisolated private static func ownedProcessGroup(
        processGroupID: pid_t,
        directory: String?
    ) -> PersistedOwnedProcessGroup? {
        guard processGroupID > 1,
              let directory,
              !directory.isEmpty else {
            return nil
        }
        return PersistedOwnedProcessGroup(
            processGroupID: processGroupID,
            directory: normalizedDirectory(directory)
        )
    }

    nonisolated private static func processSnapshot() -> [ProcessSnapshotEntry] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,pgid=,command="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8) else {
            return []
        }

        return output
            .split(separator: "\n")
            .compactMap { line in
                let parts = line.split(
                    maxSplits: 2,
                    omittingEmptySubsequences: true,
                    whereSeparator: \.isWhitespace
                )
                guard parts.count == 3,
                      let pid = Int32(parts[0]),
                      let processGroupID = Int32(parts[1]) else {
                    return nil
                }
                return ProcessSnapshotEntry(
                    pid: pid,
                    processGroupID: processGroupID,
                    command: String(parts[2])
                )
            }
    }

    nonisolated private static func processEntries(
        inProcessGroup processGroupID: pid_t,
        snapshot: [ProcessSnapshotEntry]? = nil
    ) -> [ProcessSnapshotEntry] {
        let source = snapshot ?? processSnapshot()
        return source
            .filter { $0.processGroupID == processGroupID }
            .sorted { $0.pid < $1.pid }
    }

    nonisolated private static func groupHasDirectoryEvidence(
        _ group: PersistedOwnedProcessGroup,
        snapshot: [ProcessSnapshotEntry]
    ) -> Bool {
        processEntries(inProcessGroup: group.processGroupID, snapshot: snapshot).contains { entry in
            commandBelongsToDirectory(entry.command, directory: group.directory)
                || currentWorkingDirectory(for: entry.pid).map {
                    directoriesMatch($0, group.directory)
                } == true
        }
    }

    nonisolated private static func currentWorkingDirectory(for pid: pid_t) -> String? {
        guard pid > 1 else { return nil }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-a", "-p", String(pid), "-d", "cwd", "-Fn"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8) else {
            return nil
        }

        for line in output.split(separator: "\n") where line.first == "n" {
            return normalizedDirectory(String(line.dropFirst()))
        }
        return nil
    }

    nonisolated private static func normalizedDirectory(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    nonisolated private static func directoriesMatch(_ lhs: String, _ rhs: String) -> Bool {
        normalizedDirectory(lhs) == normalizedDirectory(rhs)
    }

    nonisolated private static func send(signal: Int32, toProcessGroups processGroupIDs: [pid_t]) {
        let currentGroup = Darwin.getpgrp()
        for processGroupID in Set(processGroupIDs) where processGroupID > 1 && processGroupID != currentGroup {
            _ = Darwin.kill(-processGroupID, signal)
        }
    }

    private func runCommandToCompletion(
        for cardID: UUID,
        command: String,
        directory: String,
        activeState: ServerState,
        timeout: TimeInterval,
        requestID: UUID
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: DevServerError.cancelled)
                    return
                }

                let isCurrentRequest = DispatchQueue.main.sync {
                    self.isRequestCurrent(requestID, for: cardID)
                }
                guard isCurrentRequest else {
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

                let didRegisterProcess = DispatchQueue.main.sync {
                    self.registerProcessIfCurrent(
                        process,
                        stdoutPipe: stdoutPipe,
                        stderrPipe: stderrPipe,
                        directory: directory,
                        for: cardID,
                        requestID: requestID
                    )
                }
                guard didRegisterProcess else {
                    continuation.resume(throwing: DevServerError.cancelled)
                    return
                }

                let group = DispatchGroup()
                group.enter()

                stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let self else { return }
                    guard let str = self.decodeOutput(data) else { return }

                    DispatchQueue.main.async {
                        guard self.isRequestCurrent(requestID, for: cardID) else { return }
                        self.appendOutput(str, for: cardID, isError: false, requestID: requestID)
                        self.serverStates[cardID] = activeState
                    }
                }

                stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let self else { return }
                    guard let str = self.decodeOutput(data) else { return }

                    DispatchQueue.main.async {
                        guard self.isRequestCurrent(requestID, for: cardID) else { return }
                        self.appendOutput(str, for: cardID, isError: true, requestID: requestID)
                        self.serverStates[cardID] = activeState
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
                        self.clearRegisteredResourcesIfMatching(
                            process: process,
                            stdoutPipe: stdoutPipe,
                            stderrPipe: stderrPipe,
                            for: cardID
                        )
                        if self.isRequestCurrent(requestID, for: cardID) {
                            self.serverStates[cardID] = .error(message: error.localizedDescription)
                        }
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
                        self.clearRegisteredResourcesIfMatching(
                            process: process,
                            stdoutPipe: stdoutPipe,
                            stderrPipe: stderrPipe,
                            for: cardID
                        )
                    }
                    continuation.resume(throwing: DevServerError.cancelled)
                    return
                }

                let isStillCurrentRequest = DispatchQueue.main.sync {
                    let isCurrent = self.isRequestCurrent(requestID, for: cardID)
                    if isCurrent {
                        if !finalStdoutData.isEmpty, let str = self.decodeOutput(finalStdoutData) {
                            self.appendOutput(str, for: cardID, isError: false, requestID: requestID)
                        }
                        if !finalStderrData.isEmpty, let str = self.decodeOutput(finalStderrData) {
                            self.appendOutput(str, for: cardID, isError: true, requestID: requestID)
                        }

                        self.flushPartialBuffers(for: cardID, requestID: requestID)
                        self.flushOutput(for: cardID, requestID: requestID)
                    }

                    self.clearRegisteredResourcesIfMatching(
                        process: process,
                        stdoutPipe: stdoutPipe,
                        stderrPipe: stderrPipe,
                        for: cardID
                    )
                    return isCurrent
                }
                guard isStillCurrentRequest else {
                    continuation.resume(throwing: DevServerError.cancelled)
                    return
                }

                if result == .timedOut {
                    self.terminateOwnedProcessGroup(for: process, directory: directory)
                    DispatchQueue.main.async {
                        guard self.isRequestCurrent(requestID, for: cardID) else { return }
                        self.serverStates[cardID] = .error(message: "Setup timed out after \(Int(timeout)) seconds")
                    }
                    continuation.resume(throwing: DevServerError.timeout)
                    return
                }

                if process.terminationStatus != 0 {
                    var output = ""
                    DispatchQueue.main.sync {
                        output = self.output(for: cardID)
                        if self.isRequestCurrent(requestID, for: cardID) {
                            self.serverStates[cardID] = .error(message: "Setup failed:\n\(output)")
                        }
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
        directory: String,
        requestID: UUID
    ) async throws -> URL {
        final class ContinuationState {
            var isResumed = false
            var portDetected = false
            var launchGeneration = 0
            var didAttemptStaleListenerRecovery = false
            var didAttemptPortOverride = false
        }
        let state = ContinuationState()

        return try await withCheckedThrowingContinuation { continuation in
            func launchAttempt(using launchCommand: String) {
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard let self else {
                        if !state.isResumed {
                            state.isResumed = true
                            continuation.resume(throwing: DevServerError.cancelled)
                        }
                        return
                    }

                    let generation = DispatchQueue.main.sync { () -> Int? in
                        guard self.isRequestCurrent(requestID, for: cardID) else { return nil }
                        state.launchGeneration += 1
                        state.portDetected = false
                        return state.launchGeneration
                    }
                    guard let generation else {
                        if !state.isResumed {
                            state.isResumed = true
                            continuation.resume(throwing: DevServerError.cancelled)
                        }
                        return
                    }

                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                    process.arguments = ["-c", launchCommand]
                    process.currentDirectoryURL = URL(fileURLWithPath: directory)
                    process.environment = ProcessEnvironment.buildWithNodeSupport()

                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe

                    let didRegisterProcess = DispatchQueue.main.sync {
                        self.registerProcessIfCurrent(
                            process,
                            stdoutPipe: stdoutPipe,
                            stderrPipe: stderrPipe,
                            directory: directory,
                            for: cardID,
                            requestID: requestID
                        )
                    }
                    guard didRegisterProcess else {
                        if !state.isResumed {
                            state.isResumed = true
                            continuation.resume(throwing: DevServerError.cancelled)
                        }
                        return
                    }

                    let handleOutput: (String, Bool) -> Void = { str, isError in
                        DispatchQueue.main.async {
                            guard state.launchGeneration == generation else { return }
                            guard self.isRequestCurrent(requestID, for: cardID) else { return }
                            self.appendOutput(str, for: cardID, isError: isError, requestID: requestID)

                            if !state.portDetected && !state.isResumed {
                                self.serverStates[cardID] = .detectingPort

                                if let port = Self.parsePortFromOutput(self.outputTails[cardID] ?? "") {
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
                        let processGroupID =
                            Self.processGroupID(for: process.processIdentifier) ?? process.processIdentifier
                        Self.prunePersistedOwnedProcessGroup(processGroupID: processGroupID)

                        let finalStdoutData = stdoutPipe.fileHandleForReading.availableData
                        let finalStderrData = stderrPipe.fileHandleForReading.availableData

                        stdoutPipe.fileHandleForReading.readabilityHandler = nil
                        stderrPipe.fileHandleForReading.readabilityHandler = nil

                        DispatchQueue.main.async {
                            let wasExpectedTermination =
                                self.expectedTerminatedProcesses.remove(ObjectIdentifier(process)) != nil

                            self.clearRegisteredResourcesIfMatching(
                                process: process,
                                stdoutPipe: stdoutPipe,
                                stderrPipe: stderrPipe,
                                for: cardID
                            )

                            guard state.launchGeneration == generation else { return }

                            guard self.isRequestCurrent(requestID, for: cardID) else {
                                if !state.isResumed {
                                    state.isResumed = true
                                    continuation.resume(throwing: DevServerError.cancelled)
                                }
                                return
                            }

                            guard !wasExpectedTermination else {
                                if !state.isResumed {
                                    state.isResumed = true
                                    continuation.resume(throwing: DevServerError.cancelled)
                                }
                                return
                            }

                            if !finalStdoutData.isEmpty, let str = self.decodeOutput(finalStdoutData) {
                                self.appendOutput(str, for: cardID, isError: false, requestID: requestID)
                            }
                            if !finalStderrData.isEmpty, let str = self.decodeOutput(finalStderrData) {
                                self.appendOutput(str, for: cardID, isError: true, requestID: requestID)
                            }

                            self.flushPartialBuffers(for: cardID, requestID: requestID)
                            self.flushOutput(for: cardID, requestID: requestID)

                            let output = self.output(for: cardID)
                            if !state.portDetected,
                               let conflictPort = Self.parsePortConflictPort(output) {
                                DispatchQueue.global(qos: .userInitiated).async {
                                    let recovered =
                                        !state.didAttemptStaleListenerRecovery &&
                                        Self.reclaimPortConflictIfSafe(
                                            output: output,
                                            directory: directory,
                                            excluding: [process.processIdentifier]
                                        )

                                    let alternateCommand =
                                        !recovered && !state.didAttemptPortOverride
                                        ? Self.commandWithPortOverrideIfSupported(
                                            command: launchCommand,
                                            output: output,
                                            conflictingPort: conflictPort
                                        )
                                        : nil

                                    DispatchQueue.main.async {
                                        guard state.launchGeneration == generation else { return }
                                        guard !state.isResumed else { return }
                                        guard self.isRequestCurrent(requestID, for: cardID) else {
                                            if !state.isResumed {
                                                state.isResumed = true
                                                continuation.resume(throwing: DevServerError.cancelled)
                                            }
                                            return
                                        }

                                        if recovered {
                                            state.didAttemptStaleListenerRecovery = true
                                            self.partialLineBuffers[cardID] = (stdout: "", stderr: "")
                                            self.outputTails[cardID] = ""
                                            self.appendOutput(
                                                "[Zenban] Detected a stale listener from this worktree. Retrying once.\n",
                                                for: cardID,
                                                isError: false,
                                                requestID: requestID
                                            )
                                            self.serverStates[cardID] = .startingServer
                                            launchAttempt(using: launchCommand)
                                            return
                                        }

                                        if let alternateCommand {
                                            state.didAttemptPortOverride = true
                                            self.partialLineBuffers[cardID] = (stdout: "", stderr: "")
                                            self.outputTails[cardID] = ""
                                            self.appendOutput(
                                                "[Zenban] Port \(conflictPort) is busy. Retrying on port \(alternateCommand.port).\n",
                                                for: cardID,
                                                isError: false,
                                                requestID: requestID
                                            )
                                            self.serverStates[cardID] = .startingServer
                                            launchAttempt(using: alternateCommand.command)
                                            return
                                        }

                                        self.serverStates[cardID] = .error(message: Self.buildServerCrashMessage(output))

                                        if !state.isResumed {
                                            state.isResumed = true
                                            continuation.resume(throwing: DevServerError.serverCrashed(output))
                                        }
                                    }
                                }
                                return
                            }

                            self.serverStates[cardID] = .error(message: Self.buildServerCrashMessage(output))

                            if !state.isResumed {
                                state.isResumed = true
                                continuation.resume(throwing: DevServerError.serverCrashed(output))
                            }
                        }
                    }

                    do {
                        try process.run()
                        Self.persistOwnedProcessGroup(
                            processGroupID: Self.processGroupID(for: process.processIdentifier) ?? process.processIdentifier,
                            directory: directory
                        )
                    } catch {
                        stdoutPipe.fileHandleForReading.readabilityHandler = nil
                        stderrPipe.fileHandleForReading.readabilityHandler = nil
                        var shouldResume = false
                        DispatchQueue.main.sync {
                            self.clearRegisteredResourcesIfMatching(
                                process: process,
                                stdoutPipe: stdoutPipe,
                                stderrPipe: stderrPipe,
                                for: cardID
                            )
                            guard state.launchGeneration == generation else { return }
                            if self.isRequestCurrent(requestID, for: cardID), !state.isResumed {
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
                            guard state.launchGeneration == generation else { return }
                            guard !state.isResumed else { return }
                            guard self.isRequestCurrent(requestID, for: cardID) else {
                                state.isResumed = true
                                continuation.resume(throwing: DevServerError.cancelled)
                                return
                            }
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
                                self.terminateOwnedProcessGroup(for: process, directory: directory)
                                self.processes[cardID] = nil
                                self.processDirectories[cardID] = nil
                            }

                            continuation.resume(throwing: DevServerError.portDetectionTimeout)
                        }
                    }
                }
            }

            launchAttempt(using: command)
        }
    }

    // MARK: - Port Detection

    nonisolated private static let compiledPortPatterns: [NSRegularExpression] = {
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

    nonisolated private static let compiledPortConflictPatterns: [NSRegularExpression] = {
        let patterns = [
            #"EADDRINUSE:[^\n]*:(\d+)"#,
            #"address already in use[^\n]*:(\d+)"#
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

    nonisolated static func parsePortConflictPort(_ output: String) -> Int? {
        for regex in compiledPortConflictPatterns {
            if let match = regex.firstMatch(
                in: output,
                range: NSRange(output.startIndex..., in: output)
            ),
               let portRange = Range(match.range(at: 1), in: output),
               let port = Int(output[portRange]),
               port > 0 && port < 65536 {
                return port
            }
        }
        return nil
    }

    nonisolated static func commandBelongsToDirectory(_ command: String, directory: String) -> Bool {
        command.contains(normalizedDirectory(directory))
    }

    nonisolated static func commandWithPortOverrideIfSupported(
        command: String,
        output: String,
        conflictingPort: Int
    ) -> (command: String, port: Int)? {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else { return nil }
        guard !commandHasExplicitPortFlag(trimmedCommand) else { return nil }
        guard supportsCLIStylePortOverride(command: trimmedCommand, output: output) else { return nil }
        guard let port = fallbackPortForConflict(avoiding: conflictingPort) else { return nil }

        let overrideSuffix = scriptRunnerNeedsForwardedArguments(trimmedCommand)
            ? " -- --port \(port)"
            : " --port \(port)"
        return ("\(trimmedCommand)\(overrideSuffix)", port)
    }

    nonisolated private static func buildServerCrashMessage(_ output: String) -> String {
        if let port = parsePortConflictPort(output) {
            return "Port \(port) is already in use by another process.\n\n\(output)"
        }
        return "Server stopped unexpectedly:\n\(output)"
    }

    nonisolated private static func commandHasExplicitPortFlag(_ command: String) -> Bool {
        let patterns = [
            #"(?<!\S)--port(?:=|\s+)\d+\b"#,
            #"(?<!\S)-p(?:=|\s+)\d+\b"#,
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            if regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) != nil {
                return true
            }
        }
        return false
    }

    nonisolated private static func supportsCLIStylePortOverride(command: String, output: String) -> Bool {
        let normalizedCommand = command.lowercased()
        let normalizedOutput = output.lowercased()

        return normalizedOutput.contains("@smoud/playable-scripts")
            || normalizedOutput.contains("webpack-dev-server")
            || normalizedCommand.contains("playable-scripts")
            || normalizedCommand.contains("vite")
            || normalizedCommand.contains("next dev")
            || normalizedCommand.contains("webpack serve")
            || normalizedCommand.contains("webpack-dev-server")
    }

    nonisolated private static func scriptRunnerNeedsForwardedArguments(_ command: String) -> Bool {
        guard let regex = try? NSRegularExpression(
            pattern: #"(^|\s)(npm|pnpm|bun)(\s+run)?\s+\S+"#,
            options: [.caseInsensitive]
        ) else {
            return false
        }
        return regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) != nil
    }

    nonisolated private static func fallbackPortForConflict(avoiding conflictingPort: Int) -> Int? {
        let defaults = UserDefaults.standard
        let storedBase = defaults.integer(forKey: "cmuxPortBase")
        let storedRange = defaults.integer(forKey: "cmuxPortRange")
        let base = storedBase > 0 ? storedBase : 9100
        let rangeSize = storedRange > 0 ? storedRange : 10
        let rangeUpperBound = min(base + rangeSize, 65_536)

        if base < rangeUpperBound {
            for candidate in base..<rangeUpperBound where candidate != conflictingPort {
                if canBindTCPPort(candidate) {
                    return candidate
                }
            }
        }

        return ephemeralTCPPort(excluding: [conflictingPort])
    }

    nonisolated private static func canBindTCPPort(_ port: Int) -> Bool {
        guard port > 0 && port < 65_536 else { return false }
        return temporarilyBoundTCPPort(preferredPort: port) == port
    }

    nonisolated private static func ephemeralTCPPort(excluding excludedPorts: Set<Int>) -> Int? {
        for _ in 0..<8 {
            guard let port = temporarilyBoundTCPPort(preferredPort: 0) else { return nil }
            if !excludedPorts.contains(port) {
                return port
            }
        }
        return nil
    }

    nonisolated private static func temporarilyBoundTCPPort(preferredPort: Int) -> Int? {
        if let port = temporarilyBoundTCPPort(preferredPort: preferredPort, family: AF_INET6) {
            return port
        }
        return temporarilyBoundTCPPort(preferredPort: preferredPort, family: AF_INET)
    }

    nonisolated private static func temporarilyBoundTCPPort(
        preferredPort: Int,
        family: Int32
    ) -> Int? {
        let descriptor = socket(family, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        switch family {
        case AF_INET6:
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.stride)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = in_port_t(UInt16(preferredPort).bigEndian)
            address.sin6_addr = in6addr_any

            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPointer in
                    bind(descriptor, sockPointer, socklen_t(MemoryLayout<sockaddr_in6>.stride))
                }
            }
            guard bound == 0 else { return nil }

            var resolvedAddress = sockaddr_in6()
            var addressLength = socklen_t(MemoryLayout<sockaddr_in6>.stride)
            let resolved = withUnsafeMutablePointer(to: &resolvedAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPointer in
                    getsockname(descriptor, sockPointer, &addressLength)
                }
            }
            guard resolved == 0 else { return nil }
            return Int(UInt16(bigEndian: resolvedAddress.sin6_port))

        case AF_INET:
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(UInt16(preferredPort).bigEndian)
            address.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)

            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPointer in
                    bind(descriptor, sockPointer, socklen_t(MemoryLayout<sockaddr_in>.stride))
                }
            }
            guard bound == 0 else { return nil }

            var resolvedAddress = sockaddr_in()
            var addressLength = socklen_t(MemoryLayout<sockaddr_in>.stride)
            let resolved = withUnsafeMutablePointer(to: &resolvedAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPointer in
                    getsockname(descriptor, sockPointer, &addressLength)
                }
            }
            guard resolved == 0 else { return nil }
            return Int(UInt16(bigEndian: resolvedAddress.sin_port))

        default:
            return nil
        }
    }

    nonisolated private static func reclaimPortConflictIfSafe(
        output: String,
        directory: String,
        excluding excludedPIDs: Set<pid_t>
    ) -> Bool {
        guard let port = parsePortConflictPort(output) else { return false }

        let listenerPIDs = listeningPIDs(on: port).subtracting(excludedPIDs)
        guard !listenerPIDs.isEmpty else { return false }

        let snapshot = processSnapshot()
        let groups = Array(
            Set(
                listenerPIDs.compactMap { pid in
                    snapshot.first(where: { $0.pid == pid })?.processGroupID
                        ?? processGroupID(for: pid)
                }
            )
        ).sorted()
        guard !groups.isEmpty else { return false }

        let ownedGroups = groups.compactMap {
            ownedProcessGroup(processGroupID: $0, directory: directory)
        }
        guard ownedGroups.count == groups.count else { return false }
        guard ownedGroups.allSatisfy({ groupHasDirectoryEvidence($0, snapshot: snapshot) }) else {
            return false
        }
        guard terminateProcessGroups(groups) else { return false }
        return listeningPIDs(on: port).subtracting(excludedPIDs).isEmpty
    }

    nonisolated private static func listeningPIDs(on port: Int) -> Set<pid_t> {
        guard port > 0 && port < 65536 else { return [] }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fp"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else { return [] }

        return Set(
            output
                .split(separator: "\n")
                .compactMap { line in
                    guard line.first == "p" else { return nil }
                    return Int32(String(line.dropFirst()))
                }
        )
    }

    nonisolated private static func processGroupID(for pid: pid_t) -> pid_t? {
        guard pid > 1 else { return nil }
        let groupID = getpgid(pid)
        return groupID > 1 ? groupID : nil
    }

    nonisolated static func terminateProcessGroups(_ processGroupIDs: [pid_t]) -> Bool {
        let groups = Array(
            Set(processGroupIDs.filter { $0 > 1 && $0 != Darwin.getpgrp() })
        ).sorted()
        guard !groups.isEmpty else { return false }

        send(signal: SIGTERM, toProcessGroups: groups)

        let killDeadline = Date().addingTimeInterval(0.3)
        let deadline = Date().addingTimeInterval(1.5)
        var sentSIGKILL = false

        while Date() < deadline {
            let snapshot = processSnapshot()
            let remaining = groups.filter { !processEntries(inProcessGroup: $0, snapshot: snapshot).isEmpty }
            if remaining.isEmpty {
                return true
            }
            if !sentSIGKILL && Date() >= killDeadline {
                send(signal: SIGKILL, toProcessGroups: remaining)
                sentSIGKILL = true
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        let snapshot = processSnapshot()
        return groups.allSatisfy { processEntries(inProcessGroup: $0, snapshot: snapshot).isEmpty }
    }

    nonisolated private static func terminateOwnedProcessGroups(
        _ groups: [PersistedOwnedProcessGroup],
        requireDirectoryEvidence: Bool
    ) -> Bool {
        let snapshot = processSnapshot()
        let processGroupIDs: [pid_t] = groups.compactMap { group -> pid_t? in
            guard !processEntries(inProcessGroup: group.processGroupID, snapshot: snapshot).isEmpty else {
                return nil
            }
            if requireDirectoryEvidence && !groupHasDirectoryEvidence(group, snapshot: snapshot) {
                return nil
            }
            return group.processGroupID
        }
        guard !processGroupIDs.isEmpty else { return false }
        return terminateProcessGroups(processGroupIDs)
    }

    nonisolated private static func persistOwnedProcessGroup(
        processGroupID: pid_t,
        directory: String
    ) {
        guard let group = ownedProcessGroup(processGroupID: processGroupID, directory: directory) else {
            return
        }

        var groups = loadPersistedOwnedProcessGroups()
        groups.removeAll { $0.processGroupID == group.processGroupID }
        groups.append(group)
        savePersistedOwnedProcessGroups(groups)
    }

    nonisolated private static func removePersistedOwnedProcessGroup(processGroupID: pid_t) {
        guard processGroupID > 1 else { return }
        var groups = loadPersistedOwnedProcessGroups()
        let previousCount = groups.count
        groups.removeAll { $0.processGroupID == processGroupID }
        guard groups.count != previousCount else { return }
        savePersistedOwnedProcessGroups(groups)
    }

    nonisolated private static func prunePersistedOwnedProcessGroup(processGroupID: pid_t) {
        guard processGroupID > 1 else { return }
        var groups = loadPersistedOwnedProcessGroups()
        guard let group = groups.first(where: { $0.processGroupID == processGroupID }) else { return }
        let snapshot = processSnapshot()
        guard !processEntries(inProcessGroup: group.processGroupID, snapshot: snapshot).isEmpty,
              groupHasDirectoryEvidence(group, snapshot: snapshot) else {
            groups.removeAll { $0.processGroupID == processGroupID }
            savePersistedOwnedProcessGroups(groups)
            return
        }
    }

    nonisolated private static func loadPersistedOwnedProcessGroups() -> [PersistedOwnedProcessGroup] {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: ownedProcessGroupsDefaultsKey),
              let groups = try? JSONDecoder().decode([PersistedOwnedProcessGroup].self, from: data) else {
            return []
        }
        return groups
    }

    nonisolated private static func savePersistedOwnedProcessGroups(_ groups: [PersistedOwnedProcessGroup]) {
        let defaults = UserDefaults.standard
        if groups.isEmpty {
            defaults.removeObject(forKey: ownedProcessGroupsDefaultsKey)
            return
        }
        guard let data = try? JSONEncoder().encode(groups) else { return }
        defaults.set(data, forKey: ownedProcessGroupsDefaultsKey)
    }

    nonisolated private static func reapPersistedOwnedProcessGroupsFromPreviousLaunch() {
        let groups = loadPersistedOwnedProcessGroups()
        guard !groups.isEmpty else { return }

        let snapshot = processSnapshot()
        var survivingGroups: [PersistedOwnedProcessGroup] = []

        for group in groups {
            guard !processEntries(inProcessGroup: group.processGroupID, snapshot: snapshot).isEmpty,
                  groupHasDirectoryEvidence(group, snapshot: snapshot) else {
                continue
            }
            if !terminateProcessGroups([group.processGroupID]) {
                survivingGroups.append(group)
            }
        }

        savePersistedOwnedProcessGroups(survivingGroups)
    }
}

// MARK: - Errors

enum DevServerError: LocalizedError {
    case cancelled
    case timeout
    case setupFailed(String)
    case serverCrashed(String)
    case portDetectionTimeout

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
        }
    }
}
