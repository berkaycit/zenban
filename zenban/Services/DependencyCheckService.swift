//
//  DependencyCheckService.swift
//  zenban
//
//  Checks availability of external tools used by optional workflows.
//

import Foundation

actor DependencyCheckService {
    typealias PathProvider = @Sendable () -> String?

    static let shared = DependencyCheckService()

    private static let claudePaths = [
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        "/usr/bin/claude",
    ]

    private let gitPathProvider: PathProvider
    private let claudePathProvider: PathProvider

    enum Dependency: String, CaseIterable {
        case git = "Git"
        case claude = "Claude Code CLI"

        var description: String {
            switch self {
            case .git:
                return "External on this Mac. Used for git history, commit diffs, and shell git probes."
            case .claude:
                return "External on this Mac. Optional for AI commit message generation."
            }
        }
    }

    struct Status: Equatable {
        var git: Bool
        var claude: Bool

        subscript(_ dependency: Dependency) -> Bool {
            switch dependency {
            case .git: git
            case .claude: claude
            }
        }
    }

    init(
        gitPathProvider: @escaping PathProvider = DependencyCheckService.resolveGitPath,
        claudePathProvider: @escaping PathProvider = {
            DependencyCheckService.resolveClaudePath(environment: ProcessEnvironment.buildWithNodeSupport())
        }
    ) {
        self.gitPathProvider = gitPathProvider
        self.claudePathProvider = claudePathProvider
    }

    func checkAll() -> Status {
        Status(
            git: gitPath() != nil,
            claude: claudePath() != nil
        )
    }

    func gitPath() -> String? {
        gitPathProvider()
    }

    func claudePath() -> String? {
        claudePathProvider()
    }

    nonisolated static func resolveGitPath() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--find", "git"]
        process.standardError = FileHandle.nullDevice

        let outputPipe = Pipe()
        process.standardOutput = outputPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let path = String(data: output, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !path.isEmpty,
            FileManager.default.isExecutableFile(atPath: path) else {
            return nil
        }

        return path
    }

    nonisolated static func resolveClaudePath(
        environment: [String: String]? = nil
    ) -> String? {
        ExecutableLocator.resolve(
            "claude",
            candidatePaths: claudePaths,
            environment: environment ?? ProcessEnvironment.buildWithNodeSupport()
        )
    }
}
