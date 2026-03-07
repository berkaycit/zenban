import SwiftUI
import AppKit

struct CardDetailView: View {
    let card: Card
    let boardID: UUID
    @Environment(BoardStore.self) private var store
    @Environment(TerminalManager.self) private var terminalManager
    @State private var editedTitle = ""
    @State private var isEditing = false
    @State private var showTerminal = true
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardInfoSection
                .frame(maxHeight: showTerminal && terminalManager.isTerminalAvailable ? 160 : .infinity)

            if terminalManager.isTerminalAvailable {
                Divider()
                terminalSection
            }
        }
        .animation(.easeOut(duration: 0.15), value: showTerminal)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .background(Color.cardBackground)
        .onAppear {
            editedTitle = card.title
        }
        .onChange(of: card.id) {
            editedTitle = card.title
            isEditing = false
        }
    }

    private var cardInfoSection: some View {
        ScrollView {
            cardInfoContent
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
    }

    private var board: Board? { store.board(for: boardID) }
    private var isGitRepository: Bool {
        guard let path = board?.repositoryPath else { return false }
        return GitService.isGitRepository(path: path)
    }

    private var cardInfoContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header: Title + Actions
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    if isEditing {
                        TextField("Card title", text: $editedTitle, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.title2)
                            .fontWeight(.semibold)
                            .lineLimit(1...3)
                            .focused($isFocused)
                            .onSubmit(saveTitle)
                            .onExitCommand(perform: cancelEdit)

                        HStack(spacing: 8) {
                            Button("Cancel", action: cancelEdit)
                                .keyboardShortcut(.cancelAction)
                            Button("Save", action: saveTitle)
                                .keyboardShortcut(.defaultAction)
                                .disabled(editedTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        .font(.subheadline)
                    } else {
                        Text(card.title)
                            .font(.title2)
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { startEditing() }
                    }

                    // Metadata line
                    Text(card.createdAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                // Quick actions
                HStack(spacing: 12) {
                    if isGitRepository && card.worktreePath != nil {
                        Button(action: { store.toggleGitChanges() }) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 15))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("View Changes")

                        Button(action: { store.toggleFileBrowser() }) {
                            Image(systemName: "folder")
                                .font(.system(size: 15))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("File Browser")

                        Button(action: startDevServer) {
                            Image(systemName: "play.circle")
                                .font(.system(size: 15))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Dev Server")
                        .contextMenu {
                            if board?.devServerConfig != nil {
                                Button("Reconfigure") { store.configureDevServer(for: card) }
                            }
                        }
                    }

                    Button(action: deleteCard) {
                        Image(systemName: "trash")
                            .font(.system(size: 15))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Delete")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Status & Controls
            HStack(spacing: 24) {
                // Column pills
                segmentedPills(Column.allCases, selected: card.column, color: { $0.accentColor }) { moveToColumn($0) }

                // Agent pills
                segmentedPills(Agent.allCases, selected: currentAgent, color: { _ in Color.accentColor }) { switchAgent(to: $0) }

                Spacer()

                // Worktree indicator
                if isGitRepository {
                    worktreeIndicator
                }
            }
        }
    }

    private func segmentedPills<T: Identifiable & RawRepresentable>(
        _ items: [T],
        selected: T,
        color: @escaping (T) -> Color,
        action: @escaping (T) -> Void
    ) -> some View where T.RawValue == String, T: Equatable {
        HStack(spacing: 2) {
            ForEach(items) { item in
                Button(action: { action(item) }) {
                    Text(item.rawValue)
                        .font(.callout)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(selected == item ? color(item) : Color.clear)
                        .foregroundStyle(selected == item ? .white : .secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(selected == item)
            }
        }
        .padding(4)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var worktreeIndicator: some View {
        HStack(spacing: 8) {
            Image(systemName: card.worktreePath != nil ? "checkmark.circle.fill" : "clock")
                .font(.system(size: 13))
                .foregroundStyle(card.worktreePath != nil ? .green : .orange)

            if let path = card.worktreePath {
                Text((path as NSString).lastPathComponent)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            } else {
                Text("Creating...")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
        }
        .contextMenu {
            if let path = card.worktreePath {
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
                }
            }
        }
    }

    private var currentAgent: Agent {
        card.agent ?? board?.agent ?? .claude
    }

    private func switchAgent(to agent: Agent) {
        store.updateCardAgent(card.id, agent: agent, in: boardID)
        terminalManager.switchAgent(for: card.id, to: agent)
    }

    private var terminalSection: some View {
        VStack(spacing: 0) {
            terminalHeader
            if showTerminal {
                CardWorkspaceDeckView(cardID: card.id, boardID: boardID, cardTitle: card.title)
                    .frame(minHeight: 200)
                    .frame(maxHeight: .infinity)
            }
        }
    }

    private var terminalHeader: some View {
        HStack {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
            Text("Terminal")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button(action: { showTerminal.toggle() }) {
                Image(systemName: showTerminal ? "chevron.down" : "chevron.up")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.1))
    }

    private func startEditing() {
        editedTitle = card.title
        isEditing = true
        isFocused = true
    }

    private func saveTitle() {
        let trimmed = editedTitle.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        store.updateCard(card.id, title: trimmed, in: boardID)
        isEditing = false
    }

    private func cancelEdit() {
        editedTitle = card.title
        isEditing = false
    }

    private func moveToColumn(_ column: Column) {
        store.moveCard(card.id, to: column, in: boardID)
    }

    private func deleteCard() {
        store.deleteCard(card.id, from: boardID)
    }

    private func startDevServer() {
        if let config = board?.devServerConfig {
            // Config exists, go directly to running
            store.startDevServerDirect(card: card, setup: config.setupCommand, dev: config.devCommand)
        } else {
            // No config, show configuration sheet
            store.configureDevServer(for: card)
        }
    }
}
