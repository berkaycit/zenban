import SwiftUI
import Combine

@MainActor
final class GitDiffViewModel: ObservableObject {
    @Published var loadedDiffs: [String: [DiffLine]] = [:]
    @Published var loadingFiles: Set<String> = []

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
                let diffOutput = await self.preferredDiffOutput(for: file)
                lines = await Task.detached(priority: .utility) {
                    DiffParser.parseUnifiedDiff(diffOutput ?? "")
                }.value
            }

            guard !Task.isCancelled else { return }

            let contentHash = Self.computeDiffHash(lines)
            await self.cache.cacheDiff(lines, for: file, contentHash: contentHash)

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

    func unloadDiff(for file: String) {
        loadedDiffs.removeValue(forKey: file)
    }

    func cancelAll() {
        for task in activeTasks.values {
            task.cancel()
        }
        activeTasks.removeAll()
        loadingFiles.removeAll()
    }

    func reset() async {
        cancelAll()
        loadedDiffs.removeAll()
        await cache.invalidateAll()
    }

    private static func computeDiffHash(_ lines: [DiffLine]) -> String {
        var hasher = Hasher()
        hasher.combine(lines.count)
        // Hash first and last lines for quick validation
        if let first = lines.first {
            hasher.combine(first.content)
        }
        if let last = lines.last {
            hasher.combine(last.content)
        }
        return String(hasher.finalize())
    }

    private func preferredDiffOutput(for file: String?) async -> String? {
        if hasCommittedChanges {
            let branchDiff = await branchDiffOutput(for: file)
            if !isBlank(branchDiff) { return branchDiff }
            guard hasUncommittedChanges else { return branchDiff }
        }

        guard hasUncommittedChanges else { return "" }
        return await workingDiffOutput(for: file)
    }

    private func branchDiffOutput(for file: String?) async -> String? {
        if let file {
            return try? await GitService.getBranchFileDiff(
                worktreePath: repoPath,
                targetBranch: targetBranch,
                file: file
            )
        }

        return try? await GitService.getBranchDiff(
            worktreePath: repoPath,
            targetBranch: targetBranch
        )
    }

    private func workingDiffOutput(for file: String?) async -> String? {
        var diffOutput = try? await GitService.getDiff(worktreePath: repoPath, file: file)

        if isBlank(diffOutput) {
            diffOutput = try? await GitService.getUnstagedDiff(worktreePath: repoPath, file: file)
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

    private func isBlank(_ diffOutput: String?) -> Bool {
        diffOutput?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }
}
