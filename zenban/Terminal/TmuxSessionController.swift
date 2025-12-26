import Foundation

actor TmuxSessionController {

    enum TmuxError: Error {
        case tmuxNotInstalled
        case sessionCreationFailed(String)
    }

    private let tmuxPath: String

    init() async throws {
        let paths = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        guard let path = paths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw TmuxError.tmuxNotInstalled
        }
        self.tmuxPath = path
    }

    // MARK: - Session Management

    func ensureSession(forCardID cardID: UUID) async throws -> String {
        let sessionName = sessionName(for: cardID)

        if try await sessionExists(sessionName) {
            return sessionName
        }

        try await createSession(sessionName)
        return sessionName
    }

    func sessionExists(_ name: String) async throws -> Bool {
        let result = try await runTmux(["has-session", "-t", name])
        return result.exitCode == 0
    }

    func createSession(_ name: String, workingDirectory: String? = nil) async throws {
        var args = ["new-session", "-d", "-s", name]

        if let dir = workingDirectory {
            args.append(contentsOf: ["-c", dir])
        }

        args.append(contentsOf: ["-x", "120", "-y", "30"])

        let result = try await runTmux(args)
        if result.exitCode != 0 {
            throw TmuxError.sessionCreationFailed(result.stderr)
        }

        // Limit scrollback to prevent disk space issues
        _ = try await runTmux(["set-option", "-t", name, "history-limit", "5000"])
    }

    func killSession(_ name: String) async throws {
        let _ = try await runTmux(["kill-session", "-t", name])
    }

    // MARK: - Helpers

    private func sessionName(for cardID: UUID) -> String {
        "zenban_card_\(cardID.uuidString)"
    }

    private func runTmux(_ args: [String]) async throws -> ProcessResult {
        try await ProcessRunner.run(tmuxPath, arguments: args)
    }
}

struct ProcessResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

enum ProcessRunner {
    static func run(_ path: String, arguments: [String]) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.terminationHandler = { process in
                let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

                continuation.resume(returning: ProcessResult(
                    exitCode: process.terminationStatus,
                    stdout: stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                    stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                ))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
