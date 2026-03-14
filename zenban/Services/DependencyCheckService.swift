//
//  DependencyCheckService.swift
//  zenban
//
//  Checks and installs optional runtime tools
//

import Foundation
import OSLog

actor DependencyCheckService {
    static let shared = DependencyCheckService()

    private static let logger = Logger(subsystem: "com.berkaycit.zenban", category: "DependencyCheckService")

    private static let homebrewPaths = [
        "/opt/homebrew/bin/brew",
        "/usr/local/bin/brew",
    ]

    private static let ghPaths = [
        "/opt/homebrew/bin/gh",
        "/usr/local/bin/gh",
    ]

    private static let npmPaths = [
        "/opt/homebrew/bin/npm",
        "/usr/local/bin/npm",
        "/usr/bin/npm",
    ]

    private static let claudePaths = [
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        "/usr/bin/claude",
    ]

    enum Dependency: String, CaseIterable {
        case homebrew = "Homebrew"
        case gh = "GitHub CLI"
        case claude = "Claude Code CLI"

        var description: String {
            switch self {
            case .homebrew: "Installer used to add optional developer tools"
            case .gh: "Pull request creation"
            case .claude: "AI commit messages"
            }
        }

        var isRequired: Bool {
            false
        }
    }

    struct Status: Equatable {
        var homebrew: Bool
        var gh: Bool
        var claude: Bool

        var allRequired: Bool { true }
        var allSatisfied: Bool { homebrew && gh && claude }
        var hasMissingOptionalDependencies: Bool { !allSatisfied }
        var hasMissingDependencies: Bool { !allSatisfied }

        subscript(_ dependency: Dependency) -> Bool {
            switch dependency {
            case .homebrew: homebrew
            case .gh: gh
            case .claude: claude
            }
        }
    }

    private init() {}

    nonisolated func checkAll() -> Status {
        Status(
            homebrew: homebrewPath() != nil,
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

        if npmPath() == nil {
            outputHandler("Node.js/npm not found. Installing Node.js first...\n\n")
            try await installNode(outputHandler: outputHandler)
            outputHandler("\n")
        }

        guard let npm = npmPath() else {
            outputHandler("Error: Could not find npm after Node.js installation.\n")
            outputHandler("Please install Node.js manually and try again.\n")
            throw DependencyError.installationFailed("Node.js")
        }

        outputHandler("Installing Claude Code CLI...\n")

        var env = ProcessEnvironment.buildWithNodeSupport()
        env["NONINTERACTIVE"] = "1"

        try await runInstallCommand(
            command: npm,
            arguments: ["install", "-g", "@anthropic-ai/claude-code"],
            environment: env,
            outputHandler: outputHandler
        )

        try await Task.sleep(for: .milliseconds(500))

        guard claudePath() != nil else {
            outputHandler("\nClaude Code CLI installation may have failed. Please check the output above.\n")
            throw DependencyError.installationFailed("Claude Code CLI")
        }
        outputHandler("\nClaude Code CLI installed successfully.\n")
        Self.logger.info("Claude Code CLI installation completed")
    }

    func installMissing(outputHandler: @escaping @Sendable (String) -> Void) async throws {
        var status = checkAll()

        if !status.homebrew {
            try await installHomebrew(outputHandler: outputHandler)
            outputHandler("\n")
            status = checkAll()
        }

        if !status.gh {
            try await installGh(outputHandler: outputHandler)
            outputHandler("\n")
        }

        if !status.claude {
            try await installClaude(outputHandler: outputHandler)
        }

        if checkAll().allSatisfied {
            outputHandler("\nAll optional tools are installed.\n")
        }
    }

    private func runInstallCommand(
        command: String,
        arguments: [String],
        environment: [String: String]? = nil,
        outputHandler: @escaping @Sendable (String) -> Void
    ) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments

        var env = environment ?? ProcessInfo.processInfo.environment
        env["NONINTERACTIVE"] = "1"
        env["CI"] = "1"
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let str = String(data: data, encoding: .utf8) {
                Task { @MainActor in
                    outputHandler(str)
                }
            }
        }

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

        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in
                continuation.resume()
            }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        if process.terminationStatus != 0 {
            Self.logger.warning("Installation process exited with status: \(process.terminationStatus)")
        }
    }
}

enum DependencyError: Error, LocalizedError {
    case homebrewRequired
    case installationFailed(String)
    case processStartFailed(String)

    var errorDescription: String? {
        switch self {
        case .homebrewRequired:
            "Homebrew is required to install optional tools automatically."
        case .installationFailed(let name):
            "Failed to install \(name)."
        case .processStartFailed(let reason):
            "Failed to start installation: \(reason)"
        }
    }
}
