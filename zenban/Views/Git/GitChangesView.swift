import SwiftUI

struct GitChangesView: View {
    let card: Card
    let boardID: UUID
    let onDismiss: () -> Void
    @Environment(BoardStore.self) private var store

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
    @State private var expandedFiles: Set<String> = []
    @State private var fileDiffs: [String: String] = [:]
    @State private var isMerging = false

    // Task handles for cancellation
    @State private var loadChangesTask: Task<Void, any Error>?
    @State private var loadBranchesTask: Task<Void, any Error>?
    @State private var loadDiffTasks: [String: Task<Void, any Error>] = [:]

    private var repositoryPath: String? {
        store.board(for: boardID)?.repositoryPath
    }

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()

            contentSection
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footerSection
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.cardBackground)
        .compositingGroup()
        .onAppear {
            loadBranches()
            loadChanges()
        }
        .onDisappear {
            loadChangesTask?.cancel()
            loadBranchesTask?.cancel()
            for task in loadDiffTasks.values {
                task.cancel()
            }
            loadDiffTasks.removeAll()
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
        if isLoading {
            loadingView
        } else if let error = errorMessage {
            errorView(error)
        } else if branchChanges.isEmpty {
            emptyChangesView
        } else {
            changesListView
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

            Spacer()

            Button(action: { loadChanges() }) {
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
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

    private func errorView(_ error: String) -> some View {
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
            Button("Retry") {
                loadChanges()
            }
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

    private var changesListView: some View {
        VStack(spacing: 0) {
            branchInfoSection

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(branchChanges) { file in
                        DiffFileRow(
                            file: file,
                            isExpanded: Binding(
                                get: { expandedFiles.contains(file.path) },
                                set: { expanded in
                                    if expanded {
                                        expandedFiles.insert(file.path)
                                    } else {
                                        expandedFiles.remove(file.path)
                                    }
                                }
                            ),
                            diffContent: fileDiffs[file.path],
                            onNeedsDiff: {
                                // Only load if not already loaded or loading
                                if fileDiffs[file.path] == nil && loadDiffTasks[file.path] == nil {
                                    loadDiffForFile(file.path)
                                }
                            }
                        )
                    }
                }
                .padding(12)
            }
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
                .background(hasCommittedChanges ? Color.green : Color.green.opacity(0.5))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
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
        for task in loadDiffTasks.values {
            task.cancel()
        }
        loadDiffTasks.removeAll()

        isLoading = true
        errorMessage = nil
        fileDiffs = [:]
        expandedFiles = []

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

                // Files start collapsed - user expands what they need
                // expandedFiles already cleared at start of loadChanges()

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
        guard let worktreePath = card.worktreePath else { return }

        // Cancel existing task for this file if any
        loadDiffTasks[path]?.cancel()

        loadDiffTasks[path] = Task {
            // Try branch diff first, fall back to uncommitted diff
            var diff = (try? await GitService.getBranchFileDiff(
                worktreePath: worktreePath,
                targetBranch: selectedTargetBranch,
                file: path
            )) ?? ""

            // If branch diff is empty and we have uncommitted changes, get uncommitted diff
            if diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && hasUncommittedChanges {
                diff = (try? await GitService.getDiff(worktreePath: worktreePath, file: path)) ?? ""
            }

            guard !Task.isCancelled else {
                loadDiffTasks.removeValue(forKey: path)
                return
            }
            fileDiffs[path] = diff
            loadDiffTasks.removeValue(forKey: path)
        }
    }

    private func merge() {
        guard let worktreePath = card.worktreePath,
              let repoPath = repositoryPath else { return }

        isMerging = true
        errorMessage = nil

        Task {
            do {
                try await GitService.merge(
                    worktreePath: worktreePath,
                    targetBranch: selectedTargetBranch,
                    repositoryPath: repoPath
                )
                isMerging = false
                loadChanges()
            } catch let gitError as GitError {
                print("[GitChangesView] Merge failed with GitError: \(gitError)")
                errorMessage = gitError.errorDescription ?? "Unknown error"
                isMerging = false
            } catch {
                print("[GitChangesView] Merge failed with error: \(error)")
                errorMessage = error.localizedDescription
                isMerging = false
            }
        }
    }
}
