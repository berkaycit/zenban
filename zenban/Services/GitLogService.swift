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

    func getCommitFiles(hash: String, at repoPath: String) async throws -> [CommitFileChange] {
        let result = try await ProcessExecutor.shared.executeWithOutput(
            executable: "/usr/bin/git",
            arguments: ["show", "--format=", "--numstat", hash],
            workingDirectory: repoPath
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
        let result = try await ProcessExecutor.shared.executeWithOutput(
            executable: "/usr/bin/git",
            arguments: ["show", "--format=", hash, "--", filePath],
            workingDirectory: repoPath
        )
        return result.stdout
    }
}

struct CommitFileChange: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let additions: Int
    let deletions: Int
}
