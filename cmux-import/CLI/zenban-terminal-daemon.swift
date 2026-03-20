import Darwin
import Foundation

private var daemonDebugLogPath = "/tmp/zenban-terminal-runtime.log"

private func setDaemonDebugLogPath(socketPath: String) {
    let directory = (socketPath as NSString).deletingLastPathComponent
    guard !directory.isEmpty else { return }
    daemonDebugLogPath = (directory as NSString).appendingPathComponent("terminal-runtime.log")
}

private func daemonDebugLog(_ message: String) {
    let line = "[daemon] \(message)\n"
    let data = Data(line.utf8)
    let path = daemonDebugLogPath
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        try? handle.write(contentsOf: data)
        try? handle.close()
    } else {
        FileManager.default.createFile(atPath: path, contents: data)
    }
}

private enum DaemonError: Error, CustomStringConvertible {
    case invalidArguments(String)
    case socketSetup(String)
    case request(String)

    var description: String {
        switch self {
        case .invalidArguments(let message), .socketSetup(let message), .request(let message):
            return message
        }
    }
}

private final class SessionConnection {
    let fileDescriptor: Int32
    private weak var server: TerminalRuntimeDaemon?
    private let writeLock = NSLock()
    private let lifecycleLock = NSLock()
    private var isClosed = false

    init(fileDescriptor: Int32, server: TerminalRuntimeDaemon) {
        self.fileDescriptor = fileDescriptor
        self.server = server
    }

    func start() {
        Thread.detachNewThread { [weak self] in
            self?.readLoop()
        }
    }

    func send(response: ZenbanTerminalRuntimeResponse) {
        send(lineForMessage: .response(response))
    }

    func send(event: ZenbanTerminalRuntimeEvent) {
        send(lineForMessage: .event(event))
    }

    func close() {
        lifecycleLock.lock()
        let shouldClose = !isClosed
        isClosed = true
        lifecycleLock.unlock()
        guard shouldClose else { return }
        Darwin.shutdown(fileDescriptor, SHUT_RDWR)
        Darwin.close(fileDescriptor)
    }

    private func send(lineForMessage message: ZenbanTerminalRuntimeMessage) {
        guard let data = try? ZenbanTerminalRuntimeProtocol.encodeLine(message) else { return }
        writeLock.lock()
        defer { writeLock.unlock() }
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var totalWritten = 0
            while totalWritten < rawBuffer.count {
                let wrote = Darwin.write(
                    fileDescriptor,
                    baseAddress.advanced(by: totalWritten),
                    rawBuffer.count - totalWritten
                )
                if wrote > 0 {
                    totalWritten += wrote
                    continue
                }
                if wrote == -1 && errno == EINTR {
                    continue
                }
                break
            }
        }
    }

    private func readLoop() {
        defer {
            server?.connectionDidClose(self)
            close()
        }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16_384)

        while true {
            let count = Darwin.read(fileDescriptor, &chunk, chunk.count)
            if count > 0 {
                buffer.append(chunk, count: count)
                processBufferedLines(&buffer)
                continue
            }
            if count == 0 {
                return
            }
            if errno == EINTR {
                continue
            }
            return
        }
    }

    private func processBufferedLines(_ buffer: inout Data) {
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let line = buffer.prefix(upTo: newlineIndex)
            buffer.removeSubrange(...newlineIndex)
            guard !line.isEmpty else { continue }

            do {
                let request = try ZenbanTerminalRuntimeProtocol.decodeRequest(from: Data(line))
                try server?.handle(request: request, from: self)
            } catch {
                let fallbackRequestID =
                    (try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])?["requestID"] as? String
                    ?? UUID().uuidString
                send(
                    response: ZenbanTerminalRuntimeResponse(
                        requestID: fallbackRequestID,
                        success: false,
                        error: String(describing: error),
                        snapshot: nil,
                        isNewSession: nil,
                        pid: nil
                    )
                )
            }
        }
    }
}

private final class TerminalRuntimeSession {
    private struct PendingAttachment {
        var bufferedChunks: [Data] = []
        var bufferedBytes = 0
    }

    let sessionID: String
    let sessionKind: ZenbanTerminalRuntimeSessionKind
    let launchCommand: String?

