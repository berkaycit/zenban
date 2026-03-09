import AppKit
import Foundation
import OSLog

actor TmuxSessionManager {
    static let shared = TmuxSessionManager()

    private static let logger = Logger(subsystem: "com.berkaycit.zenban", category: "TmuxSessionManager")
    private static let candidatePaths = [
        "/opt/homebrew/bin/tmux",
        "/usr/local/bin/tmux",
        "/usr/bin/tmux",
    ]
    private static let sessionPrefix = "zenban-panel-"
    private static let socketName = "zenban"
    private static let configPath: String = {
        let zenbanDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".zenban", isDirectory: true)
        return zenbanDir.appendingPathComponent("tmux.conf", isDirectory: false).path
    }()
    private var sessionActivityCache: [String: Int] = [:]

    private init() {
        Task {
            await updateConfig()
        }
    }

    nonisolated func isTmuxAvailable() -> Bool {
        tmuxPath() != nil
    }

    nonisolated func tmuxPath() -> String? {
        if let path = Self.candidatePaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return path
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["tmux"]
        process.standardOutput = Pipe()
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let pipe = process.standardOutput as? Pipe else {
                return nil
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let path, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else {
                return nil
            }
            return path
        } catch {
            return nil
        }
    }

    func updateConfig() async {
        let config = await MainActor.run { GhosttyConfig.load() }
        writeConfigSync(contents: Self.configContents(from: config))
        sourceConfigIfPossible()
    }

    nonisolated func sessionName(for sessionID: String) -> String {
        Self.sessionPrefix + sessionID
    }

    nonisolated func attachOrCreateCommand(sessionID: String, workingDirectory: String?) -> String? {
        guard let tmux = tmuxPath() else { return nil }
        let sessionName = sessionName(for: sessionID)
        let escapedConfig = Self.escapeForShell(Self.configPath)
        let escapedDirectory = Self.escapeForShell(
            (workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? workingDirectory
                : FileManager.default.homeDirectoryForCurrentUser.path) ?? FileManager.default.homeDirectoryForCurrentUser.path
        )

        return "\(tmux) -L \(Self.socketName) -f '\(escapedConfig)' new-session -A -s \(sessionName) -c '\(escapedDirectory)' -e ZENBAN_TERMINAL=1"
    }

    nonisolated func sessionExistsSync(sessionID: String) -> Bool {
        guard let status = runSync(arguments: tmuxArguments("has-session", "-t", sessionName(for: sessionID))) else {
            return false
        }
        return status.terminationStatus == 0
    }

    nonisolated func isRecentActivity(_ activityTimestamp: Int, thresholdSeconds: Int = 2) -> Bool {
        let now = Int(Date().timeIntervalSince1970)
        return now - activityTimestamp < thresholdSeconds
    }

    @discardableResult
    nonisolated func sendKeys(sessionID: String, keys: String, execute: Bool = false) -> Bool {
        guard !keys.isEmpty else { return true }

        guard let sendResult = runSync(
            arguments: tmuxArguments("send-keys", "-t", sessionName(for: sessionID), keys),
            failureMessage: "Failed to send keys to tmux session \(sessionName(for: sessionID))"
        ), sendResult.terminationStatus == 0 else {
            return false
        }
        if execute {
            guard let enterResult = runSync(
                arguments: tmuxArguments("send-keys", "-t", sessionName(for: sessionID), "Enter"),
                failureMessage: "Failed to send Enter to tmux session \(sessionName(for: sessionID))"
            ), enterResult.terminationStatus == 0 else {
                return false
            }
        }
        return true
    }

    @discardableResult
    nonisolated func sendText(sessionID: String, text: String) -> Bool {
        guard !text.isEmpty else { return true }

        if text == "\u{03}" {
            return sendKeys(sessionID: sessionID, keys: "C-c", execute: false)
        }

        let segments = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let shouldAppendTrailingEnter = text.hasSuffix("\n")
        let sessionName = sessionName(for: sessionID)

        for (index, segment) in segments.enumerated() {
            if !segment.isEmpty {
                guard let literalResult = runSync(
                    arguments: tmuxArguments("send-keys", "-t", sessionName, "-l", segment),
                    failureMessage: "Failed to send literal text to tmux session \(sessionName)"
                ), literalResult.terminationStatus == 0 else {
                    return false
                }
            }

            let isLastSegment = index == segments.count - 1
            if !isLastSegment || shouldAppendTrailingEnter {
                guard let enterResult = runSync(
                    arguments: tmuxArguments("send-keys", "-t", sessionName, "Enter"),
                    failureMessage: "Failed to send Enter to tmux session \(sessionName)"
                ), enterResult.terminationStatus == 0 else {
                    return false
                }
            }
        }

        return true
    }

    func unsetEnvironment(sessionID: String, names: [String]) {
        let sessionName = sessionName(for: sessionID)
        for key in names where !key.isEmpty {
            _ = runSync(arguments: tmuxArguments("set-environment", "-t", sessionName, "-r", key))
        }
    }

    func setEnvironment(sessionID: String, variables: [String: String]) {
        let sessionName = sessionName(for: sessionID)
        for (key, value) in variables where !key.isEmpty {
            _ = runSync(
                arguments: tmuxArguments("set-environment", "-t", sessionName, key, value),
                failureMessage: "Failed to set tmux environment on session \(sessionName)"
            )
        }
    }

    func capturePane(
        sessionID: String,
        startLine: Int = -100,
        endLine: Int? = nil,
        escape: Bool = true,
        joinLines: Bool = true
    ) throws -> String {
        var arguments = [
            "capture-pane",
            "-t",
            sessionName(for: sessionID),
            "-p",
            "-S",
            String(startLine),
        ]
        if let endLine {
            arguments += ["-E", String(endLine)]
        }
        if escape {
            arguments.append("-e")
        }
        if joinLines {
            arguments.append("-J")
        }

        guard let result = runSync(
            arguments: tmuxArguments(arguments),
            failureMessage: "Failed to capture tmux pane \(sessionName(for: sessionID))"
        ) else {
            throw TmuxError.captureFailed
        }
        guard result.terminationStatus == 0 else {
            throw TmuxError.captureFailed
        }
        return result.output
    }

    func refreshSessionActivityCache() -> [String: Int] {
        let snapshot = refreshSessionActivity()
        sessionActivityCache = snapshot
        return snapshot
    }

    func refreshSessionActivity() -> [String: Int] {
        guard let result = runSync(
            arguments: tmuxArguments("list-windows", "-a", "-F", "#{session_name}\t#{window_activity}")
        ),
        result.terminationStatus == 0 else {
            return [:]
        }

        var sessions: [String: Int] = [:]
        for line in result.output.components(separatedBy: .newlines) where !line.isEmpty {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard let name = parts.first, !name.isEmpty else { continue }
            let activity = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            let existing = sessions[name] ?? 0
            if activity > existing {
                sessions[name] = activity
            }
        }
        return sessions
    }

    func cachedSessionActivity() -> [String: Int] {
        sessionActivityCache
    }

    func killSession(sessionID: String) {
        _ = runSync(
            arguments: tmuxArguments("kill-session", "-t", sessionName(for: sessionID)),
            failureMessage: "Failed to kill tmux session \(sessionName(for: sessionID))"
        )
    }

    func killAllZenbanSessions() {
        for session in listZenbanSessionsSync() {
            _ = runSync(
                arguments: tmuxArguments("kill-session", "-t", session),
                failureMessage: "Failed to kill tmux session \(session)"
            )
        }
    }

    nonisolated func killAllZenbanSessionsSync() {
        for session in listZenbanSessionsSync() {
            _ = runSync(arguments: tmuxArguments("kill-session", "-t", session))
        }
    }

    nonisolated private func listZenbanSessionsSync() -> [String] {
        guard let result = runSync(arguments: tmuxArguments("list-sessions", "-F", "#{session_name}")),
              result.terminationStatus == 0 else {
            return []
        }

        return result.output
            .components(separatedBy: .newlines)
            .filter { $0.hasPrefix(Self.sessionPrefix) }
    }

    private func writeConfigSync(contents: String) {
        let configURL = URL(fileURLWithPath: Self.configPath)
        let directoryURL = configURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try contents.write(to: configURL, atomically: true, encoding: .utf8)
        } catch {
            Self.logger.error("Failed to write tmux config: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func sourceConfigIfPossible() {
        _ = runSync(arguments: tmuxArguments("source-file", Self.configPath))
    }

    nonisolated private func tmuxArguments(_ arguments: String...) -> [String] {
        tmuxArguments(arguments)
    }

    nonisolated private func tmuxArguments(_ arguments: [String]) -> [String] {
        ["-L", Self.socketName, "-f", Self.configPath] + arguments
    }

    nonisolated private func runSync(
        arguments: [String],
        failureMessage: String? = nil
    ) -> (terminationStatus: Int32, output: String)? {
        guard let tmux = tmuxPath() else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmux)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return (process.terminationStatus, output)
        } catch {
            if let failureMessage {
                Self.logger.error("\(failureMessage, privacy: .public)")
            }
            return nil
        }
    }

    private static func configContents(from config: GhosttyConfig) -> String {
        let selectionForeground = config.selectionForeground.hexString()
        let selectionBackground = config.selectionBackground.hexString()

        return """
        # Zenban tmux configuration
        # This file is auto-generated - changes will be overwritten

        set -as terminal-features ",*:hyperlinks"
        set -g allow-passthrough on
        set -g status off
        set -g history-limit 10000
        set -g mouse on
        set -g default-terminal "xterm-256color"
        set -ag terminal-overrides ",xterm-256color:RGB"
        set -g mode-style "fg=\(selectionForeground),bg=\(selectionBackground)"
        bind -n WheelUpPane if -F '#{||:#{mouse_any_flag},#{alternate_on}}' 'send-keys -M' 'copy-mode -eH; send-keys -M'
        bind -n WheelDownPane if -F '#{||:#{mouse_any_flag},#{alternate_on}}' 'send-keys -M' 'send-keys -M'
        """
    }

    private static func escapeForShell(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "'\\''")
    }

    enum TmuxError: Error {
        case captureFailed
    }
}
