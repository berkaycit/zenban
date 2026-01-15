import Foundation

actor GitLogService {
    func getCommitHistory(at repoPath: String, limit: Int = 30, skip: Int = 0) async throws -> [GitCommit] {
        try await Task.detached(priority: .utility) {
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
        let result = try await ProcessExecutor.shared.executeWithOutput(
            executable: "/usr/bin/git",
            arguments: ["show", "--format=", hash],
            workingDirectory: repoPath
        )
        return result.stdout
    }
}