    private let lock = NSLock()
    private let maxReplayBytes = 512 * 1024
    private let maxPendingAttachBytes = 128 * 1024
    private let maxQueuedInputBytes = 128 * 1024
    private let inputReadinessFallbackDelay: TimeInterval
    private let inputReadinessAbsoluteDelay: TimeInterval
    private let inputReadinessOutputQuietDelay: TimeInterval
    private var replayBuffer = Data()
    private var attachedConnections: [Int32: SessionConnection] = [:]
    private var pendingAttachments: [Int32: PendingAttachment] = [:]
    private var queuedInput: [Data] = []
    private var queuedInputBytes = 0
    private var hasObservedPTYOutput = false
    private var pendingInputReadinessWorkItem: DispatchWorkItem?
    private var acceptsInput = false
    private var isAlive = true
    private var exitCode: Int32?
    private var masterFD: Int32
    private var childPID: pid_t
    private let onExit: (String, TerminalRuntimeSession) -> Void

    init(
        request: ZenbanTerminalRuntimeRequest,
        onExit: @escaping (String, TerminalRuntimeSession) -> Void
    ) throws {
        guard let sessionID = request.sessionID, !sessionID.isEmpty else {
            throw DaemonError.request("Missing sessionID")
        }

        let sessionKind = request.sessionKind ?? .shell
        let launchCommand = Self.normalizedLaunchCommand(request.launchCommand)
        if sessionKind == .agent && launchCommand == nil {
            throw DaemonError.request("Agent sessions require a launchCommand")
        }
        let cols = request.cols ?? 120
        let rows = request.rows ?? 34
        let spawnResult = try Self.spawnSession(
            cwd: request.cwd,
            cols: cols,
            rows: rows,
            env: request.env ?? ProcessInfo.processInfo.environment,
            shell: request.shell,
            sessionKind: sessionKind,
            launchCommand: launchCommand
        )

        self.sessionID = sessionID
        self.sessionKind = sessionKind
        self.launchCommand = launchCommand
        self.inputReadinessFallbackDelay = sessionKind == .agent ? 8 : 2
        self.inputReadinessAbsoluteDelay = sessionKind == .agent ? 4 : 2
        self.inputReadinessOutputQuietDelay = sessionKind == .agent ? 0.35 : 0
        self.masterFD = spawnResult.masterFD
        self.childPID = spawnResult.childPID
        self.onExit = onExit
        daemonDebugLog(
            "session.spawn session=\(sessionID) kind=\(sessionKind.rawValue) pid=\(spawnResult.childPID) " +
            "launch=\(launchCommand ?? "(nil)")"
        )
    }

    func start() {
        startReadLoop()
        startExitWatcher()
        scheduleInputReadinessFallback()
        scheduleAbsoluteInputReadinessFallback()
    }

