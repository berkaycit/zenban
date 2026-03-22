import Foundation

enum GitToolAvailabilityError: Error, LocalizedError {
    case gitUnavailable

    var errorDescription: String? {
        switch self {
        case .gitUnavailable:
            return "Git is unavailable on this Mac. Zenban uses the system git tool for history, commit diffs, and shell git probes."
        }
    }
}

actor GitLogService {
    typealias GitPathProvider = @Sendable () -> String?
    typealias ProcessRunner = @Sendable (_ executable: String, _ arguments: [String], _ workingDirectory: String?) async throws -> ProcessResult

    private let gitPathProvider: GitPathProvider
    private let processRunner: ProcessRunner

    init(
        gitPathProvider: @escaping GitPathProvider = DependencyCheckService.resolveGitPath,
        processRunner: @escaping ProcessRunner = { executable, arguments, workingDirectory in
            try await ProcessExecutor.shared.executeWithOutput(
                executable: executable,
                arguments: arguments,
                workingDirectory: workingDirectory
            )
        }
    ) {
        self.gitPathProvider = gitPathProvider
        self.processRunner = processRunner
    }

    func getCommitHistory(at repoPath: String, limit: Int = 30, skip: Int = 0) async throws -> [GitCommit] {
        _ = try requireGitAvailable()

        return try await Task.detached(priority: .utility) {
            let repo = try Libgit2Repository(path: repoPath)
            let commits = try repo.log(limit: limit, skip: skip)

            return commits.map { commit in
                let stats = try? repo.commitStats(commit.oid)

                return GitCommit(
                    id: commit.oid,
                    shortHash: commit.shortOid,
                    message: commit.summary,
                    author: commit.author.name,
                    date: commit.time,
                    filesChanged: stats?.filesChanged ?? 0,
                    additions: stats?.insertions ?? 0,
                    deletions: stats?.deletions ?? 0
                )
            }
        }.value
    }

    func getCommitDiff(hash: String, at repoPath: String) async throws -> String {
        let gitPath = try requireGitAvailable()
        let result = try await processRunner(
            gitPath,
            ["show", "--format=", hash],
            repoPath
        )
        return result.stdout
    }

    func getCommitFiles(hash: String, at repoPath: String) async throws -> [CommitFileChange] {
        let gitPath = try requireGitAvailable()
        let result = try await processRunner(
            gitPath,
            ["show", "--format=", "--numstat", hash],
            repoPath
        )

        var files: [CommitFileChange] = []
        let lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: true)

        for line in lines {
            let parts = line.split(separator: "\t")
            guard parts.count >= 3 else { continue }

            let additions = Int(parts[0]) ?? 0
            let deletions = Int(parts[1]) ?? 0
            let path = String(parts[2])

            files.append(CommitFileChange(
                path: path,
                additions: additions,
                deletions: deletions
            ))
        }

        return files
    }

    func getCommitFileDiff(hash: String, filePath: String, at repoPath: String) async throws -> String {
        let gitPath = try requireGitAvailable()
        let result = try await processRunner(
            gitPath,
            ["show", "--format=", hash, "--", filePath],
            repoPath
        )
        return result.stdout
    }

    private func requireGitAvailable() throws -> String {
        guard let gitPath = gitPathProvider() else {
            throw GitToolAvailabilityError.gitUnavailable
        }
        return gitPath
    }
}

struct CommitFileChange: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let additions: Int
    let deletions: Int
}
