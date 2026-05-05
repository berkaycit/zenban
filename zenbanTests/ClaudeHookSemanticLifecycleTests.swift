import Darwin
import Foundation
import Testing

@Suite(.serialized)
struct ClaudeHookSemanticLifecycleTests {
    @Test
    func genericNotificationReusesCompletedSummaryUntilPromptSubmitResetsLifecycle() throws {
        let fixture = try makeFixture(name: "reuse-reset")
        defer { fixture.cleanup() }

        let sessionId = "claude-semantic-\(UUID().uuidString)"
        let stop = try runClaudeHook(
            "stop",
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(fixture.workDirectory.path)","hook_event_name":"Stop"}"#,
            fixture: fixture
        )
        #expect(stop.result.status == 0)

        let reused = try runClaudeHook(
            "notification",
            standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"Notification"}"#,
            fixture: fixture
        )
        #expect(reused.result.status == 0)
        let reusedNotify = try latestNotifyCommand(in: reused.commands)
        #expect(reusedNotify.contains("|Completed|"))
        #expect(!reusedNotify.contains("Claude is waiting for your input"))

        let promptSubmit = try runClaudeHook(
            "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"UserPromptSubmit","prompt":"continue"}"#,
            fixture: fixture
        )
        #expect(promptSubmit.result.status == 0)

