import Foundation

actor ZenbanTerminalRuntimeService {
    static let shared = ZenbanTerminalRuntimeService()
    nonisolated static let isEnabled: Bool = {
        let env = ProcessInfo.processInfo.environment
        if let rawValue = env["ZENBAN_TERMINAL_RUNTIME_ENABLED"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawValue.isEmpty {
            switch rawValue.lowercased() {
            case "0", "false", "no", "off":
                return false
            default:
                return true
            }
        }
        return true
    }()

    private var startupTask: Task<Void, Never>?

    func startDaemonIfNeeded() {
        guard Self.isEnabled else { return }
        if let preflightError = Self.runtimePreflightError() {
            NSLog("terminal.runtime.daemon.preflight failed: %@", preflightError)
            return
        }
        guard startupTask == nil else { return }
        startupTask = Task(priority: .utility) {
            do {
                try await Self.ensureDaemonAvailable(
                    socketPath: Self.socketPath(),
                    daemonBinaryPath: Self.daemonBinaryPath()
                )
            } catch {
                NSLog("terminal.runtime.daemon.start failed: %@", String(describing: error))
            }
            await self.clearStartupTask()
        }
    }

    func prepareSession(
        sessionID: String,
        cwd: String?,
        env: [String: String],
        shell: String?,
        sessionKind: ZenbanTerminalRuntimeSessionKind = .shell,
        launchCommand: String? = nil
    ) async throws {
        guard Self.isEnabled else { return }
        try await send(
            ZenbanTerminalRuntimeRequest(
                action: .createOrAttach,
                sessionID: sessionID,
                cwd: cwd,
                cols: 120,
                rows: 34,
                env: env,
                shell: shell,
                sessionKind: sessionKind,
                launchCommand: launchCommand,
                attach: false
            )
        )
    }

    func write(sessionID: String, data: Data) async throws {
        guard Self.isEnabled else {
            throw NSError(
                domain: "ZenbanTerminalRuntime",
                code: 100,
                userInfo: [NSLocalizedDescriptionKey: "Terminal runtime is disabled"]
            )
        }
        try await send(
            ZenbanTerminalRuntimeRequest(
                action: .write,
                sessionID: sessionID,
                data: data
            )
        )
    }

    func kill(sessionID: String) async {
        guard Self.isEnabled else { return }
        _ = try? await send(
            ZenbanTerminalRuntimeRequest(
                action: .kill,
                sessionID: sessionID
            )
        )
    }

    func shutdownIfRunning(killSessions: Bool) async {
        guard Self.isEnabled else { return }
        let socketPath = Self.socketPath()
        guard Self.canConnect(to: socketPath) else { return }
        _ = try? await Self.performUnaryRequest(
            ZenbanTerminalRuntimeRequest(
                action: .shutdown,
                killSessions: killSessions
            ),
            socketPath: socketPath
        )
    }

    private func send(_ request: ZenbanTerminalRuntimeRequest) async throws -> ZenbanTerminalRuntimeResponse {
        try await Self.ensureDaemonAvailable(
            socketPath: Self.socketPath(),
            daemonBinaryPath: Self.daemonBinaryPath()
        )
        return try await Self.performUnaryRequest(request, socketPath: Self.socketPath())
    }

    private func clearStartupTask() {
        startupTask = nil
    }

    nonisolated static func shutdownIfRunningBlocking(
        killSessions: Bool,
        timeout: TimeInterval = 2
    ) {
        guard isEnabled else { return }

        let semaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: .utility) {
            await shared.shutdownIfRunning(killSessions: killSessions)
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout)
    }

    static func socketPath() -> String {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.zenban.app"
        let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupportURL
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent("terminal-daemon.sock", isDirectory: false)
            .path
    }

    static func daemonBinaryPath() -> String {
        Bundle.main.resourceURL?
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("zenban-terminal-daemon", isDirectory: false)
            .path
            ?? "zenban-terminal-daemon"
    }

    static func bridgeBinaryPath() -> String {
        Bundle.main.resourceURL?
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("zenban-terminal-bridge", isDirectory: false)
            .path
            ?? "zenban-terminal-bridge"
    }

    static func runtimePreflightError() -> String? {
        let fileManager = FileManager.default
        let daemonBinaryPath = daemonBinaryPath()
        guard fileManager.isExecutableFile(atPath: daemonBinaryPath) else {
            return "Daemon helper is missing or not executable at \(daemonBinaryPath)"
        }

        let bridgeBinaryPath = bridgeBinaryPath()
        guard fileManager.isExecutableFile(atPath: bridgeBinaryPath) else {
            return "Bridge helper is missing or not executable at \(bridgeBinaryPath)"
        }

        return nil
    }

    static func bridgeCommand(
        sessionID: String,
        cwd: String?,
        sessionKind: ZenbanTerminalRuntimeSessionKind,
        launchCommand: String?
    ) -> String {
        var parts: [String] = [
            ZenbanTerminalRuntimeShell.quoted(bridgeBinaryPath()),
            "--socket-path",
            ZenbanTerminalRuntimeShell.quoted(socketPath()),
            "--session-id",
            ZenbanTerminalRuntimeShell.quoted(sessionID),
            "--session-kind",
            ZenbanTerminalRuntimeShell.quoted(sessionKind.rawValue),
            "--daemon-binary-path",
            ZenbanTerminalRuntimeShell.quoted(daemonBinaryPath()),
        ]
        if let cwd, !cwd.isEmpty {
            parts.append("--cwd")
            parts.append(ZenbanTerminalRuntimeShell.quoted(cwd))
        }
        if let launchCommand, !launchCommand.isEmpty {
            parts.append("--launch-command")
            parts.append(ZenbanTerminalRuntimeShell.quoted(launchCommand))
        }
        return parts.joined(separator: " ")
    }

    static func resolvedShellPath(from env: [String: String]) -> String {
        if let shell = env["SHELL"], !shell.isEmpty {
            return shell
        }
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty {
            return shell
        }
        return "/bin/zsh"
    }

    private static func ensureDaemonAvailable(socketPath: String, daemonBinaryPath: String) async throws {
        if let preflightError = runtimePreflightError() {
            throw NSError(
                domain: "ZenbanTerminalRuntime",
                code: 16,
                userInfo: [NSLocalizedDescriptionKey: preflightError]
            )
        }

        if canConnect(to: socketPath) {
            return
        }

        if FileManager.default.fileExists(atPath: socketPath) {
            try? FileManager.default.removeItem(atPath: socketPath)
        }

        let directoryURL = URL(fileURLWithPath: (socketPath as NSString).deletingLastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: daemonBinaryPath)
        process.arguments = ["--socket-path", socketPath]
        process.standardInput = nil
        process.standardOutput = nil
        process.standardError = nil
        try process.run()

        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(50))
            if canConnect(to: socketPath) {
                return
            }
        }

        throw NSError(
            domain: "ZenbanTerminalRuntime",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for daemon socket at \(socketPath)"]
        )
    }

    private static func performUnaryRequest(
        _ request: ZenbanTerminalRuntimeRequest,
        socketPath: String
    ) async throws -> ZenbanTerminalRuntimeResponse {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let response = try performUnaryRequestSync(request, socketPath: socketPath)
                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func performUnaryRequestSync(
        _ request: ZenbanTerminalRuntimeRequest,
        socketPath: String
    ) throws -> ZenbanTerminalRuntimeResponse {
        let socket = try SocketConnection(path: socketPath)
        defer { socket.close() }
        try socket.write(data: ZenbanTerminalRuntimeProtocol.encodeLine(request))
        let line = try socket.readLine()
        let message = try ZenbanTerminalRuntimeProtocol.decodeMessage(from: line)
        guard case .response(let response) = message else {
            throw NSError(
                domain: "ZenbanTerminalRuntime",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Unexpected daemon message type"]
            )
        }
        if !response.success {
            throw NSError(
                domain: "ZenbanTerminalRuntime",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: response.error ?? "Daemon request failed"]
            )
        }
        return response
    }

    private static func canConnect(to socketPath: String) -> Bool {
        (try? SocketConnection(path: socketPath).close()) != nil
    }
}

