//
//  DependencyCheckService.swift
//  zenban
//
//  Checks and installs required dependencies (Homebrew, tmux)
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

    enum Dependency: String, CaseIterable {
        case homebrew = "Homebrew"
        case tmux = "tmux"

        var description: String {
            switch self {
            case .homebrew: "Package manager for macOS"
            case .tmux: "Terminal session persistence"
            }
        }
    }

    struct Status: Equatable {
        var homebrew: Bool
        var tmux: Bool

        var allSatisfied: Bool { homebrew && tmux }
    }

    private init() {}

    // MARK: - Dependency Checks

    nonisolated func checkAll() -> Status {
        Status(homebrew: homebrewPath() != nil, tmux: TmuxSessionManager.shared.isTmuxAvailable())
    }

    nonisolated func homebrewPath() -> String? {
        Self.homebrewPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
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

    /// Install all missing dependencies in order
    func installMissing(outputHandler: @escaping @Sendable (String) -> Void) async throws {
        let status = checkAll()

        if !status.homebrew {
            try await installHomebrew(outputHandler: outputHandler)
            outputHandler("\n")
        }

        if !status.tmux {
            try await installTmux(outputHandler: outputHandler)
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
        outputHandler: @escaping @Sendable (String) -> Void
    ) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments

        // Set up environment for non-interactive installation
        var env = ProcessInfo.processInfo.environment
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