        let genericAfterReset = try runClaudeHook(
            "notification",
            standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"Notification"}"#,
            fixture: fixture
        )
        #expect(genericAfterReset.result.status == 0)
        let genericNotify = try latestNotifyCommand(in: genericAfterReset.commands)
        #expect(genericNotify.contains("|Waiting|"))
        #expect(!genericNotify.contains("|Completed|"))

        let session = try sessionRecord(sessionId: sessionId, stateDirectory: fixture.stateDirectory)
        #expect(session["lastNotificationKind"] as? String == "genericWaiting")
    }

    @Test
    func legacySessionSummaryWithoutKindSuppressesGenericWaiting() throws {
        let fixture = try makeFixture(name: "legacy-kind")
        defer { fixture.cleanup() }

        let sessionId = "claude-legacy-\(UUID().uuidString)"
        try writeLegacySessionRecord(
            sessionId: sessionId,
            workspaceId: fixture.workspaceId,
            surfaceId: fixture.surfaceId,
            stateDirectory: fixture.stateDirectory
        )

        let result = try runClaudeHook(
            "notification",
            standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"Notification"}"#,
            fixture: fixture
        )
        #expect(result.result.status == 0)

        let notify = try latestNotifyCommand(in: result.commands)
        #expect(notify.contains("|Completed|Legacy completed body"))
        #expect(!notify.contains("Claude is waiting for your input"))
    }

    @Test
    func askUserQuestionSummaryIsNotGenericWaiting() throws {
        let fixture = try makeFixture(name: "ask-question")
        defer { fixture.cleanup() }

        let sessionId = "claude-question-\(UUID().uuidString)"
        let question = "Which deployment target should I use?"
        let preToolUse = try runClaudeHook(
            "pre-tool-use",
            standardInput: """
            {"session_id":"\(sessionId)","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"\(question)","options":[{"label":"macOS 15"},{"label":"macOS 14"}]}]}}
            """,
            fixture: fixture
        )
        #expect(preToolUse.result.status == 0)

        let notification = try runClaudeHook(
            "notification",
            standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"Notification"}"#,
            fixture: fixture
        )
        #expect(notification.result.status == 0)

        let notify = try latestNotifyCommand(in: notification.commands)
        #expect(notify.contains("|Waiting|\(question)"))
        #expect(!notify.contains("Claude is waiting for your input"))

        let session = try sessionRecord(sessionId: sessionId, stateDirectory: fixture.stateDirectory)
        #expect(session["lastNotificationKind"] as? String == "waiting")
    }

    @Test
    func codexStopStoresSemanticKindAndPromptSubmitResetsLifecycle() throws {
        let fixture = try makeFixture(name: "codex-reset")
        defer { fixture.cleanup() }

        let sessionId = "codex-semantic-\(UUID().uuidString)"
        let stop = try runCodexHook(
            "stop",
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(fixture.workDirectory.path)","hook_event_name":"Stop","last_assistant_message":"Codex finished the task"}"#,
            fixture: fixture
        )
        #expect(stop.result.status == 0)

        let notify = try latestNotifyCommand(in: stop.commands)
        #expect(notify.contains("Codex|Completed"))
        #expect(notify.contains("Codex finished the task"))

        let saved = try sessionRecord(
            sessionId: sessionId,
            stateDirectory: fixture.stateDirectory,
            stateFileName: "codex-hook-sessions.json"
        )
        #expect(saved["lastNotificationKind"] as? String == "completed")
        #expect(saved["lastBody"] as? String == "Codex finished the task")

        let promptSubmit = try runCodexHook(
            "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"UserPromptSubmit","prompt":"next task"}"#,
            fixture: fixture
        )
        #expect(promptSubmit.result.status == 0)

        let reset = try sessionRecord(
            sessionId: sessionId,
            stateDirectory: fixture.stateDirectory,
            stateFileName: "codex-hook-sessions.json"
        )
        #expect(reset["lastNotificationKind"] == nil)
        #expect(reset["lastSubtitle"] == nil)
        #expect(reset["lastBody"] == nil)
    }

    @Test
    func codexFailureStopStoresErrorKind() throws {
        let fixture = try makeFixture(name: "codex-error")
        defer { fixture.cleanup() }

        let sessionId = "codex-error-\(UUID().uuidString)"
        let stop = try runCodexHook(
            "stop",
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(fixture.workDirectory.path)","hook_event_name":"Stop","type":"error","error":"usage limit reached"}"#,
            fixture: fixture
        )
        #expect(stop.result.status == 0)

        let notify = try latestNotifyCommand(in: stop.commands)
        #expect(notify.contains("Codex|Rate limit|usage limit reached"))

        let saved = try sessionRecord(
            sessionId: sessionId,
            stateDirectory: fixture.stateDirectory,
            stateFileName: "codex-hook-sessions.json"
        )
        #expect(saved["lastNotificationKind"] as? String == "error")
        #expect(saved["lastSubtitle"] as? String == "Rate limit")
    }

    @Test
    func codexHookUsesLaunchCwdFallbackWhenPayloadOmitsCwd() throws {
        let fixture = try makeFixture(name: "codex-cwd")
        defer { fixture.cleanup() }

        let sessionId = "codex-cwd-\(UUID().uuidString)"
        let stop = try runCodexHook(
            "stop",
            standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"Stop","last_assistant_message":"Done"}"#,
            fixture: fixture,
            extraEnvironment: [
                "CMUX_AGENT_LAUNCH_CWD": fixture.workDirectory.path,
            ]
        )
        #expect(stop.result.status == 0)

        let saved = try sessionRecord(
            sessionId: sessionId,
            stateDirectory: fixture.stateDirectory,
            stateFileName: "codex-hook-sessions.json"
        )
        #expect(saved["cwd"] as? String == fixture.workDirectory.path)
    }

    private struct Fixture {
        let root: URL
        let stateDirectory: URL
        let workDirectory: URL
        let workspaceId: String
        let surfaceId: String
        let cliPath: String

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private struct HookRun {
        let result: ProcessRunResult
        let commands: [String]
    }

    private struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    private final class CommandRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        func append(_ value: String) {
            lock.lock()
            storage.append(value)
            lock.unlock()
        }

        var commands: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private final class BundleMarker {}

    private func makeFixture(name: String) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenban-claude-hook-\(name)-\(UUID().uuidString)", isDirectory: true)
        let stateDirectory = root.appendingPathComponent("state", isDirectory: true)
        let workDirectory = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        return Fixture(
            root: root,
            stateDirectory: stateDirectory,
            workDirectory: workDirectory,
            workspaceId: UUID().uuidString,
            surfaceId: UUID().uuidString,
            cliPath: try bundledCLIPath()
        )
    }

    private func runClaudeHook(
        _ subcommand: String,
        standardInput: String,
        fixture: Fixture
    ) throws -> HookRun {
        try runAgentHook(
            agent: "claude",
            subcommand,
            standardInput: standardInput,
            fixture: fixture
        )
    }

    private func runCodexHook(
        _ subcommand: String,
        standardInput: String,
        fixture: Fixture,
        extraEnvironment: [String: String] = [:]
    ) throws -> HookRun {
        try runAgentHook(
            agent: "codex",
            subcommand,
            standardInput: standardInput,
            fixture: fixture,
            extraEnvironment: extraEnvironment
        )
    }

    private func runAgentHook(
        agent: String,
        _ subcommand: String,
        standardInput: String,
        fixture: Fixture,
        extraEnvironment: [String: String] = [:]
    ) throws -> HookRun {
        let socketPath = makeSocketPath(subcommand)
        let listenerFD = try bindUnixSocket(at: socketPath)
        let recorder = CommandRecorder()
        let serverFinished = startMockServer(listenerFD: listenerFD, recorder: recorder)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = fixture.workspaceId
        environment["CMUX_SURFACE_ID"] = fixture.surfaceId
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = fixture.stateDirectory.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
        for (key, value) in extraEnvironment {
            environment[key] = value
        }

        let result = runProcess(
            executablePath: fixture.cliPath,
            arguments: ["hooks", agent, subcommand],
            environment: environment,
            standardInput: standardInput,
            timeout: 12
        )
        _ = serverFinished.wait(timeout: .now() + 2)
        #expect(!result.timedOut)
        return HookRun(result: result, commands: recorder.commands)
    }

    private func bundledCLIPath() throws -> String {
        let fileManager = FileManager.default
        let direct = Bundle.main.resourceURL?
            .appendingPathComponent("bin/cmux", isDirectory: false)
        if let direct, fileManager.isExecutableFile(atPath: direct.path) {
            return direct.path
        }

        let roots = [
            Bundle.main.bundleURL,
            Bundle(for: BundleMarker.self).bundleURL,
        ]
        for root in roots {
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            while let item = enumerator?.nextObject() as? URL {
                if item.lastPathComponent == "cmux",
                   item.path.contains(".app/Contents/Resources/bin/cmux"),
                   fileManager.isExecutableFile(atPath: item.path) {
                    return item.path
                }
            }
        }
        throw testError("Bundled cmux CLI not found")
    }

    private func makeSocketPath(_ name: String) -> String {
        let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cli-\(name.prefix(6))-\(shortID).sock")
            .path
    }

    private func bindUnixSocket(at path: String) throws -> Int32 {
        unlink(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw testError("socket failed errno=\(errno)") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path)
        let utf8 = Array(path.utf8)
        guard utf8.count < maxPathLength else { throw testError("socket path too long") }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { buffer in
                for index in 0..<utf8.count {
                    buffer[index] = CChar(bitPattern: utf8[index])
                }
                buffer[utf8.count] = 0
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else { throw testError("bind failed errno=\(errno)") }
        guard Darwin.listen(fd, 1) == 0 else { throw testError("listen failed errno=\(errno)") }
        return fd
    }

    private func startMockServer(listenerFD: Int32, recorder: CommandRecorder) -> DispatchSemaphore {
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                }
            }
            guard clientFD >= 0 else {
                finished.signal()
                return
            }
            defer {
                Darwin.close(clientFD)
                finished.signal()
            }

            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(clientFD, &buffer, buffer.count)
                if count < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if count == 0 { return }
                pending.append(buffer, count: count)

                while let newlineRange = pending.firstRange(of: Data([0x0A])) {
                    let lineData = pending.subdata(in: 0..<newlineRange.lowerBound)
                    pending.removeSubrange(0...newlineRange.lowerBound)
                    guard let line = String(data: lineData, encoding: .utf8) else { continue }
                    recorder.append(line)
                    let response = mockResponse(for: line) + "\n"
                    _ = response.withCString { pointer in
                        Darwin.write(clientFD, pointer, strlen(pointer))
                    }
                }
            }
        }
        return finished
    }

    private func mockResponse(for line: String) -> String {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String else {
            return "OK"
        }
        let payload: [String: Any] = ["id": id, "ok": true, "result": [String: Any]()]
        let encoded = try? JSONSerialization.data(withJSONObject: payload)
        return encoded.flatMap { String(data: $0, encoding: .utf8) } ?? #"{"id":"\#(id)","ok":true}"#
    }

    private func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        standardInput: String,
        timeout: TimeInterval
    ) -> ProcessRunResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ProcessRunResult(status: -1, stdout: "", stderr: String(describing: error), timedOut: false)
        }
        stdinPipe.fileHandleForWriting.write(Data(standardInput.utf8))
        try? stdinPipe.fileHandleForWriting.close()

        let exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exitSignal.signal()
        }

        let timedOut = exitSignal.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            _ = exitSignal.wait(timeout: .now() + 1)
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessRunResult(
            status: process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut
        )
    }

    private func latestNotifyCommand(in commands: [String]) throws -> String {
        guard let command = commands.last(where: { $0.hasPrefix("notify_target_async ") }) else {
            throw testError("notify_target_async command not found in \(commands)")
        }
        return command
    }

    private func sessionRecord(
        sessionId: String,
        stateDirectory: URL,
        stateFileName: String = "claude-hook-sessions.json"
    ) throws -> [String: Any] {
        let stateURL = stateDirectory.appendingPathComponent(stateFileName, isDirectory: false)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]
        let sessions = object?["sessions"] as? [String: Any]
        guard let session = sessions?[sessionId] as? [String: Any] else {
            throw testError("session not found")
        }
        return session
    }

    private func writeLegacySessionRecord(
        sessionId: String,
        workspaceId: String,
        surfaceId: String,
        stateDirectory: URL
    ) throws {
        let now = Date().timeIntervalSince1970
        let payload: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": surfaceId,
                    "lastSubtitle": "Completed",
                    "lastBody": "Legacy completed body",
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(
            to: stateDirectory.appendingPathComponent("claude-hook-sessions.json", isDirectory: false),
            options: .atomic
        )
    }

    private func testError(_ message: String) -> NSError {
        NSError(domain: "ClaudeHookSemanticLifecycleTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: message,
        ])
    }
}