    var pid: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return childPID
    }

    var alive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isAlive
    }

    func preparePendingAttach(_ connection: SessionConnection) {
        lock.lock()
        pendingAttachments[connection.fileDescriptor] = PendingAttachment()
        lock.unlock()
    }

    func beginAttach(_ connection: SessionConnection) -> Data? {
        lock.lock()
        pendingAttachments[connection.fileDescriptor] = PendingAttachment()
        let snapshot = sessionKind == .agent ? nil : replayBuffer
        lock.unlock()
        daemonDebugLog("attach session=\(sessionID) fd=\(connection.fileDescriptor) snapshotBytes=\(snapshot?.count ?? 0)")
        return snapshot
    }

    func finishAttach(_ connection: SessionConnection) {
        lock.lock()
        guard let pendingAttachment = pendingAttachments.removeValue(forKey: connection.fileDescriptor) else {
            lock.unlock()
            return
        }
        attachedConnections[connection.fileDescriptor] = connection
        let bufferedChunks = pendingAttachment.bufferedChunks
        lock.unlock()

        for chunk in bufferedChunks where !chunk.isEmpty {
            connection.send(
                event: ZenbanTerminalRuntimeEvent(
                    event: .data,
                    sessionID: sessionID,
                    data: chunk,
                    exitCode: nil,
                    error: nil
                )
            )
        }
    }

    func detach(_ connection: SessionConnection) {
        lock.lock()
        attachedConnections.removeValue(forKey: connection.fileDescriptor)
        pendingAttachments.removeValue(forKey: connection.fileDescriptor)
        lock.unlock()
    }

    func snapshot() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard sessionKind == .shell else { return nil }
        return replayBuffer
    }

    func matchesConfiguration(
        sessionKind: ZenbanTerminalRuntimeSessionKind,
        launchCommand: String?
    ) -> Bool {
        self.sessionKind == sessionKind && self.launchCommand == Self.normalizedLaunchCommand(launchCommand)
    }

    func write(_ data: Data) throws {
        let preview = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\n", with: "\\n")

        lock.lock()
        if isAlive && !acceptsInput {
            while !queuedInput.isEmpty && queuedInputBytes + data.count > maxQueuedInputBytes {
                let dropped = queuedInput.removeFirst()
                queuedInputBytes -= dropped.count
            }
            queuedInput.append(data)
            queuedInputBytes += data.count
            lock.unlock()
            daemonDebugLog(
                "write.queued session=\(sessionID) bytes=\(data.count) queuedBytes=\(queuedInputBytes) payload=\(preview)"
            )
            return
        }
        let masterFD = self.masterFD
        let alive = isAlive
        lock.unlock()

        guard alive else {
            throw DaemonError.request("Session \(sessionID) is not alive")
        }

        daemonDebugLog("write session=\(sessionID) bytes=\(data.count) payload=\(preview)")
        try Self.writeToMaster(data, masterFD: masterFD, sessionID: sessionID)
    }

    func resize(cols: UInt16, rows: UInt16) {
        lock.lock()
        let masterFD = self.masterFD
        let childPID = self.childPID
        let alive = isAlive
        lock.unlock()

        guard alive, masterFD >= 0 else { return }

        var windowSize = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        let resizeResult = Darwin.ioctl(masterFD, UInt(TIOCSWINSZ), &windowSize)
        guard resizeResult == 0 else {
            daemonDebugLog(
                "resize.failed session=\(sessionID) cols=\(cols) rows=\(rows) errno=\(errno)"
            )
            return
        }

        _ = Darwin.kill(childPID, SIGWINCH)
    }

    func kill() {
        lock.lock()
        let childPID = self.childPID
        let alive = isAlive
        lock.unlock()
        guard alive else { return }
        _ = Darwin.kill(childPID, SIGHUP)
    }

    private func withMasterFD(_ body: (Int32) throws -> Void) throws {
        lock.lock()
        let masterFD = self.masterFD
        let alive = isAlive
        lock.unlock()
        guard alive else {
            throw DaemonError.request("Session \(sessionID) is not alive")
        }
        try body(masterFD)
    }

    private func startReadLoop() {
        Thread.detachNewThread { [weak self] in
            self?.readLoop()
        }
    }

    private func readLoop() {
        var chunk = [UInt8](repeating: 0, count: 16_384)
        while true {
            lock.lock()
            let masterFD = self.masterFD
            let alive = isAlive
            lock.unlock()
            guard alive else { return }

            let count = Darwin.read(masterFD, &chunk, chunk.count)
            if count > 0 {
                let data = Data(chunk.prefix(count))
                handlePTYOutputReadiness()
                appendToSnapshot(data)
                broadcast(
                    event: ZenbanTerminalRuntimeEvent(
                        event: .data,
                        sessionID: sessionID,
                        data: data,
                        exitCode: nil,
                        error: nil
                    )
                )
                continue
            }

            if count == 0 {
                return
            }

            if errno == EINTR {
                continue
            }

            if errno == EIO || errno == EBADF {
                return
            }
        }
    }

    private func startExitWatcher() {
        Thread.detachNewThread { [weak self] in
            self?.waitForExit()
        }
    }

    private func waitForExit() {
        var status: Int32 = 0
        let result = Darwin.waitpid(childPID, &status, 0)
        guard result == childPID else { return }

        let resolvedExitCode = Self.resolveExitCode(status)
        daemonDebugLog(
            "session.exit session=\(sessionID) pid=\(childPID) status=\(status) exitCode=\(resolvedExitCode)"
        )

        lock.lock()
        guard isAlive else {
            lock.unlock()
            return
        }
        isAlive = false
        exitCode = resolvedExitCode
        pendingInputReadinessWorkItem?.cancel()
        pendingInputReadinessWorkItem = nil
        let masterFD = self.masterFD
        self.masterFD = -1
        let clients = Array(attachedConnections.values)
        pendingAttachments.removeAll()
        lock.unlock()

        if masterFD >= 0 {
            Darwin.close(masterFD)
        }

        let event = ZenbanTerminalRuntimeEvent(
            event: .exit,
            sessionID: sessionID,
            data: nil,
            exitCode: resolvedExitCode,
            error: nil
        )
        for client in clients {
            client.send(event: event)
        }
        onExit(sessionID, self)
    }

    private func appendToSnapshot(_ data: Data) {
        lock.lock()
        if sessionKind == .shell {
            replayBuffer.append(data)
            if replayBuffer.count > maxReplayBytes {
                replayBuffer.removeFirst(replayBuffer.count - maxReplayBytes)
            }
        }
        for key in pendingAttachments.keys {
            guard var pendingAttachment = pendingAttachments[key] else { continue }
            pendingAttachment.bufferedChunks.append(data)
            pendingAttachment.bufferedBytes += data.count
            while pendingAttachment.bufferedBytes > maxPendingAttachBytes,
                  let droppedChunk = pendingAttachment.bufferedChunks.first {
                pendingAttachment.bufferedChunks.removeFirst()
                pendingAttachment.bufferedBytes -= droppedChunk.count
            }
            pendingAttachments[key] = pendingAttachment
        }
        lock.unlock()
    }

    private func broadcast(event: ZenbanTerminalRuntimeEvent) {
        lock.lock()
        let clients = Array(attachedConnections.values)
        lock.unlock()
        for client in clients {
            client.send(event: event)
        }
    }

    private func scheduleInputReadinessFallback() {
        daemonDebugLog("input.fallback.scheduled session=\(sessionID) delay=\(inputReadinessFallbackDelay)")
        Thread.detachNewThread { [weak self] in
            Thread.sleep(forTimeInterval: self?.inputReadinessFallbackDelay ?? 0)
            self?.markInputReadyAfterSilentStartupTimeout()
        }
    }

    private func scheduleAbsoluteInputReadinessFallback() {
        daemonDebugLog("input.absoluteFallback.scheduled session=\(sessionID) delay=\(inputReadinessAbsoluteDelay)")
        Thread.detachNewThread { [weak self] in
            Thread.sleep(forTimeInterval: self?.inputReadinessAbsoluteDelay ?? 0)
            self?.markInputReadyAfterAbsoluteStartupTimeout()
        }
    }

    private func handlePTYOutputReadiness() {
        guard sessionKind == .agent else {
            markInputReadyIfNeeded(reason: "pty-output")
            return
        }

        let workItem: DispatchWorkItem
        lock.lock()
        guard isAlive, !acceptsInput else {
            lock.unlock()
            return
        }

        hasObservedPTYOutput = true
        pendingInputReadinessWorkItem?.cancel()
        workItem = DispatchWorkItem { [weak self] in
            self?.markInputReadyIfNeeded(reason: "pty-output-quiet")
        }
        pendingInputReadinessWorkItem = workItem
        let delay = inputReadinessOutputQuietDelay
        lock.unlock()

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func markInputReadyAfterSilentStartupTimeout() {
        lock.lock()
        let shouldMarkReady = isAlive && !acceptsInput && !hasObservedPTYOutput
        lock.unlock()
        guard shouldMarkReady else { return }
        markInputReadyIfNeeded(reason: "startup-timeout")
    }

    private func markInputReadyAfterAbsoluteStartupTimeout() {
        lock.lock()
        let shouldMarkReady = isAlive && !acceptsInput
        lock.unlock()
        guard shouldMarkReady else { return }
        markInputReadyIfNeeded(reason: "absolute-startup-timeout")
    }

    private func markInputReadyIfNeeded(reason: String) {
        lock.lock()
        guard isAlive, !acceptsInput else {
            lock.unlock()
            return
        }

        pendingInputReadinessWorkItem?.cancel()
        pendingInputReadinessWorkItem = nil
        acceptsInput = true
        let queued = queuedInput
        let queuedBytes = queuedInputBytes
        queuedInput.removeAll(keepingCapacity: false)
        queuedInputBytes = 0
        let masterFD = self.masterFD
        lock.unlock()

        daemonDebugLog(
            "input.ready session=\(sessionID) reason=\(reason) queuedChunks=\(queued.count) queuedBytes=\(queuedBytes)"
        )

        guard masterFD >= 0 else { return }
        for chunk in queued {
            do {
                try Self.writeToMaster(chunk, masterFD: masterFD, sessionID: sessionID)
            } catch {
                daemonDebugLog("write.flush.failed session=\(sessionID) error=\(error)")
                return
            }
        }
    }

    private static func writeToMaster(_ data: Data, masterFD: Int32, sessionID: String) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var totalWritten = 0
            while totalWritten < rawBuffer.count {
                let wrote = Darwin.write(
                    masterFD,
                    baseAddress.advanced(by: totalWritten),
                    rawBuffer.count - totalWritten
                )
                if wrote > 0 {
                    totalWritten += wrote
                    continue
                }
                if wrote == -1 && errno == EINTR {
                    continue
                }
                throw DaemonError.request("Failed to write to session \(sessionID)")
            }
        }
    }

    private static func spawnSession(
        cwd: String?,
        cols: UInt16,
        rows: UInt16,
        env: [String: String],
        shell: String?,
        sessionKind: ZenbanTerminalRuntimeSessionKind,
        launchCommand: String?
    ) throws -> (masterFD: Int32, childPID: pid_t) {
        var masterFD: Int32 = -1
        var windowSize = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        let childPID = forkpty(&masterFD, nil, nil, &windowSize)
        guard childPID >= 0 else {
            throw DaemonError.socketSetup("forkpty failed: \(String(cString: strerror(errno)))")
        }

        if childPID == 0 {
            let resolvedShell = shell ?? env["SHELL"] ?? "/bin/zsh"
            if let cwd, !cwd.isEmpty {
                _ = cwd.withCString { Darwin.chdir($0) }
            }

            for (key, value) in env where !key.isEmpty {
                setenv(key, value, 1)
            }

            Self.execShell(
                resolvedShell: resolvedShell,
                sessionKind: sessionKind,
                launchCommand: launchCommand
            )
        }

        return (masterFD, childPID)
    }

    private static func execShell(
        resolvedShell: String,
        sessionKind: ZenbanTerminalRuntimeSessionKind,
        launchCommand: String?
    ) {
        let shellName = URL(fileURLWithPath: resolvedShell).lastPathComponent
        let loginShellName = "-\(shellName)"

        resolvedShell.withCString { shellPtr in
            loginShellName.withCString { loginShellPtr in
                let argvStorage: [UnsafeMutablePointer<CChar>?]
                switch sessionKind {
                case .shell:
                    argvStorage = [
                        strdup(loginShellPtr),
                        strdup("-i"),
                        nil
                    ]
                case .agent:
                    let command = launchCommand ?? ""
                    argvStorage = [
                        strdup(shellName),
                        strdup("-c"),
                        strdup("exec \(command)"),
                        nil
                    ]
                }

                execv(shellPtr, argvStorage)
                let message = "execv failed for \(resolvedShell)\n"
                _ = message.withCString { Darwin.write(STDERR_FILENO, $0, strlen($0)) }
                _exit(1)
            }
        }
        _exit(1)
    }

    fileprivate static func normalizedLaunchCommand(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func resolveExitCode(_ status: Int32) -> Int32 {
        let lowBits = status & 0x7f
        if lowBits == 0 {
            return (status >> 8) & 0xff
        }
        if lowBits != 0x7f {
            return 128 + lowBits
        }
        return -1
    }
}

