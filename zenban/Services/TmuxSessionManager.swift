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
    private static let configPath: String = {
        let zenbanDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".zenban", isDirectory: true)
        return zenbanDir.appendingPathComponent("tmux.conf", isDirectory: false).path
    }()

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

        return "\(tmux) -f '\(escapedConfig)' new-session -A -s \(sessionName) -c '\(escapedDirectory)' -e ZENBAN_TERMINAL=1"
    }

    nonisolated func sessionExistsSync(sessionID: String) -> Bool {
        guard let tmux = tmuxPath() else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmux)
        process.arguments = ["has-session", "-t", sessionName(for: sessionID)]
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    nonisolated func sendKeys(sessionID: String, keys: String, execute: Bool = false) {
        guard !keys.isEmpty, let tmux = tmuxPath() else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmux)
        var arguments = ["send-keys", "-t", sessionName(for: sessionID), keys]
        if execute {
            arguments.append("Enter")
        }
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            Self.logger.error("Failed to send keys to tmux session \(self.sessionName(for: sessionID), privacy: .public)")
        }
    }

    nonisolated func sendText(sessionID: String, text: String) {
        guard !text.isEmpty, let tmux = tmuxPath() else { return }

        if text == "\u{03}" {
            sendKeys(sessionID: sessionID, keys: "C-c", execute: false)
            return
        }

        let segments = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let shouldAppendTrailingEnter = text.hasSuffix("\n")

        for (index, segment) in segments.enumerated() {
            if !segment.isEmpty {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: tmux)
                process.arguments = ["send-keys", "-t", sessionName(for: sessionID), "-l", segment]
                process.standardError = FileHandle.nullDevice

                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    Self.logger.error("Failed to send literal text to tmux session \(self.sessionName(for: sessionID), privacy: .public)")
                    return
                }
            }

            let isLastSegment = index == segments.count - 1
            if !isLastSegment || shouldAppendTrailingEnter {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: tmux)
                process.arguments = ["send-keys", "-t", sessionName(for: sessionID), "Enter"]
                process.standardError = FileHandle.nullDevice

                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    Self.logger.error("Failed to send Enter to tmux session \(self.sessionName(for: sessionID), privacy: .public)")
                    return
                }
            }
        }
    }

    func killSession(sessionID: String) {
        guard let tmux = tmuxPath() else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmux)
        process.arguments = ["kill-session", "-t", sessionName(for: sessionID)]
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            Self.logger.error("Failed to kill tmux session \(self.sessionName(for: sessionID), privacy: .public)")
        }
    }

    func killAllZenbanSessions() {
        for session in listZenbanSessionsSync() {
            let process = Process()
            guard let tmux = tmuxPath() else { return }
            process.executableURL = URL(fileURLWithPath: tmux)
            process.arguments = ["kill-session", "-t", session]
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                Self.logger.error("Failed to kill tmux session \(session, privacy: .public)")
            }
        }
    }

    nonisolated func killAllZenbanSessionsSync() {
        guard let tmux = tmuxPath() else { return }

        for session in listZenbanSessionsSync() {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tmux)
            process.arguments = ["kill-session", "-t", session]
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                continue
            }
        }
    }

    nonisolated private func listZenbanSessionsSync() -> [String] {
        guard let tmux = tmuxPath() else { return [] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmux)
        process.arguments = ["list-sessions", "-F", "#{session_name}"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return [] }
            return output
                .components(separatedBy: .newlines)
                .filter { $0.hasPrefix(Self.sessionPrefix) }
        } catch {
            return []
        }
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
        guard let tmux = tmuxPath() else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmux)
        process.arguments = ["source-file", Self.configPath]
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            Self.logger.error("Failed to source tmux config: \(error.localizedDescription, privacy: .public)")
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
}