private struct SocketConnection {
    private let fileDescriptor: Int32

    init(path: String) throws {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: "ZenbanTerminalRuntime", code: 10, userInfo: [NSLocalizedDescriptionKey: "socket() failed"])
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd)
            throw NSError(domain: "ZenbanTerminalRuntime", code: 11, userInfo: [NSLocalizedDescriptionKey: "Socket path is too long"])
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
            throw NSError(
                domain: "ZenbanTerminalRuntime",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: "connect() failed for \(path)"]
            )
        }

        self.fileDescriptor = fd
    }

    func close() {
        Darwin.shutdown(fileDescriptor, SHUT_RDWR)
        Darwin.close(fileDescriptor)
    }

    func write(data: Data) throws {
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
                throw NSError(domain: "ZenbanTerminalRuntime", code: 13, userInfo: [NSLocalizedDescriptionKey: "write() failed"])
            }
        }
    }

    func readLine() throws -> Data {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                return Data(buffer.prefix(upTo: newlineIndex))
            }

            let count = Darwin.read(fileDescriptor, &chunk, chunk.count)
            if count > 0 {
                buffer.append(chunk, count: count)
                continue
            }
            if count == 0 {
                throw NSError(domain: "ZenbanTerminalRuntime", code: 14, userInfo: [NSLocalizedDescriptionKey: "Socket closed before response"])
            }
            if errno == EINTR {
                continue
            }
            throw NSError(domain: "ZenbanTerminalRuntime", code: 15, userInfo: [NSLocalizedDescriptionKey: "read() failed"])
        }
    }
}
