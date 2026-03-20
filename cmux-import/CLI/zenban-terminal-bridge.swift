import Darwin
import Dispatch
import Foundation

private var bridgeDebugLogPath = "/tmp/zenban-terminal-runtime.log"

private func setBridgeDebugLogPath(socketPath: String) {
    let directory = (socketPath as NSString).deletingLastPathComponent
    guard !directory.isEmpty else { return }
    bridgeDebugLogPath = (directory as NSString).appendingPathComponent("terminal-runtime.log")
}

private func bridgeDebugLog(_ message: String) {
    let line = "[bridge] \(message)\n"
    let data = Data(line.utf8)
    let path = bridgeDebugLogPath
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        try? handle.write(contentsOf: data)
        try? handle.close()
    } else {
        FileManager.default.createFile(atPath: path, contents: data)
    }
}

private enum BridgeError: Error, CustomStringConvertible {
    case invalidArguments(String)
    case socket(String)
    case protocolViolation(String)

    var description: String {
        switch self {
        case .invalidArguments(let message), .socket(let message), .protocolViolation(let message):
            return message
        }
    }
}

private final class TerminalBridge {
    private struct RawTerminalState {
        let fileDescriptor: Int32
        let original: termios
    }

    private let socketPath: String
    private let sessionID: String
    private let cwd: String?
    private let daemonBinaryPath: String
    private let sessionKind: ZenbanTerminalRuntimeSessionKind
    private let launchCommand: String?
    private let socketFD: Int32
    private let writeLock = NSLock()
    private let lifecycleLock = NSLock()
    private let shutdownSemaphore = DispatchSemaphore(value: 0)
    private var signalSources: [DispatchSourceSignal] = []
    private var hasDetached = false
    private var isStopping = false
    private var exitCode: Int32 = 0
    private var rawTerminalState: RawTerminalState?
    private var socketReadBuffer = Data()

    init(
        socketPath: String,
        sessionID: String,
        cwd: String?,
        daemonBinaryPath: String,
        sessionKind: ZenbanTerminalRuntimeSessionKind,
        launchCommand: String?
    ) throws {
        self.socketPath = socketPath
        self.sessionID = sessionID
        self.cwd = cwd
        self.daemonBinaryPath = daemonBinaryPath
        self.sessionKind = sessionKind
        self.launchCommand = launchCommand?.trimmingCharacters(in: .whitespacesAndNewlines)
        setBridgeDebugLogPath(socketPath: socketPath)
        self.socketFD = try Self.connectWithBootstrap(
            to: socketPath,
            daemonBinaryPath: daemonBinaryPath
        )
    }

    func run() throws -> Int32 {
        try enterRawTerminalModeIfNeeded()
        defer { restoreRawTerminalModeIfNeeded() }

        let initialResponse = try createOrAttach()
        bridgeDebugLog("run session=\(sessionID) snapshotBytes=\(initialResponse.snapshot?.count ?? 0)")
        if let snapshot = initialResponse.snapshot, !snapshot.isEmpty {
            try Self.writeAll(snapshot, to: STDOUT_FILENO)
        }

        startSocketEventLoop()
        installSignalHandlers()
        sendInitialResize()
        startInputForwardLoop()

        shutdownSemaphore.wait()
        detachIfNeeded()
        Darwin.close(socketFD)
        return exitCode
    }

    private func enterRawTerminalModeIfNeeded() throws {
        guard isatty(STDIN_FILENO) == 1 else { return }

        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else {
            throw BridgeError.socket("tcgetattr() failed")
        }

        var raw = original
        cfmakeraw(&raw)
        raw.c_iflag |= tcflag_t(IUTF8)
        guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else {
            throw BridgeError.socket("tcsetattr() failed")
        }

        rawTerminalState = RawTerminalState(fileDescriptor: STDIN_FILENO, original: original)
        bridgeDebugLog("tty.raw enabled session=\(sessionID)")
    }

    private func restoreRawTerminalModeIfNeeded() {
        guard let rawTerminalState else { return }
        var original = rawTerminalState.original
        _ = tcsetattr(rawTerminalState.fileDescriptor, TCSANOW, &original)
        self.rawTerminalState = nil
        bridgeDebugLog("tty.raw restored session=\(sessionID)")
    }

