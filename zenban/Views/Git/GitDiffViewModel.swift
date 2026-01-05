import SwiftUI
import Combine

@MainActor
final class GitDiffViewModel: ObservableObject {
    @Published var loadedDiffs: [String: [DiffLine]] = [:]
    @Published var loadingFiles: Set<String> = []
    @Published var errors: [String: String] = [:]
    @Published var isBatchLoading: Bool = false

    private let cache: GitDiffCache
    private var activeTasks: [String: Task<Void, Never>] = [:]
    private let repoPath: String

    private var targetBranch: String
    private var hasCommittedChanges: Bool = false
    private var hasUncommittedChanges: Bool = false
    private var untrackedFiles: Set<String> = []

    init(repoPath: String, cache: GitDiffCache = GitDiffCache(), targetBranch: String = "main") {
        self.repoPath = repoPath
        self.cache = cache
        self.targetBranch = targetBranch
    }

    func updateContext(
        targetBranch: String,
        hasCommittedChanges: Bool,
        hasUncommittedChanges: Bool,
        untrackedFiles: Set<String>
    ) {
        self.targetBranch = targetBranch
        self.hasCommittedChanges = hasCommittedChanges
        self.hasUncommittedChanges = hasUncommittedChanges
        self.untrackedFiles = untrackedFiles
    }

    func loadDiff(for file: String) {
        guard !loadingFiles.contains(file) else { return }
        guard loadedDiffs[file] == nil else { return }

        activeTasks[file]?.cancel()
        loadingFiles.insert(file)
        errors.removeValue(forKey: file)

        let isUntracked = untrackedFiles.contains(file)

        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor in
                    self.activeTasks.removeValue(forKey: file)
                }
            }

            if let cached = await self.cache.getDiff(for: file) {
                await MainActor.run { [weak self] in
                    self?.loadedDiffs[file] = cached
                    self?.loadingFiles.remove(file)
                }
                return
            }

            var lines: [DiffLine]

            if isUntracked {
                lines = await self.loadUntrackedFileAsDiff(file)
            } else {
                let diffOutput = await self.loadDiffOutput(for: file)
                lines = await Task.detached(priority: .utility) {
                    DiffParser.parseUnifiedDiff(diffOutput ?? "")
                }.value
            }

            guard !Task.isCancelled else { return }

            await self.cache.cacheDiff(lines, for: file)

            await MainActor.run { [weak self] in
                guard !Task.isCancelled else { return }
                self?.loadedDiffs[file] = lines
                self?.loadingFiles.remove(file)
            }
        }

        activeTasks[file] = task
    }

    func cancelLoad(for file: String) {
        activeTasks[file]?.cancel()
        activeTasks.removeValue(forKey: file)
        loadingFiles.remove(file)
    }

    func invalidateCache() async {
        await cache.invalidateAll()
        loadedDiffs.removeAll()
    }

    func invalidateFile(_ file: String) async {
        await cache.invalidate(file: file)
        loadedDiffs.removeValue(forKey: file)
    }

    /// Batch load diffs for multiple files in fewer git calls
    func loadAllDiffs(for files: [String]) async {
        let trackedFiles = files.filter { !untrackedFiles.contains($0) }
        let filesToLoad = trackedFiles.filter { loadedDiffs[$0] == nil && !loadingFiles.contains($0) }
        let untrackedToLoad = files.filter { untrackedFiles.contains($0) && loadedDiffs[$0] == nil }

        guard !filesToLoad.isEmpty || !untrackedToLoad.isEmpty else {
            isBatchLoading = false
            return
        }

        isBatchLoading = true
        defer { isBatchLoading = false }

        // Load tracked files with batch diff
        if !filesToLoad.isEmpty {
            let diffOutput = await loadBatchDiffOutput()

            let parsedByFile = await Task.detached(priority: .utility) {
                DiffParser.splitDiffByFile(diffOutput ?? "")
            }.value

            for file in filesToLoad {
                let lines = parsedByFile[file] ?? []
                loadedDiffs[file] = lines
                if !lines.isEmpty {
                    await cache.cacheDiff(lines, for: file)
                }
            }
        }

        // Load untracked files
        for file in untrackedToLoad {
            let lines = await loadUntrackedFileAsDiff(file)
            loadedDiffs[file] = lines
            if !lines.isEmpty {
                await cache.cacheDiff(lines, for: file)
            }
        }
    }

    private func loadBatchDiffOutput() async -> String? {
        if hasCommittedChanges {
            let branchDiff = try? await GitService.getBranchDiff(
                worktreePath: repoPath,
                targetBranch: targetBranch
            )
            if let diff = branchDiff, !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return diff
            }
            guard hasUncommittedChanges else { return branchDiff }
        }

        guard hasUncommittedChanges else { return "" }

        var diffOutput = try? await GitService.getDiff(worktreePath: repoPath, file: nil)
        if diffOutput?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            diffOutput = try? await GitService.getUnstagedDiff(worktreePath: repoPath, file: nil)
        }
        return diffOutput
    }

    private func loadUntrackedFileAsDiff(_ file: String) async -> [DiffLine] {
        let fullPath = (repoPath as NSString).appendingPathComponent(file)

        // Read file on background thread to avoid blocking UI
        return await Task.detached {
            guard let content = try? String(contentsOfFile: fullPath, encoding: .utf8) else {
                return [DiffLine]()
            }

            let fileLines = content.components(separatedBy: .newlines)
            var diffLines: [DiffLine] = []

            // Add header
            diffLines.append(DiffLine(
                lineNumber: 0,
                oldLineNumber: nil,
                newLineNumber: nil,
                content: "new file: \(file)",
                type: .header
            ))

            // Add all lines as additions
            for (index, line) in fileLines.enumerated() {
                diffLines.append(DiffLine(
                    lineNumber: index + 1,
                    oldLineNumber: nil,
                    newLineNumber: String(index + 1),
                    content: line,
                    type: .added
                ))
            }

            return diffLines
        }.value
    }

    private func loadDiffOutput(for file: String) async -> String? {
        if hasCommittedChanges {
            let branchDiff = try? await GitService.getBranchFileDiff(
                worktreePath: repoPath,
                targetBranch: targetBranch,
                file: file
            )

            if let diff = branchDiff, !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return diff
            }

            guard hasUncommittedChanges else { return branchDiff }
            return await loadWorkingDiffOutput(for: file)
        }

        guard hasUncommittedChanges else { return "" }
        return await loadWorkingDiffOutput(for: file)
    }

    private func loadWorkingDiffOutput(for file: String) async -> String? {
        var diffOutput = try? await GitService.getDiff(worktreePath: repoPath, file: file)

        if diffOutput?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            diffOutput = try? await GitService.getUnstagedDiff(worktreePath: repoPath, file: file)
        }

        return diffOutput
    }

    deinit {
        for task in activeTasks.values {
            task.cancel()
        }
    }
}
