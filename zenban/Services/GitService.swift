import Foundation
import Clibgit2

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
            // Parse conflict files from git output
            let conflictFiles = msg.components(separatedBy: "\n")
                .filter { $0.contains("CONFLICT") }
                .compactMap { line -> String? in
                    // Extract filename from "CONFLICT (content): Merge conflict in <file>"
                    if let range = line.range(of: "Merge conflict in ") {
                        return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                    }
                    // Extract filename from "CONFLICT (modify/delete): <file> deleted in ..."
                    if let colonRange = line.range(of: "):") {
                        let afterColon = line[colonRange.upperBound...].trimmingCharacters(in: .whitespaces)
                        return afterColon.components(separatedBy: " ").first
                    }
                    return nil
                }

            if conflictFiles.isEmpty {
                return "Failed to merge: \(msg)"
            } else {
                let fileList = conflictFiles.map { "  - \($0)" }.joined(separator: "\n")
                return "Merge conflict in:\n\(fileList)"
            }
        case .mergeSucceededPushFailed(let msg):
            return "Merge completed locally but push failed: \(msg)"
        case .prCreationFailed(let msg):
            return "Failed to create PR: \(msg)"
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
        let worktreeName: String

        init(cardID: UUID, repositoryPath: String) {
            branch = "card/\(cardID.uuidString)"
            let repoParent = (repositoryPath as NSString).deletingLastPathComponent
            let worktreesDir = (repoParent as NSString).appendingPathComponent("repo-worktrees")
            directory = (worktreesDir as NSString).appendingPathComponent(branch)
            worktreeName = cardID.uuidString
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

        do {
            try await runLibgit2 {
                let repo = try Libgit2Repository(initAt: repoPath)
                try repo.setHeadSymbolic(refName: "refs/heads/main")
            }
        } catch {
            throw GitError.initFailed
        }
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

        do {
            try await runLibgit2 {
                let repo = try Libgit2Repository(path: repositoryPath)
                let baseBranch = try repo.currentBranchName()
                try repo.addWorktree(
                    name: paths.worktreeName,
                    path: paths.directory,
                    branch: paths.branch,
                    createBranch: true,
                    baseBranch: baseBranch
                )
            }
        } catch {
            throw GitError.worktreeCreationFailed(libgit2ErrorMessage(error))
        }
        return paths.directory
    }

    static func deleteWorktree(cardID: UUID, repositoryPath: String) async {
        let paths = WorktreePaths(cardID: cardID, repositoryPath: repositoryPath)
        await pruneAndCleanup(paths: paths, repositoryPath: repositoryPath)
    }

    static func isGitRepository(path: String) -> Bool {
        Libgit2Repository.isRepository(path)
    }

    /// Cleans up stale worktree entries, removes worktree registration, deletes branch, and removes directory
    private static func pruneAndCleanup(paths: WorktreePaths, repositoryPath: String) async {
        _ = try? await runLibgit2 {
            let repo = try Libgit2Repository(path: repositoryPath)
            try? repo.removeWorktree(name: paths.worktreeName, force: true)
            try? repo.deleteBranch(name: paths.branch)
        }
        try? FileManager.default.removeItem(atPath: paths.directory)
    }

    private static func libgit2ErrorMessage(_ error: Error) -> String {
        if let libgit2Error = error as? Libgit2Error {
            return libgit2Error.errorDescription ?? "Unknown libgit2 error"
        }
        return error.localizedDescription
    }

    private static func runLibgit2<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await Task.detached(priority: .utility) {
            try work()
        }.value
    }

    // MARK: - Status & Diff Operations

    static func getStatus(worktreePath: String) async throws -> GitStatus {
        do {
            return try await runLibgit2 {
                let repo = try Libgit2Repository(path: worktreePath)
                let status = try repo.status(includeUntracked: true, includeIgnored: false)
                if status.entries.isEmpty {
                    let branch = (try repo.currentBranchName()) ?? "HEAD"
                    return GitStatus(
                        branch: branch,
                        filesChanged: [],
                        totalAdditions: 0,
                        totalDeletions: 0
                    )
                }

                let deltas = try repo.diffHeadToWorkdir(includeUntracked: true)

                var statsByPath: [String: (additions: Int, deletions: Int)] = [:]
                for delta in deltas {
                    let path = delta.newPath ?? delta.oldPath ?? ""
                    guard !path.isEmpty else { continue }
                    let current = statsByPath[path] ?? (0, 0)
                    statsByPath[path] = (
                        current.additions + delta.additions,
                        current.deletions + delta.deletions
                    )
                }

                let filesChanged = status.entries.map { entry in
                    let stats = statsByPath[entry.path] ?? (0, 0)
                    return FileChange(
                        path: entry.path,
                        status: mapLibgit2Status(entry.status),
                        additions: stats.additions,
                        deletions: stats.deletions
                    )
                }

                let totalAdditions = filesChanged.reduce(0) { $0 + $1.additions }
                let totalDeletions = filesChanged.reduce(0) { $0 + $1.deletions }
                let branch = (try repo.currentBranchName()) ?? "HEAD"

                return GitStatus(
                    branch: branch,
                    filesChanged: filesChanged,
                    totalAdditions: totalAdditions,
                    totalDeletions: totalDeletions
                )
            }
        } catch {
            throw GitError.statusFailed(libgit2ErrorMessage(error))
        }
    }

    private static nonisolated func mapLibgit2Status(_ status: Libgit2FileStatus) -> FileChange.FileStatus {
        if status.isUntracked {
            return .untracked
        }
        if status.contains(.indexNew) || status.contains(.wtNew) {
            return .added
        }
        if status.contains(.indexDeleted) || status.contains(.wtDeleted) {
            return .deleted
        }
        if status.contains(.indexRenamed) || status.contains(.wtRenamed) {
            return .renamed
        }
        return .modified
    }

    static func getDiff(worktreePath: String, file: String? = nil) async throws -> String {
        do {
            return try await runLibgit2 {
                let repo = try Libgit2Repository(path: worktreePath)
                return try repo.diffUnified(pathspec: file)
            }
        } catch {
            throw GitError.diffFailed(libgit2ErrorMessage(error))
        }
    }

    static func getUnstagedDiff(worktreePath: String, file: String? = nil) async throws -> String {
        do {
            return try await runLibgit2 {
                let repo = try Libgit2Repository(path: worktreePath)
                return try repo.diffUnstagedUnified(pathspec: file)
            }
        } catch {
            throw GitError.diffFailed(libgit2ErrorMessage(error))
        }
    }

    // MARK: - Branch Operations

    static func getCurrentBranch(worktreePath: String) async throws -> String {
        do {
            return try await runLibgit2 {
                let repo = try Libgit2Repository(path: worktreePath)
                return (try repo.currentBranchName()) ?? "HEAD"
            }
        } catch {
            throw GitError.branchListFailed(libgit2ErrorMessage(error))
        }
    }

    static func listBranches(repositoryPath: String, includeRemote: Bool = true) async throws -> [BranchInfo] {
        do {
            return try await runLibgit2 {
                let repo = try Libgit2Repository(path: repositoryPath)
                let branchType: Libgit2BranchType = includeRemote ? .all : .local
                let branchInfos = try repo.listBranches(type: branchType, includeUpstreamInfo: false)
                let currentBranch = (try repo.currentBranchName()) ?? "HEAD"

                var branches: [BranchInfo] = []
                for info in branchInfos {
                    var name = info.name
                    let isRemote = info.isRemote

                    if name.contains("HEAD") { continue }
                    if name.hasPrefix("card/") { continue }

                    if isRemote {
                        if name.hasPrefix("origin/") {
                            name = String(name.dropFirst("origin/".count))
                        }
                        if name == "origin" { continue }
                    }

                    if branches.contains(where: { $0.name == name }) { continue }

                    branches.append(BranchInfo(
                        name: name,
                        isCurrent: name == currentBranch,
                        isRemote: isRemote
                    ))
                }

                return branches
            }
        } catch {
            throw GitError.branchListFailed(libgit2ErrorMessage(error))
        }
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
        do {
            try await runLibgit2 {
                let repo = try Libgit2Repository(path: worktreePath)
                try repo.stageAll()
                _ = try repo.commit(message: message)
            }
        } catch {
            throw GitError.commitFailed(libgit2ErrorMessage(error))
        }
    }

    static func push(worktreePath: String, setUpstream: Bool = false) async throws {
        do {
            try await runLibgit2 {
                let repo = try Libgit2Repository(path: worktreePath)
                try repo.push(remoteName: "origin", shouldSetUpstream: setUpstream)
            }
        } catch {
            throw GitError.pushFailed(libgit2ErrorMessage(error))
        }
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
        do {
            try await runLibgit2 {
                let worktreeRepo = try Libgit2Repository(path: worktreePath)
                guard let worktreeBranch = try worktreeRepo.currentBranchName() else {
                    throw Libgit2Error.referenceNotFound("HEAD")
                }

                let repo = try Libgit2Repository(path: repositoryPath)
                let originalRepoBranch = (try repo.currentBranchName()) ?? worktreeBranch

                var originalHeadOid = git_oid()
                var hasOriginalHead = false
                if let ptr = repo.pointer {
                    var headRef: OpaquePointer?
                    if git_repository_head(&headRef, ptr) == 0, let h = headRef {
                        defer { git_reference_free(h) }
                        if let target = git_reference_target(h) {
                            originalHeadOid = target.pointee
                            hasOriginalHead = true
                        }
                    }
                }

                do {
                    try repo.checkoutBranch(name: targetBranch)
                    try performMerge(repo: repo, sourceBranch: worktreeBranch)
                } catch {
                    if let ptr = repo.pointer {
                        git_repository_state_cleanup(ptr)
                        if hasOriginalHead {
                            var commit: OpaquePointer?
                            if git_commit_lookup(&commit, ptr, &originalHeadOid) == 0, let c = commit {
                                defer { git_commit_free(c) }
                                var opts = git_checkout_options()
                                git_checkout_options_init(&opts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
                                opts.checkout_strategy = UInt32(GIT_CHECKOUT_FORCE.rawValue)
                                _ = git_reset(ptr, c, GIT_RESET_HARD, &opts)
                            }
                        }
                    }
                    try? repo.checkoutBranch(name: originalRepoBranch)
                    throw error
                }

                try repo.push(remoteName: "origin")
            }
        } catch let error as Libgit2Error {
            if case .mergeConflict = error {
                throw GitError.mergeFailed(error.errorDescription ?? "Merge conflict")
            }
            throw GitError.mergeFailed(error.errorDescription ?? error.localizedDescription)
        } catch {
            throw GitError.mergeFailed(error.localizedDescription)
        }
    }

    private static nonisolated func performMerge(repo: Libgit2Repository, sourceBranch: String) throws {
        guard let ptr = repo.pointer else {
            throw Libgit2Error.notARepository(repo.path)
        }

        let sourceRefName = "refs/heads/\(sourceBranch)"
        var sourceRef: OpaquePointer?
        let lookupError = git_reference_lookup(&sourceRef, ptr, sourceRefName)
        guard lookupError == 0, let sRef = sourceRef else {
            throw Libgit2Error.branchNotFound(sourceBranch)
        }
        defer { git_reference_free(sRef) }

        var annotatedCommit: OpaquePointer?
        let annotateError = git_annotated_commit_from_ref(&annotatedCommit, ptr, sRef)
        guard annotateError == 0, let ac = annotatedCommit else {
            throw Libgit2Error.from(annotateError, context: "annotated commit")
        }
        defer { git_annotated_commit_free(ac) }

        var analysis: git_merge_analysis_t = GIT_MERGE_ANALYSIS_NONE
        var preference: git_merge_preference_t = GIT_MERGE_PREFERENCE_NONE

        var commits: [OpaquePointer?] = [ac]
        let analysisError = commits.withUnsafeMutableBufferPointer { buffer in
            git_merge_analysis(&analysis, &preference, ptr, buffer.baseAddress, 1)
        }
        guard analysisError == 0 else {
            throw Libgit2Error.from(analysisError, context: "merge analysis")
        }

        if analysis.rawValue & GIT_MERGE_ANALYSIS_UP_TO_DATE.rawValue != 0 {
            return
        }

        if analysis.rawValue & GIT_MERGE_ANALYSIS_FASTFORWARD.rawValue != 0 {
            var targetOid = git_oid()
            let oidError = git_reference_name_to_id(&targetOid, ptr, sourceRefName)
            guard oidError == 0 else {
                throw Libgit2Error.from(oidError, context: "get target oid")
            }

            var targetCommit: OpaquePointer?
            let commitError = git_commit_lookup(&targetCommit, ptr, &targetOid)
            guard commitError == 0, let tc = targetCommit else {
                throw Libgit2Error.from(commitError, context: "commit lookup")
            }
            defer { git_commit_free(tc) }

            var tree: OpaquePointer?
            let treeError = git_commit_tree(&tree, tc)
            guard treeError == 0, let t = tree else {
                throw Libgit2Error.from(treeError, context: "get commit tree")
            }
            defer { git_tree_free(t) }

            var checkoutOpts = git_checkout_options()
            git_checkout_options_init(&checkoutOpts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
            checkoutOpts.checkout_strategy = UInt32(GIT_CHECKOUT_SAFE.rawValue)

            let checkoutError = git_checkout_tree(ptr, t, &checkoutOpts)
            guard checkoutError == 0 else {
                throw Libgit2Error.from(checkoutError, context: "checkout tree")
            }

            let headRef = try repo.head()
            defer { git_reference_free(headRef) }

            var newRef: OpaquePointer?
            let setError = git_reference_set_target(&newRef, headRef, &targetOid, "fast-forward")
            defer { if let r = newRef { git_reference_free(r) } }
            guard setError == 0 else {
                throw Libgit2Error.from(setError, context: "update HEAD")
            }

            return
        }

        if analysis.rawValue & GIT_MERGE_ANALYSIS_NORMAL.rawValue != 0 {
            var mergeOpts = git_merge_options()
            git_merge_options_init(&mergeOpts, UInt32(GIT_MERGE_OPTIONS_VERSION))

            var checkoutOpts = git_checkout_options()
            git_checkout_options_init(&checkoutOpts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
            checkoutOpts.checkout_strategy = UInt32(GIT_CHECKOUT_SAFE.rawValue)

            var commits: [OpaquePointer?] = [ac]
            let mergeError = commits.withUnsafeMutableBufferPointer { buffer in
                git_merge(ptr, buffer.baseAddress, 1, &mergeOpts, &checkoutOpts)
            }

            if mergeError != 0 {
                if mergeError == Int32(GIT_ECONFLICT.rawValue) || mergeError == Int32(GIT_EMERGECONFLICT.rawValue) {
                    throw Libgit2Error.mergeConflict("Merge conflicts detected. Please resolve manually.")
                }
                throw Libgit2Error.from(mergeError, context: "merge")
            }

            let index = try repo.getIndex()
            defer { git_index_free(index) }

            if git_index_has_conflicts(index) != 0 {
                throw Libgit2Error.mergeConflict("Merge conflicts detected. Please resolve manually.")
            }

            var treeOid = git_oid()
            let writeError = git_index_write_tree(&treeOid, index)
            guard writeError == 0 else {
                throw Libgit2Error.from(writeError, context: "write tree")
            }

            var tree: OpaquePointer?
            let treeLookupError = git_tree_lookup(&tree, ptr, &treeOid)
            guard treeLookupError == 0, let t = tree else {
                throw Libgit2Error.from(treeLookupError, context: "tree lookup")
            }
            defer { git_tree_free(t) }

            let sig = try repo.defaultSignature()
            defer { git_signature_free(sig) }

            let headRef = try repo.head()
            defer { git_reference_free(headRef) }

            var headCommit: OpaquePointer?
            let peelError = git_reference_peel(&headCommit, headRef, GIT_OBJECT_COMMIT)
            guard peelError == 0, let hc = headCommit else {
                throw Libgit2Error.from(peelError, context: "peel HEAD")
            }
            defer { git_commit_free(hc) }

            guard let sourceOidPtr = git_annotated_commit_id(ac) else {
                throw Libgit2Error.referenceNotFound(sourceBranch)
            }
            var sourceOid = sourceOidPtr.pointee
            var sourceCommit: OpaquePointer?
            let sourceLookupError = git_commit_lookup(&sourceCommit, ptr, &sourceOid)
            guard sourceLookupError == 0, let sc = sourceCommit else {
                throw Libgit2Error.from(sourceLookupError, context: "source commit lookup")
            }
            defer { git_commit_free(sc) }

            var parents: [OpaquePointer?] = [hc, sc]
            var commitOid = git_oid()
            let commitError = parents.withUnsafeMutableBufferPointer { buffer in
                git_commit_create(
                    &commitOid,
                    ptr,
                    "HEAD",
                    sig,
                    sig,
                    nil,
                    "Merge branch '\(sourceBranch)'",
                    t,
                    2,
                    buffer.baseAddress
                )
            }
            guard commitError == 0 else {
                throw Libgit2Error.from(commitError, context: "create merge commit")
            }

            git_repository_state_cleanup(ptr)
        }
    }

    // MARK: - PR Operations

    private static var githubToken: String? {
        let env = ProcessInfo.processInfo.environment
        return env["GITHUB_TOKEN"] ?? env["GITHUB_PAT"] ?? env["GITHUB_API_TOKEN"]
    }

    private static func parseGitHubRemote(_ remote: String) -> (owner: String, repo: String)? {
        if let url = URL(string: remote), let host = url.host, host.contains("github.com") {
            let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let parts = path.split(separator: "/")
            guard parts.count >= 2 else { return nil }
            let owner = String(parts[0])
            let repo = String(parts[1]).replacingOccurrences(of: ".git", with: "")
            return (owner, repo)
        }

        if !remote.contains("://"), let colonIndex = remote.firstIndex(of: ":") {
            let afterColon = String(remote[remote.index(after: colonIndex)...])
            let parts = afterColon.split(separator: "/")
            guard parts.count >= 2 else { return nil }
            let owner = String(parts[0])
            let repo = String(parts[1]).replacingOccurrences(of: ".git", with: "")
            return (owner, repo)
        }

        return nil
    }

    static func createPR(worktreePath: String, config: PRConfig) async throws -> PRResult {
        guard let token = githubToken else {
            throw GitError.prCreationFailed("Missing GitHub token. Set GITHUB_TOKEN or GITHUB_PAT.")
        }

        let remoteURL = try await runLibgit2 {
            let repo = try Libgit2Repository(path: worktreePath)
            let remote = try repo.defaultRemote()
            return remote?.pushUrl ?? remote?.url
        }

        guard let remoteURL, let repoInfo = parseGitHubRemote(remoteURL) else {
            throw GitError.prCreationFailed("Unable to determine GitHub repository from remotes.")
        }

        let headBranch = try await getCurrentBranch(worktreePath: worktreePath)
        let url = URL(string: "https://api.github.com/repos/\(repoInfo.owner)/\(repoInfo.repo)/pulls")
        guard let apiURL = url else {
            throw GitError.prCreationFailed("Invalid GitHub API URL.")
        }

        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("zenban", forHTTPHeaderField: "User-Agent")

        var body: [String: Any] = [
            "title": config.title,
            "head": headBranch,
            "base": config.baseBranch,
            "body": config.description
        ]
        if config.isDraft {
            body["draft"] = true
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GitError.prCreationFailed("Invalid response from GitHub.")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let errorMessage = message?["message"] as? String ?? "GitHub API returned status \(httpResponse.statusCode)"
            throw GitError.prCreationFailed(errorMessage)
        }

        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let prUrl = json?["html_url"] as? String ?? ""
        let number = json?["number"] as? Int ?? 0
        return PRResult(url: prUrl, number: number)
    }

    static func generatePRDescription(worktreePath: String) async throws -> String {
        let summaries = try await runLibgit2 {
            let repo = try Libgit2Repository(path: worktreePath)
            return try repo.commitSummaries(range: "main..HEAD")
        }
        guard !summaries.isEmpty else { return "" }
        let lines = summaries.map { "- \($0)" }.joined(separator: "\n")
        return "## Changes\n\n\(lines)"
    }

    // MARK: - Branch Comparison

    /// Get diff between current branch and target branch (for merge/PR)
    static func getBranchDiff(worktreePath: String, targetBranch: String) async throws -> String {
        do {
            return try await runLibgit2 {
                let repo = try Libgit2Repository(path: worktreePath)
                return try repo.diffBetweenUnified(base: targetBranch, head: "HEAD")
            }
        } catch {
            throw GitError.diffFailed(libgit2ErrorMessage(error))
        }
    }

    /// Get diff stats between current branch and target branch
    static func getBranchDiffStats(worktreePath: String, targetBranch: String) async throws -> [(path: String, additions: Int, deletions: Int)] {
        do {
            return try await runLibgit2 {
                let repo = try Libgit2Repository(path: worktreePath)
                let deltas = try repo.diffBetween(base: targetBranch, head: "HEAD")
                return deltas.compactMap { delta in
                    guard let path = delta.newPath ?? delta.oldPath else { return nil }
                    return (path: path, additions: delta.additions, deletions: delta.deletions)
                }
            }
        } catch {
            throw GitError.diffFailed(libgit2ErrorMessage(error))
        }
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
        do {
            return try await runLibgit2 {
                let repo = try Libgit2Repository(path: worktreePath)
                let status = try repo.status(includeUntracked: true, includeIgnored: false)
                return status.hasChanges
            }
        } catch {
            return false
        }
    }

    /// Get file diff between branches
    static func getBranchFileDiff(worktreePath: String, targetBranch: String, file: String) async throws -> String {
        do {
            return try await runLibgit2 {
                let repo = try Libgit2Repository(path: worktreePath)
                return try repo.diffBetweenUnified(base: targetBranch, head: "HEAD", pathspec: file)
            }
        } catch {
            throw GitError.diffFailed(libgit2ErrorMessage(error))
        }
    }
}