    private func createOrAttach() throws -> ZenbanTerminalRuntimeResponse {
        let size = currentWindowSize()
        let createEnvironment: [String: String]?
        let createShell: String?
        if sessionKind == .shell {
            createEnvironment = ProcessInfo.processInfo.environment
            createShell = resolvedShellPath()
        } else {
            createEnvironment = nil
            createShell = nil
        }
        let request = ZenbanTerminalRuntimeRequest(
            action: .createOrAttach,
            sessionID: sessionID,
            cwd: resolvedWorkingDirectory(),
            cols: size.cols,
            rows: size.rows,
            env: createEnvironment,
            shell: createShell,
            sessionKind: sessionKind,
            launchCommand: launchCommand,
            attach: true,
            data: nil
        )
        try send(request: request)
        let message = try readNextMessage()
        guard case .response(let response) = message else {
            throw BridgeError.protocolViolation("Expected createOrAttach response")
        }
        guard response.success else {
            throw BridgeError.protocolViolation(response.error ?? "createOrAttach failed")
        }
        return response
    }

    private func sendInitialResize() {
        let size = currentWindowSize()
        let request = ZenbanTerminalRuntimeRequest(
            action: .resize,
            sessionID: sessionID,
            cols: size.cols,
            rows: size.rows
        )
        do {
            try send(request: request)
            bridgeDebugLog("resize.initial session=\(sessionID) cols=\(size.cols) rows=\(size.rows)")
        } catch {
            bridgeDebugLog("resize.initial.failed session=\(sessionID) error=\(error)")
        }
    }

    private func startSocketEventLoop() {
        Thread.detachNewThread { [weak self] in
            self?.socketEventLoop()
        }
    }

    private func socketEventLoop() {
        var chunk = [UInt8](repeating: 0, count: 16_384)

        processBufferedSocketMessages()

        while true {
            let count = Darwin.read(socketFD, &chunk, chunk.count)
            if count > 0 {
                socketReadBuffer.append(chunk, count: count)
                processBufferedSocketMessages()
                continue
            }
            if count == 0 {
                bridgeDebugLog("socket.eof session=\(sessionID) exitCode=\(exitCode)")
                requestStop(exitCode: exitCode)
                return
            }
            if errno == EINTR {
                continue
            }
            bridgeDebugLog("socket.read.failed session=\(sessionID) errno=\(errno)")
            requestStop(exitCode: 1)
            return
        }
    }

    private func processBufferedSocketMessages() {
        while let message = nextDecodedMessage() {
            switch message {
            case .response:
                continue
            case .event(let event):
                handle(event: event)
            }
        }
    }

    private func nextDecodedMessage() -> ZenbanTerminalRuntimeMessage? {
        while let newlineIndex = socketReadBuffer.firstIndex(of: 0x0A) {
            let line = Data(socketReadBuffer.prefix(upTo: newlineIndex))
            socketReadBuffer.removeSubrange(...newlineIndex)
            guard !line.isEmpty else {
                continue
            }
            return try? ZenbanTerminalRuntimeProtocol.decodeMessage(from: line)
        }
        return nil
    }

    private func readNextMessage() throws -> ZenbanTerminalRuntimeMessage {
        while true {
            if let message = nextDecodedMessage() {
                return message
            }

            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(socketFD, &chunk, chunk.count)
            if count > 0 {
                socketReadBuffer.append(chunk, count: count)
                continue
            }
            if count == 0 {
                throw BridgeError.socket("Socket closed before response")
            }
            if errno == EINTR {
                continue
            }
            throw BridgeError.socket("Failed to read from socket")
        }
    }

    private func handle(event: ZenbanTerminalRuntimeEvent) {
        switch event.event {
        case .data:
            guard let data = event.data, !data.isEmpty else { return }
            _ = try? Self.writeAll(data, to: STDOUT_FILENO)
        case .exit:
            bridgeDebugLog("event.exit session=\(sessionID) code=\(event.exitCode ?? -999)")
            requestStop(exitCode: event.exitCode ?? 0)
        case .error:
            if let error = event.error {
                bridgeDebugLog("event.error session=\(sessionID) error=\(error)")
                let message = Data((error + "\n").utf8)
                _ = try? Self.writeAll(message, to: STDERR_FILENO)
            }
        }
    }

    private func startInputForwardLoop() {
        Thread.detachNewThread { [weak self] in
            self?.inputForwardLoop()
        }
    }

