//
//  DependencyCheckService.swift
//  zenban
//
//  Checks and installs runtime dependencies
//

import Foundation
import OSLog

/// Actor that checks and installs runtime dependencies
actor DependencyCheckService {
    static let shared = DependencyCheckService()

    private static let logger = Logger(subsystem: "com.berkaycit.zenban", category: "DependencyCheckService")

    private static let homebrewPaths = [
        "/opt/homebrew/bin/brew",  // Apple Silicon
        "/usr/local/bin/brew"      // Intel
    ]

    private static let ghPaths = [
        "/opt/homebrew/bin/gh",
        "/usr/local/bin/gh"
    ]

    private static let claudePaths = [
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        "/usr/bin/claude"
    ]

    enum Dependency: String, CaseIterable {
        case homebrew = "Homebrew"
        case tmux = "tmux"
        case gh = "GitHub CLI"
        case claude = "Claude Code CLI"

        var description: String {
            switch self {
            case .homebrew: "Package manager for macOS"
            case .tmux: "Terminal session persistence"
            case .gh: "Pull request creation"
            case .claude: "AI commit messages"
            }
        }

        var isRequired: Bool {
            switch self {
            case .homebrew, .tmux: true
            case .gh, .claude: false
            }
        }
    }

    struct Status: Equatable {
        var homebrew: Bool
        var tmux: Bool
        var gh: Bool
        var claude: Bool

        var allRequired: Bool { homebrew && tmux }
        var allSatisfied: Bool { homebrew && tmux && gh && claude }

        subscript(_ dependency: Dependency) -> Bool {
            switch dependency {
            case .homebrew: homebrew
            case .tmux: tmux
            case .gh: gh
            case .claude: claude
            }
        }
    }

    private init() {}

    // MARK: - Dependency Checks

    nonisolated func checkAll() -> Status {
        Status(
            homebrew: homebrewPath() != nil,
            tmux: TmuxSessionManager.shared.isTmuxAvailable(),
            gh: ghPath() != nil,
            claude: claudePath() != nil
        )
    }

    nonisolated func homebrewPath() -> String? {
        Self.homebrewPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    nonisolated func ghPath() -> String? {
        Self.ghPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    nonisolated func claudePath() -> String? {
        Self.claudePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - Installation

    func installHomebrew(outputHandler: @escaping @Sendable (String) -> Void) async throws {
        Self.logger.info("Starting Homebrew installation")
        outputHandler("Installing Homebrew...\n")

        try await runInstallCommand(
            command: "/bin/bash",
            arguments: ["-c", "curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh | bash"],
            outputHandler: outputHandler
        )

        guard homebrewPath() != nil else {
            outputHandler("\nHomebrew installation may have failed. Please check the output above.\n")
            throw DependencyError.installationFailed("Homebrew")
        }
        outputHandler("\nHomebrew installed successfully.\n")
        Self.logger.info("Homebrew installation completed")
    }

    func installTmux(outputHandler: @escaping @Sendable (String) -> Void) async throws {
        guard let brewPath = homebrewPath() else {
            throw DependencyError.homebrewRequired
        }

        Self.logger.info("Starting tmux installation")
        outputHandler("Installing tmux...\n")

        try await runInstallCommand(
            command: brewPath,
            arguments: ["install", "tmux"],
            outputHandler: outputHandler
        )

        guard TmuxSessionManager.shared.isTmuxAvailable() else {
            outputHandler("\ntmux installation may have failed. Please check the output above.\n")
            throw DependencyError.installationFailed("tmux")
        }
        outputHandler("\ntmux installed successfully.\n")
        Self.logger.info("tmux installation completed")
    }

    func installGh(outputHandler: @escaping @Sendable (String) -> Void) async throws {
        guard let brewPath = homebrewPath() else {
            throw DependencyError.homebrewRequired
        }

        Self.logger.info("Starting GitHub CLI installation")
        outputHandler("Installing GitHub CLI...\n")

        try await runInstallCommand(
            command: brewPath,
            arguments: ["install", "gh"],
            outputHandler: outputHandler
        )

        guard ghPath() != nil else {
            outputHandler("\nGitHub CLI installation may have failed. Please check the output above.\n")
            throw DependencyError.installationFailed("GitHub CLI")
        }
        outputHandler("\nGitHub CLI installed successfully.\n")
        Self.logger.info("GitHub CLI installation completed")
    }

    func installClaude(outputHandler: @escaping @Sendable (String) -> Void) async throws {
        Self.logger.info("Starting Claude Code CLI installation")
        outputHandler("Installing Claude Code CLI...\n")

        // Use npm with node environment support
        var env = ProcessEnvironment.buildWithNodeSupport()
        env["NONINTERACTIVE"] = "1"

        try await runInstallCommand(
            command: "/bin/bash",
            arguments: ["-c", "npm install -g @anthropic-ai/claude-code"],
            environment: env,
            outputHandler: outputHandler
        )

        guard claudePath() != nil else {
            outputHandler("\nClaude Code CLI installation may have failed. Please check the output above.\n")
            throw DependencyError.installationFailed("Claude Code CLI")
        }
        outputHandler("\nClaude Code CLI installed successfully.\n")
        Self.logger.info("Claude Code CLI installation completed")
    }

    func installMissing(outputHandler: @escaping @Sendable (String) -> Void) async throws {
        let status = checkAll()

        if !status.homebrew {
            try await installHomebrew(outputHandler: outputHandler)
            outputHandler("\n")
        }

        if !status.tmux {
            try await installTmux(outputHandler: outputHandler)
            outputHandler("\n")
        }

        if !status.gh {
            try await installGh(outputHandler: outputHandler)
            outputHandler("\n")
        }

        if !status.claude {
            try await installClaude(outputHandler: outputHandler)
        }

        let finalStatus = checkAll()
        if finalStatus.allSatisfied {
            outputHandler("\nAll dependencies installed successfully.\n")
        }
    }

    // MARK: - Private Helpers

    private func runInstallCommand(
        command: String,
        arguments: [String],
        environment: [String: String]? = nil,
        outputHandler: @escaping @Sendable (String) -> Void
    ) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments

        // Set up environment for non-interactive installation
        var env = environment ?? ProcessInfo.processInfo.environment
        env["NONINTERACTIVE"] = "1"
        env["CI"] = "1"
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Handle stdout
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let str = String(data: data, encoding: .utf8) {
                Task { @MainActor in
                    outputHandler(str)
                }
            }
        }

        // Handle stderr
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let str = String(data: data, encoding: .utf8) {
                Task { @MainActor in
                    outputHandler(str)
                }
            }
        }

        do {
            try process.run()
        } catch {
            Self.logger.error("Failed to start installation process: \(error.localizedDescription)")
            throw DependencyError.processStartFailed(error.localizedDescription)
        }

        // Wait for process to complete
        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in
                continuation.resume()
            }
        }

        // Clean up handlers
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        if process.terminationStatus != 0 {
            Self.logger.warning("Installation process exited with status: \(process.terminationStatus)")
            // Don't throw here - let the verification step determine success
        }
    }
}

// MARK: - Errors

enum DependencyError: Error, LocalizedError {
    case homebrewRequired
    case installationFailed(String)
    case processStartFailed(String)

    var errorDescription: String? {
        switch self {
        case .homebrewRequired:
            return "Homebrew must be installed first"
        case .installationFailed(let name):
            return "\(name) installation failed"
        case .processStartFailed(let reason):
            return "Failed to start installation: \(reason)"
        }
    }
}
