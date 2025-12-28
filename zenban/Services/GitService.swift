import Foundation

enum GitError: Error, LocalizedError {
    case initFailed
    case directoryCreationFailed
    case directoryAlreadyExists
    case worktreeCreationFailed(String)
    case worktreeDeletionFailed(String)
    case branchDeletionFailed(String)

    var errorDescription: String? {
        switch self {
        case .initFailed:
            return "Failed to initialize git repository"
        case .directoryCreationFailed:
            return "Failed to create directory"
        case .directoryAlreadyExists:
            return "Directory already exists"
        case .worktreeCreationFailed(let msg):
            return "Failed to create worktree: \(msg)"
        case .worktreeDeletionFailed(let msg):
            return "Failed to delete worktree: \(msg)"
        case .branchDeletionFailed(let msg):
            return "Failed to delete branch: \(msg)"
        }
    }
}

struct GitService {
    private struct WorktreePaths {
        let branch: String
        let directory: String

        init(cardID: UUID, repositoryPath: String) {
            branch = "card/\(cardID.uuidString)"
            let repoParent = (repositoryPath as NSString).deletingLastPathComponent
            let worktreesDir = (repoParent as NSString).appendingPathComponent("repo-worktrees")
            directory = (worktreesDir as NSString).appendingPathComponent(branch)
        }
    }

    static func createRepository(name: String, parentPath: String) async throws -> String {
        let repoPath = (parentPath as NSString).appendingPathComponent(name)
        let fileManager = FileManager.default

        guard !fileManager.fileExists(atPath: repoPath) else {
            throw GitError.directoryAlreadyExists
        }

        do {
            try fileManager.createDirectory(atPath: repoPath, withIntermediateDirectories: false)
        } catch {
            throw GitError.directoryCreationFailed
        }

        return try await runGitCommand(
            args: ["init"],
            directory: repoPath,
            errorMapper: { _ in .initFailed },
            successResult: repoPath
        )
    }

    static func createWorktree(cardID: UUID, repositoryPath: String) async throws -> String {
        let paths = WorktreePaths(cardID: cardID, repositoryPath: repositoryPath)
        let parentDir = (paths.directory as NSString).deletingLastPathComponent

        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: parentDir) {
            try fileManager.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
        }

        await pruneAndCleanup(paths: paths, repositoryPath: repositoryPath)

        return try await runGitCommand(
            args: ["worktree", "add", "-b", paths.branch, paths.directory],
            directory: repositoryPath,
            errorMapper: { .worktreeCreationFailed($0) },
            successResult: paths.directory
        )
    }

    static func deleteWorktree(cardID: UUID, repositoryPath: String) async {
        let paths = WorktreePaths(cardID: cardID, repositoryPath: repositoryPath)
        await pruneAndCleanup(paths: paths, repositoryPath: repositoryPath)
    }

    static func isGitRepository(path: String) -> Bool {
        let gitPath = (path as NSString).appendingPathComponent(".git")
        return FileManager.default.fileExists(atPath: gitPath)
    }

    /// Cleans up stale worktree entries, removes worktree registration, deletes branch, and removes directory
    private static func pruneAndCleanup(paths: WorktreePaths, repositoryPath: String) async {
        _ = try? await runGitCommand(
            args: ["worktree", "prune"],
            directory: repositoryPath,
            errorMapper: { _ in GitError.worktreeDeletionFailed("") },
            successResult: ()
        )

        _ = try? await runGitCommand(
            args: ["worktree", "remove", "--force", paths.directory],
            directory: repositoryPath,
            errorMapper: { _ in GitError.worktreeDeletionFailed("") },
            successResult: ()
        )

        _ = try? await runGitCommand(
            args: ["branch", "-D", paths.branch],
            directory: repositoryPath,
            errorMapper: { _ in GitError.branchDeletionFailed("") },
            successResult: ()
        )

        try? FileManager.default.removeItem(atPath: paths.directory)
    }

    private static func runGitCommand<T>(
        args: [String],
        directory: String,
        errorMapper: @escaping (String) -> GitError,
        successResult: T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = args
                process.currentDirectoryURL = URL(fileURLWithPath: directory)

                let errorPipe = Pipe()
                process.standardError = errorPipe

                do {
                    try process.run()
                    process.waitUntilExit()

                    if process.terminationStatus == 0 {
                        continuation.resume(returning: successResult)
                    } else {
                        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                        let errorMsg = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                        continuation.resume(throwing: errorMapper(errorMsg))
                    }
                } catch {
                    continuation.resume(throwing: errorMapper(error.localizedDescription))
                }
            }
        }
    }
}