    private func inputForwardLoop() {
        var chunk = [UInt8](repeating: 0, count: 8_192)
        while true {
            lifecycleLock.lock()
            let stopping = isStopping
            lifecycleLock.unlock()
            if stopping { return }

            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
            let pollResult = Darwin.poll(&descriptor, 1, 250)
            if pollResult == 0 {
                continue
            }
            if pollResult == -1 {
                if errno == EINTR {
                    continue
                }
                bridgeDebugLog("stdin.poll.failed session=\(sessionID) errno=\(errno)")
                requestStop(exitCode: 1)
                return
            }
            if descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0,
               descriptor.revents & Int16(POLLIN) == 0 {
                bridgeDebugLog("stdin.poll.hup session=\(sessionID) revents=\(descriptor.revents)")
                requestStop(exitCode: exitCode)
                return
            }
            if descriptor.revents & Int16(POLLIN) == 0 {
                continue
            }

            let count = Darwin.read(STDIN_FILENO, &chunk, chunk.count)
            if count > 0 {
                let payload = Data(chunk.prefix(count))
                let preview = String(decoding: payload, as: UTF8.self)
                    .replacingOccurrences(of: "\n", with: "\\n")
                bridgeDebugLog("stdin->daemon session=\(sessionID) bytes=\(count) payload=\(preview)")
                let request = ZenbanTerminalRuntimeRequest(
                    action: .write,
                    sessionID: sessionID,
                    data: payload
                )
                _ = try? send(request: request)
                continue
            }
            if count == 0 {
                bridgeDebugLog("stdin.eof session=\(sessionID)")
                requestStop(exitCode: exitCode)
                return
            }
            if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                continue
            }
            bridgeDebugLog("stdin.read.failed session=\(sessionID) errno=\(errno)")
            requestStop(exitCode: 1)
            return
        }
    }

    private func installSignalHandlers() {
        signal(SIGWINCH, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        signal(SIGHUP, SIG_IGN)
        signal(SIGINT, SIG_IGN)

        let winchSource = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global(qos: .utility))
        winchSource.setEventHandler { [weak self] in
            guard let self else { return }
            let size = self.currentWindowSize()
            let request = ZenbanTerminalRuntimeRequest(
                action: .resize,
                sessionID: self.sessionID,
                cols: size.cols,
                rows: size.rows
            )
            _ = try? self.send(request: request)
        }
        winchSource.resume()
        signalSources.append(winchSource)

        let stopHandler: @Sendable () -> Void = { [weak self] in
            self?.requestStop(exitCode: 0)
        }

        for signalValue in [SIGTERM, SIGHUP, SIGINT] {
            let source = DispatchSource.makeSignalSource(signal: signalValue, queue: .global(qos: .utility))
            source.setEventHandler(handler: stopHandler)
            source.resume()
            signalSources.append(source)
        }
    }

    private func resolvedWorkingDirectory() -> String {
        if let cwd, !cwd.isEmpty {
            return cwd
        }
        return FileManager.default.currentDirectoryPath
    }

    private func resolvedShellPath() -> String {
        let env = ProcessInfo.processInfo.environment
        if let shell = env["SHELL"], !shell.isEmpty {
            return shell
        }
        return "/bin/zsh"
    }

    private func currentWindowSize() -> (cols: UInt16, rows: UInt16) {
        if isatty(STDOUT_FILENO) == 1 {
            var windowSize = winsize()
            if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &windowSize) == 0,
               windowSize.ws_col > 0,
               windowSize.ws_row > 0 {
                return (windowSize.ws_col, windowSize.ws_row)
            }
        }

        let environment = ProcessInfo.processInfo.environment
        if let columns = environment["COLUMNS"].flatMap(UInt16.init),
           let rows = environment["LINES"].flatMap(UInt16.init),
           columns > 0,
           rows > 0 {
            return (columns, rows)
        }
        return (120, 34)
    }

    private func send(request: ZenbanTerminalRuntimeRequest) throws {
        let data = try ZenbanTerminalRuntimeProtocol.encodeLine(request)
        writeLock.lock()
        defer { writeLock.unlock() }
        try Self.writeAll(data, to: socketFD)
    }

    private func detachIfNeeded() {
        lifecycleLock.lock()
        let shouldDetach = !hasDetached
        hasDetached = true
        lifecycleLock.unlock()
        guard shouldDetach else { return }

        let request = ZenbanTerminalRuntimeRequest(
            action: .detach,
            sessionID: sessionID
        )
        _ = try? send(request: request)
    }

    private func requestStop(exitCode: Int32) {
        lifecycleLock.lock()
        let shouldSignal = !isStopping
        isStopping = true
        self.exitCode = exitCode
        lifecycleLock.unlock()
        guard shouldSignal else { return }
        shutdownSemaphore.signal()
    }

    private static func connect(to socketPath: String) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw BridgeError.socket("socket() failed")
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd)
            throw BridgeError.invalidArguments("Socket path is too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: CChar.self, repeating: 0)
            for (index, byte) in pathBytes.enumerated() {
                buffer[index] = byte
            }
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            throw BridgeError.socket("connect() failed for \(socketPath)")
        }

        return fd
    }

    private static func connectWithBootstrap(to socketPath: String, daemonBinaryPath: String) throws -> Int32 {
        if let connected = try? connect(to: socketPath) {
            return connected
        }

        try startDaemon(socketPath: socketPath, daemonBinaryPath: daemonBinaryPath)

        for _ in 0..<40 {
            usleep(50_000)
            if let connected = try? connect(to: socketPath) {
                return connected
            }
        }

        throw BridgeError.socket("connect() failed for \(socketPath)")
    }

    private static func startDaemon(socketPath: String, daemonBinaryPath: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: daemonBinaryPath)
        process.arguments = ["--socket-path", socketPath]
        process.standardInput = nil
        process.standardOutput = nil
        process.standardError = nil
        try process.run()
    }

    private static func siblingDaemonBinaryPath() -> String {
        let executablePath = (CommandLine.arguments.first?.isEmpty == false)
            ? CommandLine.arguments[0]
            : FileManager.default.currentDirectoryPath
        let directory = (executablePath as NSString).deletingLastPathComponent
        return (directory as NSString).appendingPathComponent("zenban-terminal-daemon")
    }

    private static func writeAll(_ data: Data, to fileDescriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
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
                throw BridgeError.socket("write() failed")
            }
        }
    }
}