private final class TerminalRuntimeDaemon {
    private let socketPath: String
    private let stateLock = NSLock()
    private var sessions: [String: TerminalRuntimeSession] = [:]
    private var connections: [Int32: SessionConnection] = [:]
    private var listenerFD: Int32 = -1
    private var shutdownRequested = false

    init(socketPath: String) {
        self.socketPath = socketPath
        setDaemonDebugLogPath(socketPath: socketPath)
    }

    func run() throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: (socketPath as NSString).deletingLastPathComponent, isDirectory: true),
            withIntermediateDirectories: true
        )

        let listenerFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenerFD >= 0 else {
            throw DaemonError.socketSetup("socket() failed")
        }
        defer {
            stateLock.lock()
            let trackedListenerFD = self.listenerFD
            self.listenerFD = -1
            stateLock.unlock()

            if trackedListenerFD >= 0 {
                Darwin.close(trackedListenerFD)
            }
            unlink(socketPath)
        }

        unlink(socketPath)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw DaemonError.invalidArguments("Socket path is too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: CChar.self, repeating: 0)
            for (index, byte) in pathBytes.enumerated() {
                buffer[index] = byte
            }
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listenerFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            throw DaemonError.socketSetup("bind() failed for \(socketPath)")
        }

        guard Darwin.listen(listenerFD, SOMAXCONN) == 0 else {
            throw DaemonError.socketSetup("listen() failed for \(socketPath)")
        }

        stateLock.lock()
        self.listenerFD = listenerFD
        stateLock.unlock()

        while true {
            stateLock.lock()
            let shouldShutdown = shutdownRequested
            stateLock.unlock()
            if shouldShutdown {
                break
            }

            let clientFD = Darwin.accept(listenerFD, nil, nil)
            if clientFD < 0 {
                stateLock.lock()
                let shouldShutdownAfterAccept = shutdownRequested
                stateLock.unlock()
                if shouldShutdownAfterAccept && (errno == EBADF || errno == EINVAL) {
                    break
                }
                if errno == EINTR {
                    continue
                }
                continue
            }

            let connection = SessionConnection(fileDescriptor: clientFD, server: self)
            stateLock.lock()
            connections[clientFD] = connection
            stateLock.unlock()
            connection.start()
        }
    }

    func handle(request: ZenbanTerminalRuntimeRequest, from connection: SessionConnection) throws {
        switch request.action {
        case .createOrAttach:
            try handleCreateOrAttach(request, from: connection)
        case .detach:
            guard let sessionID = request.sessionID else {
                throw DaemonError.request("Missing sessionID")
            }
            session(for: sessionID)?.detach(connection)
            connection.send(
                response: ZenbanTerminalRuntimeResponse(
                    requestID: request.requestID,
                    success: true,
                    error: nil,
                    snapshot: nil,
                    isNewSession: nil,
                    pid: nil
                )
            )
        case .write:
            guard let sessionID = request.sessionID else {
                throw DaemonError.request("Missing sessionID")
            }
            guard let data = request.data else {
                throw DaemonError.request("Missing write data")
            }
            guard let session = session(for: sessionID) else {
                throw DaemonError.request("Session \(sessionID) not found")
            }
            try session.write(data)
            connection.send(
                response: ZenbanTerminalRuntimeResponse(
                    requestID: request.requestID,
                    success: true,
                    error: nil,
                    snapshot: nil,
                    isNewSession: nil,
                    pid: nil
                )
            )
        case .resize:
            guard let sessionID = request.sessionID,
                  let cols = request.cols,
                  let rows = request.rows else {
                throw DaemonError.request("Missing resize arguments")
            }
            session(for: sessionID)?.resize(cols: cols, rows: rows)
            connection.send(
                response: ZenbanTerminalRuntimeResponse(
                    requestID: request.requestID,
                    success: true,
                    error: nil,
                    snapshot: nil,
                    isNewSession: nil,
                    pid: nil
                )
            )
        case .kill:
            guard let sessionID = request.sessionID else {
                throw DaemonError.request("Missing sessionID")
            }
            session(for: sessionID)?.kill()
            connection.send(
                response: ZenbanTerminalRuntimeResponse(
                    requestID: request.requestID,
                    success: true,
                    error: nil,
                    snapshot: nil,
                    isNewSession: nil,
                    pid: nil
                )
            )
        case .snapshot:
            guard let sessionID = request.sessionID else {
                throw DaemonError.request("Missing sessionID")
            }
            let resolvedSession = session(for: sessionID)
            let snapshot = resolvedSession?.snapshot()
            connection.send(
                response: ZenbanTerminalRuntimeResponse(
                    requestID: request.requestID,
                    success: true,
                    error: nil,
                    snapshot: snapshot,
                    isNewSession: nil,
                    pid: resolvedSession?.pid
                )
            )
        case .shutdown:
            connection.send(
                response: ZenbanTerminalRuntimeResponse(
                    requestID: request.requestID,
                    success: true,
                    error: nil,
                    snapshot: nil,
                    isNewSession: nil,
                    pid: nil
                )
            )
            requestShutdown(killSessions: request.killSessions ?? true)
        }
    }

    func connectionDidClose(_ connection: SessionConnection) {
        stateLock.lock()
        connections.removeValue(forKey: connection.fileDescriptor)
        let sessions = Array(self.sessions.values)
        stateLock.unlock()

        for session in sessions {
            session.detach(connection)
        }
    }

    private func handleCreateOrAttach(_ request: ZenbanTerminalRuntimeRequest, from connection: SessionConnection) throws {
        guard let sessionID = request.sessionID, !sessionID.isEmpty else {
            throw DaemonError.request("Missing sessionID")
        }

        let requestedSessionKind = request.sessionKind ?? .shell
        let requestedLaunchCommand = TerminalRuntimeSession.normalizedLaunchCommand(request.launchCommand)
        var isNewSession = false
        let resolvedSession: TerminalRuntimeSession
        if let existing = self.session(for: sessionID), existing.alive {
            if existing.matchesConfiguration(
                sessionKind: requestedSessionKind,
                launchCommand: requestedLaunchCommand
            ) {
                resolvedSession = existing
            } else {
                existing.kill()
                stateLock.lock()
                if sessions[sessionID] === existing {
                    sessions.removeValue(forKey: sessionID)
                }
                stateLock.unlock()

                let created = try TerminalRuntimeSession(request: request) { [weak self] sessionID, session in
                    self?.sessionDidExit(sessionID, session: session)
                }
                let attach = request.attach ?? true
                if attach {
                    created.preparePendingAttach(connection)
                }
                stateLock.lock()
                sessions[sessionID] = created
                stateLock.unlock()
                created.start()
                resolvedSession = created
                isNewSession = true
            }
        } else {
            let created = try TerminalRuntimeSession(request: request) { [weak self] sessionID, session in
                self?.sessionDidExit(sessionID, session: session)
            }
            let attach = request.attach ?? true
            if attach {
                created.preparePendingAttach(connection)
            }
            stateLock.lock()
            sessions[sessionID] = created
            stateLock.unlock()
            created.start()
            resolvedSession = created
            isNewSession = true
        }

        let attach = request.attach ?? true
        let snapshot: Data?
        if attach {
            snapshot = isNewSession ? resolvedSession.snapshot() : resolvedSession.beginAttach(connection)
        } else {
            snapshot = resolvedSession.snapshot()
        }
        daemonDebugLog(
            "createOrAttach session=\(sessionID) attach=\(attach ? 1 : 0) " +
            "new=\(isNewSession ? 1 : 0) fd=\(connection.fileDescriptor) snapshotBytes=\(snapshot?.count ?? 0)"
        )
        connection.send(
            response: ZenbanTerminalRuntimeResponse(
                requestID: request.requestID,
                success: true,
                error: nil,
                snapshot: snapshot,
                isNewSession: isNewSession,
                pid: resolvedSession.pid
            )
        )
        if attach {
            resolvedSession.finishAttach(connection)
        }
    }

    private func session(for sessionID: String) -> TerminalRuntimeSession? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return sessions[sessionID]
    }

    private func sessionDidExit(_ sessionID: String, session: TerminalRuntimeSession) {
        stateLock.lock()
        if sessions[sessionID] === session {
            sessions.removeValue(forKey: sessionID)
        }
        stateLock.unlock()
    }

    private func requestShutdown(killSessions: Bool) {
        stateLock.lock()
        guard !shutdownRequested else {
            stateLock.unlock()
            return
        }
        shutdownRequested = true
        let listenerFD = self.listenerFD
        self.listenerFD = -1
        let sessions = Array(self.sessions.values)
        let connections = Array(self.connections.values)
        stateLock.unlock()

        if killSessions {
            for session in sessions {
                session.kill()
            }
        }

        if listenerFD >= 0 {
            Darwin.shutdown(listenerFD, SHUT_RDWR)
            Darwin.close(listenerFD)
        }

        for connection in connections {
            connection.close()
        }
    }
}

@main
private enum ZenbanTerminalDaemonMain {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        do {
            let arguments = CommandLine.arguments
            guard let socketFlagIndex = arguments.firstIndex(of: "--socket-path"),
                  socketFlagIndex + 1 < arguments.count else {
                throw DaemonError.invalidArguments("Usage: zenban-terminal-daemon --socket-path <path>")
            }

            let socketPath = arguments[socketFlagIndex + 1]
            setDaemonDebugLogPath(socketPath: socketPath)
            daemonDebugLog("main.start socket=\(socketPath)")
            let daemon = TerminalRuntimeDaemon(socketPath: socketPath)
            try daemon.run()
            daemonDebugLog("main.exit")
        } catch {
            daemonDebugLog("main.error \(error)")
            fputs("zenban-terminal-daemon error: \(error)\n", stderr)
            Darwin.exit(1)
        }
    }
}
