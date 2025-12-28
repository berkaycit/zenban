import Foundation

enum GitError: Error, LocalizedError {
    case initFailed
    case directoryCreationFailed
    case directoryAlreadyExists
    case worktreeCreationFailed(String)
    case worktreeDeletionFailed(String)
    case branchDeletionFailed(String)
    case statusFailed(String)
    case diffFailed(String)
    case commitFailed(String)
    case pushFailed(String)
    case mergeFailed(String)
    case mergeSucceededPushFailed(String)
    case prCreationFailed(String)
    case ghNotInstalled
    case ghNotAuthenticated
    case branchListFailed(String)
    case claudeNotInstalled
    case claudeGenerationFailed(String)

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
        case .statusFailed(let msg):
            return "Failed to get git status: \(msg)"
        case .diffFailed(let msg):
            return "Failed to get diff: \(msg)"
        case .commitFailed(let msg):
            return "Failed to commit: \(msg)"
        case .pushFailed(let msg):
            return "Failed to push: \(msg)"
        case .mergeFailed(let msg):
            return "Failed to merge: \(msg)"
        case .mergeSucceededPushFailed(let msg):
            return "Merge completed locally but push failed: \(msg)"
        case .prCreationFailed(let msg):
            return "Failed to create PR: \(msg)"
        case .ghNotInstalled:
            return "GitHub CLI (gh) is not installed"
        case .ghNotAuthenticated:
            return "GitHub CLI is not authenticated. Run 'gh auth login' first"
        case .branchListFailed(let msg):
            return "Failed to list branches: \(msg)"
        case .claudeNotInstalled:
            return "Claude Code CLI is not installed. Install with: npm install -g @anthropic-ai/claude-code"
        case .claudeGenerationFailed(let msg):
            return "AI generation failed: \(msg)"
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

