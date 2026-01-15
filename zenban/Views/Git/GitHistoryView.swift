import SwiftUI

struct GitHistoryView: View {
    let worktreePath: String
    let selectedCommit: GitCommit?
    let onSelectCommit: (GitCommit?) -> Void

    @State private var commits: [GitCommit] = []
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var hasMoreCommits = true
    @State private var errorMessage: String?

    private let logService = GitLogService()
    private let pageSize = 30

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if isLoading && commits.isEmpty {
                loadingView
            } else if let error = errorMessage, commits.isEmpty {
                errorView(error)
            } else if commits.isEmpty {
                emptyView
            } else {
                commitsList
            }
        }
        .task {
            await loadCommits()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("History")
                .font(.system(size: 12, weight: .medium))

            Spacer()

            if !commits.isEmpty {
                Text("\(commits.count)\(hasMoreCommits ? "+" : "")")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(Capsule())
            }

            Button {
                Task { await refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("Loading history...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(.orange)

            Text("Failed to load history")
                .font(.caption)

            Text(message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Retry") {
                Task { await loadCommits() }
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)

            Text("No commits yet")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var commitsList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if selectedCommit != nil {
                    workingChangesRow
                    Divider()
                }

                ForEach(commits) { commit in
                    commitRow(commit)
                        .onAppear {
                            if commit.id == commits.last?.id && hasMoreCommits && !isLoadingMore {
                                Task { await loadMoreCommits() }
                            }
                        }
                    Divider()
                }

                if isLoadingMore {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading more...")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                } else if hasMoreCommits {
                    Button {
                        Task { await loadMoreCommits() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 11))
                            Text("Load more")
                                .font(.caption)
                        }
                        .foregroundStyle(Color.accentColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var workingChangesRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "pencil.circle")
                .font(.system(size: 14))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text("Working Changes")
                    .font(.system(size: 12, weight: .medium))

                Text("View uncommitted changes")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelectCommit(nil)
        }
    }

    private func commitRow(_ commit: GitCommit) -> some View {
        let isSelected = selectedCommit?.id == commit.id

        return HStack(spacing: 10) {
            Text(commit.shortHash)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(commit.message)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 8) {
                    Text(commit.author)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)

                    Text(commit.relativeDate)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            HStack(spacing: 6) {
                if commit.filesChanged > 0 {
                    Text("\(commit.filesChanged)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Image(systemName: "doc")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }

                if commit.additions > 0 {
                    Text("+\(commit.additions)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.green)
                }

                if commit.deletions > 0 {
                    Text("-\(commit.deletions)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelectCommit(commit)
        }
    }

    private func loadCommits() async {
        isLoading = true
        errorMessage = nil

        do {
            let newCommits = try await logService.getCommitHistory(at: worktreePath, limit: pageSize, skip: 0)
            commits = newCommits
            hasMoreCommits = newCommits.count == pageSize
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func loadMoreCommits() async {
        guard !isLoadingMore && hasMoreCommits else { return }

        isLoadingMore = true

        do {
            let newCommits = try await logService.getCommitHistory(
                at: worktreePath,
                limit: pageSize,
                skip: commits.count
            )
            commits.append(contentsOf: newCommits)
            hasMoreCommits = newCommits.count == pageSize
        } catch {
            // Ignore load-more errors
        }

        isLoadingMore = false
    }

    private func refresh() async {
        commits.removeAll()
        hasMoreCommits = true
        await loadCommits()
    }
}
