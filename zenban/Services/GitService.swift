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
        let branchName = "card/\(cardID.uuidString)"
        let repoParent = (repositoryPath as NSString).deletingLastPathComponent
        let worktreesDir = (repoParent as NSString).appendingPathComponent("repo-worktrees")
        let worktreePath = (worktreesDir as NSString).appendingPathComponent(branchName)

        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: worktreesDir) {
            try fileManager.createDirectory(atPath: worktreesDir, withIntermediateDirectories: true)
        }

        return try await runGitCommand(
            args: ["worktree", "add", "-b", branchName, worktreePath],
            directory: repositoryPath,
            errorMapper: { .worktreeCreationFailed($0) },
            successResult: worktreePath
        )
    }

    static func deleteWorktree(cardID: UUID, repositoryPath: String) async throws {
        let branchName = "card/\(cardID.uuidString)"
        let repoParent = (repositoryPath as NSString).deletingLastPathComponent
        let worktreesDir = (repoParent as NSString).appendingPathComponent("repo-worktrees")
        let worktreePath = (worktreesDir as NSString).appendingPathComponent(branchName)

        try await runGitCommand(
            args: ["worktree", "remove", "--force", worktreePath],
            directory: repositoryPath,
            errorMapper: { .worktreeDeletionFailed($0) },
            successResult: ()
        )

        try await runGitCommand(
            args: ["branch", "-D", branchName],
            directory: repositoryPath,
            errorMapper: { .branchDeletionFailed($0) },
            successResult: ()
        )
    }

    static func isGitRepository(path: String) -> Bool {
        let gitPath = (path as NSString).appendingPathComponent(".git")
        return FileManager.default.fileExists(atPath: gitPath)
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
