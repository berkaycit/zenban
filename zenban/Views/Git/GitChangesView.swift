import SwiftUI

struct GitChangesView: View {
    let card: Card
    let boardID: UUID
    let onDismiss: () -> Void
    @Environment(BoardStore.self) private var store
    @StateObject private var diffViewModel: GitDiffViewModel

    private enum GitChangesTab: String, CaseIterable {
        case changes = "Changes"
        case history = "History"
    }

    @State private var selectedTab: GitChangesTab = .changes
    @State private var branchChanges: [FileChange] = []
    @State private var totalAdditions = 0
    @State private var totalDeletions = 0
    @State private var currentBranch = ""
    @State private var hasUncommittedChanges = false
    @State private var hasCommittedChanges = false
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showCommit = false
    @State private var showCreatePR = false
    @State private var selectedTargetBranch = "main"
    @State private var availableBranches: [BranchInfo] = []
    @State private var selectedFilePath: String?
    @State private var isMerging = false
    @State private var selectedHistoryCommit: GitCommit?
    @State private var historyDiffOutput = ""
    @State private var isHistoryDiffLoading = false
    @State private var historyDiffError: String?

    // Task handles for cancellation
    @State private var loadChangesTask: Task<Void, any Error>?
    @State private var loadBranchesTask: Task<Void, any Error>?
    @State private var historyDiffTask: Task<Void, Never>?

    private let historyLogService = GitLogService()

    private var repositoryPath: String? {
        store.board(for: boardID)?.repositoryPath
    }

    private var worktreePath: String {
        card.worktreePath ?? ""
    }

    private var selectedFileChange: FileChange? {
        guard let selectedFilePath else { return nil }
        return branchChanges.first { $0.path == selectedFilePath }
    }

    private var selectedFileFullPath: String? {
        guard let worktreePath = card.worktreePath,
              let selectedFilePath else { return nil }
        return (worktreePath as NSString).appendingPathComponent(selectedFilePath)
    }

    init(card: Card, boardID: UUID, onDismiss: @escaping () -> Void) {
        self.card = card
        self.boardID = boardID
        self.onDismiss = onDismiss
        _diffViewModel = StateObject(wrappedValue: GitDiffViewModel(repoPath: card.worktreePath ?? ""))
    }

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()

