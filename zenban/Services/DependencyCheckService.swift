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

    private static let tmuxPaths = [
        "/opt/homebrew/bin/tmux",
        "/usr/local/bin/tmux",
        "/usr/bin/tmux"
    ]

    private static let ghPaths = [
        "/opt/homebrew/bin/gh",
        "/usr/local/bin/gh"
    ]

    private static let npmPaths = [
        "/opt/homebrew/bin/npm",
        "/usr/local/bin/npm",
        "/usr/bin/npm"
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
            case .homebrew: "Package manager used to install runtime tools"
            case .tmux: "Keeps card terminals alive while their UI is hidden"
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
        var hasMissingOptionalDependencies: Bool { !gh || !claude }
        var hasMissingDependencies: Bool { !allSatisfied }

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
            tmux: tmuxPath() != nil,
            gh: ghPath() != nil,
            claude: claudePath() != nil
        )
    }

    nonisolated func homebrewPath() -> String? {
        Self.homebrewPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    nonisolated func tmuxPath() -> String? {
        ExecutableLocator.resolve(
            "tmux",
            candidatePaths: Self.tmuxPaths,
            environment: ProcessEnvironment.buildWithNodeSupport()
        )
    }

    nonisolated func ghPath() -> String? {
        Self.ghPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    nonisolated func npmPath() -> String? {
        ExecutableLocator.resolve(
            "npm",
            candidatePaths: Self.npmPaths,
            environment: ProcessEnvironment.buildWithNodeSupport()
        )
    }

    nonisolated func claudePath() -> String? {
        ExecutableLocator.resolve(
            "claude",
            candidatePaths: Self.claudePaths,
            environment: ProcessEnvironment.buildWithNodeSupport()
        )
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

        guard tmuxPath() != nil else {
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

    func installNode(outputHandler: @escaping @Sendable (String) -> Void) async throws {
        guard let brewPath = homebrewPath() else {
            throw DependencyError.homebrewRequired
        }

        Self.logger.info("Starting Node.js installation")
        outputHandler("Installing Node.js...\n")

        try await runInstallCommand(
            command: brewPath,
            arguments: ["install", "node"],
            outputHandler: outputHandler
        )

        guard npmPath() != nil else {
            outputHandler("\nNode.js installation may have failed. Please check the output above.\n")
            throw DependencyError.installationFailed("Node.js")
        }
        outputHandler("\nNode.js installed successfully.\n")
        Self.logger.info("Node.js installation completed")
    }

    func installClaude(outputHandler: @escaping @Sendable (String) -> Void) async throws {
        Self.logger.info("Starting Claude Code CLI installation")

        // Step 1: Ensure npm is available (install Node.js if needed)
        if npmPath() == nil {
            outputHandler("Node.js/npm not found. Installing Node.js first...\n\n")
            try await installNode(outputHandler: outputHandler)
            outputHandler("\n")
        }

        // Step 2: Get npm path
        guard let npm = npmPath() else {
            outputHandler("Error: Could not find npm after Node.js installation.\n")
            outputHandler("Please install Node.js manually and try again.\n")
            throw DependencyError.installationFailed("Node.js")
        }

        // Step 3: Install Claude Code CLI using npm directly
        outputHandler("Installing Claude Code CLI...\n")

        var env = ProcessEnvironment.buildWithNodeSupport()
        env["NONINTERACTIVE"] = "1"

        try await runInstallCommand(
            command: npm,
            arguments: ["install", "-g", "@anthropic-ai/claude-code"],
            environment: env,
            outputHandler: outputHandler
        )

        // Step 4: Brief delay to allow filesystem to update
        try await Task.sleep(for: .milliseconds(500))

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