        try await runGit(["init"], in: repoPath, errorMapper: { _ in .initFailed })
        return repoPath
    }

    static func createWorktree(cardID: UUID, repositoryPath: String) async throws -> String {
        let paths = WorktreePaths(cardID: cardID, repositoryPath: repositoryPath)
        let parentDir = (paths.directory as NSString).deletingLastPathComponent

        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: parentDir) {
            try fileManager.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
        }

        await pruneAndCleanup(paths: paths, repositoryPath: repositoryPath)

        try await runGit(["worktree", "add", "-b", paths.branch, paths.directory], in: repositoryPath, errorMapper: { .worktreeCreationFailed($0) })
        return paths.directory
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
        try? await runGit(["worktree", "prune"], in: repositoryPath, errorMapper: { _ in .worktreeDeletionFailed("") })
        try? await runGit(["worktree", "remove", "--force", paths.directory], in: repositoryPath, errorMapper: { _ in .worktreeDeletionFailed("") })
        try? await runGit(["branch", "-D", paths.branch], in: repositoryPath, errorMapper: { _ in .branchDeletionFailed("") })
        try? FileManager.default.removeItem(atPath: paths.directory)
    }

    // MARK: - Process Execution

    private static func runProcess(
        executable: String,
        args: [String],
        directory: String,
        errorMapper: @escaping (String) -> GitError
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = args
                process.currentDirectoryURL = URL(fileURLWithPath: directory)

                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = errorPipe

                do {
                    try process.run()
                    process.waitUntilExit()

                    if process.terminationStatus == 0 {
                        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                        continuation.resume(returning: String(data: outputData, encoding: .utf8) ?? "")
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

    @discardableResult
    private static func runGit(
        _ args: [String],
        in directory: String,
        errorMapper: @escaping (String) -> GitError
    ) async throws -> String {
        try await runProcess(executable: "/usr/bin/git", args: args, directory: directory, errorMapper: errorMapper)
    }

    private static var ghPath: String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first { FileManager.default.fileExists(atPath: $0) }
    }

    private static func runGh(_ args: [String], in directory: String) async throws -> String {
        guard let path = ghPath else { throw GitError.ghNotInstalled }
        return try await runProcess(executable: path, args: args, directory: directory, errorMapper: { .prCreationFailed($0) })
    }

    // MARK: - Status & Diff Operations

    static func getStatus(worktreePath: String) async throws -> GitStatus {
        let branch = try await getCurrentBranch(worktreePath: worktreePath)
        let statusOutput = try await runGit(["status", "--porcelain"], in: worktreePath, errorMapper: { .statusFailed($0) })
        let diffStats = try await getDiffStats(worktreePath: worktreePath)

        var filesChanged: [FileChange] = []

        // Parse status output
        for line in statusOutput.split(separator: "\n", omittingEmptySubsequences: true) {
            let lineStr = String(line)
            guard lineStr.count >= 3 else { continue }

            let statusChar = lineStr.prefix(2).trimmingCharacters(in: .whitespaces)
            let filePath = String(lineStr.dropFirst(3))

            let status: FileChange.FileStatus
            switch statusChar {
            case "A", "??":
                status = statusChar == "??" ? .untracked : .added
            case "M", "MM", " M":
                status = .modified
            case "D", " D":
                status = .deleted
            case "R":
                status = .renamed
            default:
                status = .modified
            }

            // Find stats for this file
            let stats = diffStats.first { $0.path == filePath }

            filesChanged.append(FileChange(
                path: filePath,
                status: status,
                additions: stats?.additions ?? 0,
                deletions: stats?.deletions ?? 0
            ))
        }

        let totalAdditions = filesChanged.reduce(0) { $0 + $1.additions }
        let totalDeletions = filesChanged.reduce(0) { $0 + $1.deletions }

        return GitStatus(
            branch: branch,
            filesChanged: filesChanged,
            totalAdditions: totalAdditions,
            totalDeletions: totalDeletions
        )
    }

    static func getDiff(worktreePath: String, file: String? = nil) async throws -> String {
        var args = ["diff", "HEAD"]
        if let file = file {
            args += ["--", file]
        }
        return try await runGit(args, in: worktreePath, errorMapper: { .diffFailed($0) })
    }

    static func getDiffStats(worktreePath: String) async throws -> [(path: String, additions: Int, deletions: Int)] {
        let output = try await runGit(["diff", "HEAD", "--numstat"], in: worktreePath, errorMapper: { .diffFailed($0) })
        return parseNumstatOutput(output)
    }

    private static func parseNumstatOutput(_ output: String) -> [(path: String, additions: Int, deletions: Int)] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let parts = line.split(separator: "\t")
            guard parts.count >= 3 else { return nil }
            return (path: String(parts[2]), additions: Int(parts[0]) ?? 0, deletions: Int(parts[1]) ?? 0)
        }
    }

    // MARK: - Branch Operations

    static func getCurrentBranch(worktreePath: String) async throws -> String {
        let output = try await runGit(["rev-parse", "--abbrev-ref", "HEAD"], in: worktreePath, errorMapper: { .branchListFailed($0) })
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func listBranches(repositoryPath: String, includeRemote: Bool = true) async throws -> [BranchInfo] {
        var args = ["branch", "--format=%(refname:short)"]
        if includeRemote { args.append("-a") }

        let output = try await runGit(args, in: repositoryPath, errorMapper: { .branchListFailed($0) })
        let currentBranch = try? await getCurrentBranch(worktreePath: repositoryPath)

        var branches: [BranchInfo] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            var name = String(line).trimmingCharacters(in: .whitespaces)
            let isRemote = name.hasPrefix("remotes/") || name.hasPrefix("origin/")

            // Clean up remote branch names
            if name.hasPrefix("remotes/origin/") {
                name = String(name.dropFirst("remotes/origin/".count))
            } else if name.hasPrefix("origin/") {
                name = String(name.dropFirst("origin/".count))
            }

            // Skip HEAD pointer and origin-only entries
            if name.contains("HEAD") { continue }
            if name == "origin" { continue }

            // Skip card branches (worktree branches)
            if name.hasPrefix("card/") { continue }

            // Skip duplicates (local and remote versions of same branch)
            if branches.contains(where: { $0.name == name }) { continue }

            branches.append(BranchInfo(
                name: name,
                isCurrent: name == currentBranch,
                isRemote: isRemote
            ))
        }

        return branches
    }

    // MARK: - AI Commit Message Generation

    static func generateCommitMessage(worktreePath: String) async throws -> CommitMessageResult {
        guard ClaudeService.isAvailable else {
            throw GitError.claudeNotInstalled
        }

        let diff = try await getDiff(worktreePath: worktreePath)

        guard !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GitError.claudeGenerationFailed("No changes to analyze")
        }

        do {
            let response = try await ClaudeService.generate(
                prompt: PromptTemplate.commitMessage.template,
                context: diff,
                workingDirectory: worktreePath,
                config: .default
            )

            return DefaultCommitMessageParser().parse(response)
        } catch let error as AIProviderError {
            throw GitError.claudeGenerationFailed(error.localizedDescription ?? "Unknown error")
        }
    }

    // MARK: - Commit & Push Operations

    static func commitAll(worktreePath: String, message: String) async throws {
        try await runGit(["add", "-A"], in: worktreePath, errorMapper: { .commitFailed($0) })
        try await runGit(["commit", "-m", message], in: worktreePath, errorMapper: { .commitFailed($0) })
    }

    static func push(worktreePath: String, setUpstream: Bool = false) async throws {
        var args = ["push"]
        if setUpstream {
            let branch = try await getCurrentBranch(worktreePath: worktreePath)
            args += ["-u", "origin", branch]
        }
        try await runGit(args, in: worktreePath, errorMapper: { .pushFailed($0) })
    }

    static func commitAndPush(worktreePath: String, message: String) async throws {
        try await commitAll(worktreePath: worktreePath, message: message)
        do {
            try await push(worktreePath: worktreePath)
        } catch {
            try await push(worktreePath: worktreePath, setUpstream: true)
        }
    }

    // MARK: - Merge Operations

    static func merge(worktreePath: String, targetBranch: String, repositoryPath: String) async throws {
        let worktreeBranch = try await getCurrentBranch(worktreePath: worktreePath)
        let originalRepoBranch = try await getCurrentBranch(worktreePath: repositoryPath)

        // Checkout and merge with rollback on failure
        do {
            try await runGit(["checkout", targetBranch], in: repositoryPath, errorMapper: { .mergeFailed($0) })
            try await runGit(["merge", worktreeBranch], in: repositoryPath, errorMapper: { .mergeFailed($0) })
        } catch {
            // Abort merge if in progress and restore original branch
            try? await runGit(["merge", "--abort"], in: repositoryPath, errorMapper: { _ in .mergeFailed("") })
            try? await runGit(["checkout", originalRepoBranch], in: repositoryPath, errorMapper: { _ in .mergeFailed("") })
            throw error
        }

        // Push separately - merge succeeded, push might fail
        do {
            try await runGit(["push"], in: repositoryPath, errorMapper: { .pushFailed($0) })
        } catch {
            throw GitError.mergeSucceededPushFailed(error.localizedDescription)
        }
    }

    // MARK: - PR Operations (gh CLI)

    static var isGhInstalled: Bool { ghPath != nil }

    static func isGhAuthenticated() async -> Bool {
        guard ghPath != nil else { return false }
        return (try? await runGh(["auth", "status"], in: FileManager.default.currentDirectoryPath)) != nil
    }

    static func createPR(worktreePath: String, config: PRConfig) async throws -> PRResult {
        guard isGhInstalled else { throw GitError.ghNotInstalled }
        guard await isGhAuthenticated() else { throw GitError.ghNotAuthenticated }

        var args = ["pr", "create", "--title", config.title, "--base", config.baseBranch, "--body", config.description]
        if config.isDraft { args.append("--draft") }

        let output = try await runGh(args, in: worktreePath)
        let url = output.trimmingCharacters(in: .whitespacesAndNewlines)

        var prNumber = 0
        if let range = url.range(of: "/pull/") {
            prNumber = Int(url[range.upperBound...]) ?? 0
        }
        return PRResult(url: url, number: prNumber)
    }

    static func generatePRDescription(worktreePath: String) async throws -> String {
        let output = try await runGit(["log", "main..HEAD", "--pretty=format:- %s"], in: worktreePath, errorMapper: { .diffFailed($0) })
        return output.isEmpty ? "" : "## Changes\n\n\(output)"
    }

    // MARK: - Branch Comparison

    /// Get diff between current branch and target branch (for merge/PR)
    static func getBranchDiff(worktreePath: String, targetBranch: String) async throws -> String {
        try await runGit(["diff", "\(targetBranch)...HEAD"], in: worktreePath, errorMapper: { .diffFailed($0) })
    }

    /// Get diff stats between current branch and target branch
    static func getBranchDiffStats(worktreePath: String, targetBranch: String) async throws -> [(path: String, additions: Int, deletions: Int)] {
        let output = try await runGit(["diff", "\(targetBranch)...HEAD", "--numstat"], in: worktreePath, errorMapper: { .diffFailed($0) })
        return parseNumstatOutput(output)
    }

    /// Get list of changed files between current branch and target branch
    static func getBranchChangedFiles(worktreePath: String, targetBranch: String) async throws -> [FileChange] {
        let diffStats = try await getBranchDiffStats(worktreePath: worktreePath, targetBranch: targetBranch)

        return diffStats.map { stat in
            FileChange(
                path: stat.path,
                status: .modified,
                additions: stat.additions,
                deletions: stat.deletions
            )
        }
    }

    /// Check if there are uncommitted changes
    static func hasUncommittedChanges(worktreePath: String) async -> Bool {
        let output = (try? await runGit(["status", "--porcelain"], in: worktreePath, errorMapper: { .statusFailed($0) })) ?? ""
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Get file diff between branches
    static func getBranchFileDiff(worktreePath: String, targetBranch: String, file: String) async throws -> String {
        try await runGit(["diff", "\(targetBranch)...HEAD", "--", file], in: worktreePath, errorMapper: { .diffFailed($0) })
    }
}