@main
private enum ZenbanTerminalBridgeMain {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        do {
            let arguments = CommandLine.arguments
            guard let socketFlagIndex = arguments.firstIndex(of: "--socket-path"),
                  socketFlagIndex + 1 < arguments.count,
                  let sessionFlagIndex = arguments.firstIndex(of: "--session-id"),
                  sessionFlagIndex + 1 < arguments.count,
                  let sessionKindFlagIndex = arguments.firstIndex(of: "--session-kind"),
                  sessionKindFlagIndex + 1 < arguments.count,
                  let sessionKind = ZenbanTerminalRuntimeSessionKind(rawValue: arguments[sessionKindFlagIndex + 1]) else {
                throw BridgeError.invalidArguments(
                    "Usage: zenban-terminal-bridge --socket-path <path> --session-id <id> --session-kind <shell|agent> [--cwd <path>] [--launch-command <command>]"
                )
            }

            let cwd: String?
            if let cwdFlagIndex = arguments.firstIndex(of: "--cwd"), cwdFlagIndex + 1 < arguments.count {
                cwd = arguments[cwdFlagIndex + 1]
            } else {
                cwd = nil
            }

            let daemonBinaryPath: String
            if let daemonBinaryPathFlagIndex = arguments.firstIndex(of: "--daemon-binary-path"),
               daemonBinaryPathFlagIndex + 1 < arguments.count {
                daemonBinaryPath = arguments[daemonBinaryPathFlagIndex + 1]
            } else {
                daemonBinaryPath = Self.siblingDaemonBinaryPath()
            }

            let launchCommand: String?
            if let launchCommandFlagIndex = arguments.firstIndex(of: "--launch-command"),
               launchCommandFlagIndex + 1 < arguments.count {
                launchCommand = arguments[launchCommandFlagIndex + 1]
            } else {
                launchCommand = nil
            }

            bridgeDebugLog(
                "main.start session=\(arguments[sessionFlagIndex + 1]) kind=\(sessionKind.rawValue) " +
                "cwd=\(cwd ?? "(nil)") launch=\(launchCommand ?? "(nil)")"
            )
            let bridge = try TerminalBridge(
                socketPath: arguments[socketFlagIndex + 1],
                sessionID: arguments[sessionFlagIndex + 1],
                cwd: cwd,
                daemonBinaryPath: daemonBinaryPath,
                sessionKind: sessionKind,
                launchCommand: launchCommand
            )
            let code = try bridge.run()
            bridgeDebugLog("main.exit code=\(code)")
            Darwin.exit(code)
        } catch {
            bridgeDebugLog("main.error \(error)")
            fputs("zenban-terminal-bridge error: \(error)\n", stderr)
            Darwin.exit(1)
        }
    }

    private static func siblingDaemonBinaryPath() -> String {
        let executablePath = (CommandLine.arguments.first?.isEmpty == false)
            ? CommandLine.arguments[0]
            : FileManager.default.currentDirectoryPath
        let directory = (executablePath as NSString).deletingLastPathComponent
        return (directory as NSString).appendingPathComponent("zenban-terminal-daemon")
    }
}
