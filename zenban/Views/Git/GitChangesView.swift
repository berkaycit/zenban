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
    @State private var isHistoryDiffLoading = false
    @State private var historyDiffError: String?

    // History files state
    @State private var historyCommitFiles: [CommitFileChange] = []
    @State private var expandedHistoryFiles: Set<String> = []
    @State private var historyFileDiffs: [String: String] = [:]
    @State private var loadingHistoryFileDiffs: Set<String> = []

    // Panel widths for HStack layout (like DevServerView)
    @State private var changesListWidth: CGFloat = 240
    @State private var historyListWidth: CGFloat = 300

    // Task handles for cancellation
    @State private var loadChangesTask: Task<Void, Never>?
    @State private var loadBranchesTask: Task<Void, Never>?
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
        .clipped()
        .background(Color.cardBackground)
        .compositingGroup()
        .task {
            loadBranches()
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
            diffViewModel.cancelAll()
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
            .accessibilityLabel("Back")

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
            }

            Spacer()

            if selectedTab == .changes {
                Button(action: { loadChanges() }) {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(isLoading)
                .accessibilityLabel("Refresh changes")
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
        .background(Color.secondaryBackground)
    }

    // MARK: - Content Views

    private var loadingView: some View {
        placeholderView(message: "Loading changes...", showsSpinner: true)
    }

    private func errorView(_ error: String, onRetry: @escaping () -> Void) -> some View {
        placeholderView(
            icon: "exclamationmark.triangle",
            title: "Unable to Load",
            message: error,
            tint: .orange,
            actionTitle: "Retry",
            action: onRetry
        )
    }

    private var emptyChangesView: some View {
        placeholderView(
            icon: "checkmark.circle",
            title: "No changes",
            message: "Working tree is clean",
            tint: .green
        )
    }

    private var diffLoadingView: some View {
        placeholderView(message: "Loading diff...", showsSpinner: true)
    }

    private var emptySelectionView: some View {
        placeholderView(icon: "doc.text", message: "Select a file to view its diff")
    }

    private func noDiffView(_ message: String) -> some View {
        placeholderView(icon: "checkmark.circle", message: message, tint: .green)
    }

    private func placeholderView(
        icon: String? = nil,
        title: String? = nil,
        message: String,
        tint: Color = .secondary,
        showsSpinner: Bool = false,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 8) {
            Spacer()

            if showsSpinner {
                ProgressView()
                    .controlSize(.regular)
            } else if let icon {
                Image(systemName: icon)
                    .font(.largeTitle)
                    .foregroundStyle(tint)
            }

            if let title {
                Text(title)
                    .font(.headline)
            }

            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
            }

            Spacer()
        }
    }

    private var changesListView: some View {
        HStack(spacing: 0) {
            changesListPanel
                .frame(width: changesListWidth)

            panelResizeHandle(width: $changesListWidth, minWidth: 240, maxWidth: 280)

            diffDetailPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func panelResizeHandle(width: Binding<CGFloat>, minWidth: CGFloat, maxWidth: CGFloat) -> some View {
        Rectangle()
            .fill(Color.separator)
            .frame(width: 1)
            .overlay(
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let newWidth = width.wrappedValue + value.translation.width
                                width.wrappedValue = max(minWidth, min(maxWidth, newWidth))
                            }
                    )
                    .onHover { hovering in
                        if hovering {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
            )
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
        .background(Color.secondaryBackground)
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
                        if !diffViewModel.loadingFiles.contains(file.path) {
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
        HStack(spacing: 0) {
            GitHistoryView(
                worktreePath: worktreePath,
                selectedCommit: selectedHistoryCommit,
                onSelectCommit: { commit in
                    selectedHistoryCommit = commit
                }
            )
            .frame(width: historyListWidth)

            panelResizeHandle(width: $historyListWidth, minWidth: 320, maxWidth: 360)

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
        .background(Color.secondaryBackground)
    }

    @ViewBuilder
    private var historyDiffContentSection: some View {
        if isHistoryDiffLoading && historyCommitFiles.isEmpty {
            diffLoadingView
        } else if let error = historyDiffError {
            errorView(error) { loadHistoryDiff(for: selectedHistoryCommit) }
        } else if historyCommitFiles.isEmpty {
            noDiffView("No files changed")
        } else {
            historyFilesListView
        }
    }

    private var historyFilesListView: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(historyCommitFiles) { file in
                    historyFileRow(file)
                }
            }
        }
    }

    @ViewBuilder
    private func historyFileRow(_ file: CommitFileChange) -> some View {
        let isExpanded = expandedHistoryFiles.contains(file.path)

        VStack(spacing: 0) {
            Button {
                toggleHistoryFile(file)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)

                    Image(systemName: fileIcon(for: file.path))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    Text(file.path)
                        .font(.system(size: 14, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    HStack(spacing: 4) {
                        if file.additions > 0 {
                            Text("+\(file.additions)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.green)
                        }
                        if file.deletions > 0 {
                            Text("-\(file.deletions)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.red)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                let isLoading = loadingHistoryFileDiffs.contains(file.path)

                if isLoading {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading diff...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.codeBackground)
                } else if let diff = historyFileDiffs[file.path] {
                    DiffView(diffOutput: diff, fontSize: 12, fontFamily: "Menlo")
                        .frame(minHeight: 812, maxHeight: 812)
                }
            }

            Divider()
        }
    }

    private func fileIcon(for path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "js", "ts", "jsx", "tsx": return "chevron.left.forwardslash.chevron.right"
        case "json": return "curlybraces"
        case "md": return "doc.text"
        case "css", "scss": return "paintbrush"
        case "html": return "globe"
        default: return "doc"
        }
    }

    private func toggleHistoryFile(_ file: CommitFileChange) {
        if expandedHistoryFiles.contains(file.path) {
            expandedHistoryFiles.remove(file.path)
        } else {
            expandedHistoryFiles.insert(file.path)
            if historyFileDiffs[file.path] == nil {
                loadHistoryFileDiff(for: file)
            }
        }
    }

    private func loadHistoryFileDiff(for file: CommitFileChange) {
        loadingHistoryFileDiffs.insert(file.path)

        Task {
            do {
                let diff: String
                if let commit = selectedHistoryCommit {
                    diff = try await historyLogService.getCommitFileDiff(
                        hash: commit.id,
                        filePath: file.path,
                        at: worktreePath
                    )
                } else {
                    diff = try await GitService.getDiff(worktreePath: worktreePath, file: file.path)
                }
                historyFileDiffs[file.path] = diff
            } catch {
                historyFileDiffs[file.path] = "Failed to load diff: \(error.localizedDescription)"
            }
            loadingHistoryFileDiffs.remove(file.path)
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

        isLoading = true
        errorMessage = nil

        loadChangesTask = Task {
            await diffViewModel.reset()

            do {
                try Task.checkCancellation()

                async let currentBranchValue = GitService.getCurrentBranch(worktreePath: worktreePath)
                async let committedChangesValue = GitService.getBranchChangedFiles(
                    worktreePath: worktreePath,
                    targetBranch: selectedTargetBranch
                )

                try Task.checkCancellation()
                currentBranch = try await currentBranchValue
                let committedChanges = try await committedChangesValue
                hasCommittedChanges = !committedChanges.isEmpty

                if hasCommittedChanges {
                    hasUncommittedChanges = await GitService.hasUncommittedChanges(worktreePath: worktreePath)
                    branchChanges = committedChanges
                } else {
                    let status = try await GitService.getStatus(worktreePath: worktreePath)
                    hasUncommittedChanges = !status.filesChanged.isEmpty
                    branchChanges = status.filesChanged
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
        guard let worktreePath = card.worktreePath else {
            loadChanges()
            return
        }

        loadBranchesTask?.cancel()
        let previousBranch = selectedTargetBranch

        loadBranchesTask = Task {
            do {
                try Task.checkCancellation()

                guard let repoPath = repositoryPath else {
                    loadChanges()
                    return
                }

                async let branchesValue = GitService.listBranches(repositoryPath: repoPath)
                async let currentWorktreeBranchValue = GitService.getCurrentBranch(worktreePath: worktreePath)
                let branches = try await branchesValue
                let currentWorktreeBranch = try? await currentWorktreeBranchValue

                try Task.checkCancellation()
                availableBranches = branches.map { branch in
                    BranchInfo(
                        name: branch.name,
                        isCurrent: branch.name == currentWorktreeBranch,
                        isRemote: branch.isRemote
                    )
                }

                let targetOptions = availableBranches.filter { !$0.isCurrent }

                // Try to find main or master
                if let main = targetOptions.first(where: { $0.name == "main" || $0.name == "master" }) {
                    selectedTargetBranch = main.name
                } else if let first = targetOptions.first {
                    selectedTargetBranch = first.name
                }
            } catch is CancellationError {
                return
            } catch {
                availableBranches = []
            }

            guard !Task.isCancelled else { return }
            if selectedTargetBranch == previousBranch {
                loadChanges()
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
        historyCommitFiles = []
        expandedHistoryFiles = []
        historyFileDiffs = [:]

        historyDiffTask = Task {
            do {
                if let commit {
                    let files = try await historyLogService.getCommitFiles(hash: commit.id, at: path)
                    guard !Task.isCancelled else { return }
                    historyCommitFiles = files
                } else {
                    // For working changes, use the branch changes
                    historyCommitFiles = branchChanges.map { change in
                        CommitFileChange(path: change.path, additions: change.additions, deletions: change.deletions)
                    }
                }
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