            contentSection
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if selectedTab == .changes {
                Divider()
                footerSection
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.cardBackground)
        .compositingGroup()
        .onAppear {
            loadBranches()
            loadChanges()
        }
        .onChange(of: selectedFilePath) { oldValue, newValue in
            if let oldValue, oldValue != newValue {
                if diffViewModel.loadingFiles.contains(oldValue) {
                    diffViewModel.cancelLoad(for: oldValue)
                }
                diffViewModel.unloadDiff(for: oldValue)
            }
            guard let path = newValue else { return }
            if diffViewModel.loadedDiffs[path] == nil &&
                !diffViewModel.loadingFiles.contains(path) {
                loadDiffForFile(path)
            }
        }
        .onChange(of: selectedTab) { _, newValue in
            if newValue == .history {
                loadHistoryDiff(for: selectedHistoryCommit)
            }
        }
        .onChange(of: selectedHistoryCommit) { _, newValue in
            guard selectedTab == .history else { return }
            loadHistoryDiff(for: newValue)
        }
        .onDisappear {
            loadChangesTask?.cancel()
            loadBranchesTask?.cancel()
            historyDiffTask?.cancel()
            let loadingFiles = diffViewModel.loadingFiles
            for file in loadingFiles {
                diffViewModel.cancelLoad(for: file)
            }
        }
        .sheet(isPresented: $showCommit) {
            if let worktreePath = card.worktreePath {
                CommitSheet(
                    worktreePath: worktreePath,
                    isPresented: $showCommit,
                    onCommit: { loadChanges() }
                )
            }
        }
        .sheet(isPresented: $showCreatePR) {
            if let worktreePath = card.worktreePath {
                CreatePRSheet(
                    card: card,
                    worktreePath: worktreePath,
                    baseBranch: selectedTargetBranch,
                    isPresented: $showCreatePR
                )
            }
        }
    }

    // MARK: - Content Section

    @ViewBuilder
    private var contentSection: some View {
        if selectedTab == .changes {
            if isLoading {
                loadingView
            } else if let error = errorMessage {
                errorView(error) { loadChanges() }
            } else if branchChanges.isEmpty {
                emptyChangesView
            } else {
                changesListView
            }
        } else {
            historyContentSection
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 12) {
            Button(action: onDismiss) {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.medium))
            }
            .buttonStyle(.plain)

            Picker("View", selection: $selectedTab) {
                ForEach(GitChangesTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 180)

            if selectedTab == .changes {
                if !branchChanges.isEmpty || !isLoading {
                    Text("\(branchChanges.count) files changed")
                        .font(.headline)

                    HStack(spacing: 4) {
                        Text("+\(totalAdditions)")
                            .foregroundStyle(.green)
                        Text("-\(totalDeletions)")
                            .foregroundStyle(.red)
                    }
                    .font(.subheadline.monospaced())

                    if hasUncommittedChanges {
                        Text("(uncommitted)")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } else {
                    Text("Changes")
                        .font(.headline)
                }
            } else {
                Text("History")
                    .font(.headline)
            }

            Spacer()

            if selectedTab == .changes {
                Button(action: { loadChanges() }) {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(isLoading)
            }
        }
        .padding(16)
    }

    // MARK: - Branch Info

    private var targetBranchOptions: [String] {
        var options = availableBranches.filter { !$0.isCurrent }.map { $0.name }

        // Always include selectedTargetBranch in options
        if !options.contains(selectedTargetBranch) {
            options.insert(selectedTargetBranch, at: 0)
        }

        return options
    }

    private var branchInfoSection: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(.secondary)

            Text(currentBranch)
                .font(.caption.monospaced())

            Image(systemName: "arrow.right")
                .foregroundStyle(.tertiary)

            Picker("Target", selection: $selectedTargetBranch) {
                ForEach(targetBranchOptions, id: \.self) { branch in
                    Text(branch).tag(branch)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(minWidth: 100)
            .onChange(of: selectedTargetBranch) {
                loadChanges()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.05))
    }

    // MARK: - Content Views

    private var loadingView: some View {
        VStack {
            Spacer()
            ProgressView()
                .controlSize(.regular)
            Text("Loading changes...")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            Spacer()
        }
    }

    private func errorView(_ error: String, onRetry: @escaping () -> Void) -> some View {
        VStack {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(error)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
            Button("Retry", action: onRetry)
            Spacer()
        }
    }

    private var emptyChangesView: some View {
        VStack {
            Spacer()
            Image(systemName: "checkmark.circle")
                .font(.largeTitle)
                .foregroundStyle(.green)
            Text("No changes")
                .font(.headline)
                .padding(.top, 8)
            Text("Working tree is clean")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var diffLoadingView: some View {
        VStack {
            Spacer()
            ProgressView()
                .controlSize(.regular)
            Text("Loading diff...")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            Spacer()
        }
    }

    private var emptySelectionView: some View {
        VStack {
            Spacer()
            Image(systemName: "doc.text")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Select a file to view its diff")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            Spacer()
        }
    }

    private func noDiffView(_ message: String) -> some View {
        VStack {
            Spacer()
            Image(systemName: "checkmark.circle")
                .font(.largeTitle)
                .foregroundStyle(.green)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            Spacer()
        }
    }

    private var changesListView: some View {
        HSplitView {
            changesListPanel
                .frame(minWidth: 180, idealWidth: 200, maxWidth: 220)

            diffDetailPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var changesListPanel: some View {
        VStack(spacing: 0) {
            branchInfoSection
            Divider()

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(branchChanges) { file in
                        DiffFileRow(
                            file: file,
                            isSelected: file.path == selectedFilePath,
                            onSelect: {
                                selectedFilePath = file.path
                            }
                        )
                    }
                }
                .padding(12)
            }
        }
    }

    private var diffDetailPanel: some View {
        VStack(spacing: 0) {
            diffHeaderSection
            Divider()
            diffContentSection
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var diffHeaderSection: some View {
        HStack(spacing: 8) {
            if let file = selectedFileChange, let fullPath = selectedFileFullPath {
                FileIconView(path: fullPath, size: 14)
                Text(file.path)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                HStack(spacing: 6) {
                    if file.additions > 0 {
                        Text("+\(file.additions)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.green)
                    }
                    if file.deletions > 0 {
                        Text("-\(file.deletions)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.red)
                    }
                }
            } else {
                Text("Select a file to view diff")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.05))
    }

    @ViewBuilder
    private var diffContentSection: some View {
        if let file = selectedFileChange {
            if let lines = diffViewModel.loadedDiffs[file.path] {
                if lines.isEmpty {
                    noDiffView("No changes in this file")
                } else {
                    DiffView(lines: lines, fontSize: 12, fontFamily: "Menlo")
                }
            } else {
                diffLoadingView
                    .onAppear {
                        if !diffViewModel.loadingFiles.contains(file.path) && !diffViewModel.isBatchLoading {
                            loadDiffForFile(file.path)
                        }
                    }
            }
        } else {
            emptySelectionView
        }
    }

    // MARK: - History Views

    private var historyContentSection: some View {
        HSplitView {
            GitHistoryView(
                worktreePath: worktreePath,
                selectedCommit: selectedHistoryCommit,
                onSelectCommit: { commit in
                    selectedHistoryCommit = commit
                }
            )
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)

            historyDiffPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var historyDiffPanel: some View {
        VStack(spacing: 0) {
            historyDiffHeader
            Divider()
            historyDiffContentSection
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var historyDiffHeader: some View {
        HStack(spacing: 8) {
            if let commit = selectedHistoryCommit {
                Text(commit.shortHash)
                    .font(.caption.monospaced())

                Text(commit.message)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                Text(commit.relativeDate)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Working Changes")
                    .font(.caption)
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.05))
    }

    @ViewBuilder
    private var historyDiffContentSection: some View {
        if isHistoryDiffLoading {
            diffLoadingView
        } else if let error = historyDiffError {
            errorView(error) { loadHistoryDiff(for: selectedHistoryCommit) }
        } else if historyDiffOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            noDiffView("No diff to display")
        } else {
            DiffView(diffOutput: historyDiffOutput, fontSize: 12, fontFamily: "Menlo")
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack(spacing: 12) {
            Spacer()

            Button(action: { showCommit = true }) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .frame(width: 16, height: 16)
                    Text("Commit")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(hasUncommittedChanges ? Color.accentColor : Color.accentColor.opacity(0.5))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(isMerging || !hasUncommittedChanges)

            Button(action: merge) {
                HStack(spacing: 6) {
                    Group {
                        if isMerging {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.triangle.merge")
                        }
                    }
                    .frame(width: 16, height: 16)
                    Text("Merge")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(hasCommittedChanges ? Color.buttonGreen : Color.buttonGreen.opacity(0.5))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(isMerging || !hasCommittedChanges)

            Button(action: { showCreatePR = true }) {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle")
                        .frame(width: 16, height: 16)
                    Text("Create PR")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(hasCommittedChanges ? Color.purple : Color.purple.opacity(0.5))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(isMerging || !hasCommittedChanges)
        }
        .padding(16)
    }

    // MARK: - Actions

    private func loadChanges() {
        guard let worktreePath = card.worktreePath else {
            errorMessage = "No worktree path available"
            isLoading = false
            return
        }

        // Cancel existing tasks
        loadChangesTask?.cancel()
        let loadingFiles = diffViewModel.loadingFiles
        for file in loadingFiles {
            diffViewModel.cancelLoad(for: file)
        }
        diffViewModel.errors.removeAll()
        diffViewModel.loadedDiffs.removeAll()
        Task {
            await diffViewModel.invalidateCache()
        }

        isLoading = true
        errorMessage = nil

        loadChangesTask = Task {
            do {
                try Task.checkCancellation()
                currentBranch = try await GitService.getCurrentBranch(worktreePath: worktreePath)

                try Task.checkCancellation()
                let committedChanges = try await GitService.getBranchChangedFiles(
                    worktreePath: worktreePath,
                    targetBranch: selectedTargetBranch
                )
                hasCommittedChanges = !committedChanges.isEmpty
                hasUncommittedChanges = await GitService.hasUncommittedChanges(worktreePath: worktreePath)

                try Task.checkCancellation()
                // Show committed changes, or uncommitted if no commits yet
                if hasCommittedChanges {
                    branchChanges = committedChanges
                } else if hasUncommittedChanges {
                    let status = try await GitService.getStatus(worktreePath: worktreePath)
                    branchChanges = status.filesChanged
                } else {
                    branchChanges = []
                }

                totalAdditions = branchChanges.reduce(0) { $0 + $1.additions }
                totalDeletions = branchChanges.reduce(0) { $0 + $1.deletions }

                let untrackedFiles = Set(branchChanges.compactMap { change in
                    change.status == .untracked ? change.path : nil
                })
                diffViewModel.updateContext(
                    targetBranch: selectedTargetBranch,
                    hasCommittedChanges: hasCommittedChanges,
                    hasUncommittedChanges: hasUncommittedChanges,
                    untrackedFiles: untrackedFiles
                )

                if branchChanges.isEmpty {
                    selectedFilePath = nil
                } else if selectedFilePath == nil ||
                            !branchChanges.contains(where: { $0.path == selectedFilePath }) {
                    selectedFilePath = branchChanges.first?.path
                }

                isLoading = false

            } catch is CancellationError {
                // Task was cancelled, do nothing
            } catch {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    private func loadBranches() {
        guard let repoPath = repositoryPath,
              let worktreePath = card.worktreePath else { return }

        loadBranchesTask?.cancel()

        loadBranchesTask = Task {
            do {
                try Task.checkCancellation()
                guard let branches = try? await GitService.listBranches(repositoryPath: repoPath) else { return }
                let currentWorktreeBranch = try? await GitService.getCurrentBranch(worktreePath: worktreePath)

                try Task.checkCancellation()
                // Filter out the worktree's branch
                availableBranches = branches.map { branch in
                    BranchInfo(
                        name: branch.name,
                        isCurrent: branch.name == currentWorktreeBranch,
                        isRemote: branch.isRemote
                    )
                }

                let targetOptions = availableBranches.filter { !$0.isCurrent }
                let previousBranch = selectedTargetBranch

                // Try to find main or master
                if let main = targetOptions.first(where: { $0.name == "main" || $0.name == "master" }) {
                    selectedTargetBranch = main.name
                } else if let first = targetOptions.first {
                    selectedTargetBranch = first.name
                }

                // Reload changes if branch changed
                if selectedTargetBranch != previousBranch {
                    loadChanges()
                }
            } catch is CancellationError {
                // Cancelled
            }
        }
    }

    private func loadDiffForFile(_ path: String) {
        guard card.worktreePath != nil else { return }
        diffViewModel.loadDiff(for: path)
    }

    private func loadHistoryDiff(for commit: GitCommit?) {
        let path = worktreePath
        guard !path.isEmpty else { return }

        historyDiffTask?.cancel()
        historyDiffError = nil
        isHistoryDiffLoading = true
        historyDiffOutput = ""

        historyDiffTask = Task {
            do {
                let output = if let commit {
                    try await historyLogService.getCommitDiff(hash: commit.id, at: path)
                } else {
                    try await GitService.getDiff(worktreePath: path)
                }

                guard !Task.isCancelled else { return }
                historyDiffOutput = output
                isHistoryDiffLoading = false
            } catch {
                guard !Task.isCancelled else { return }
                historyDiffError = error.localizedDescription
                isHistoryDiffLoading = false
            }
        }
    }

    private func merge() {
        guard let worktreePath = card.worktreePath,
              let repoPath = repositoryPath else { return }

        isMerging = true
        errorMessage = nil

        Task {
            defer { isMerging = false }
            do {
                try await GitService.merge(
                    worktreePath: worktreePath,
                    targetBranch: selectedTargetBranch,
                    repositoryPath: repoPath
                )
                loadChanges()
            } catch let gitError as GitError {
                errorMessage = gitError.errorDescription ?? "Unknown error"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
