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
    @State private var showGitChanges = false
    @State private var showDevServer = false
    @State private var showDevServerCommand = false
    @State private var devServerSetupCommand: String?
    @State private var devServerDevCommand = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            // Normal card detail content
            VStack(alignment: .leading, spacing: 0) {
                cardInfoSection
                    .frame(height: showTerminal && terminalManager.isTerminalAvailable ? 160 : nil)
                    .frame(maxHeight: showTerminal && terminalManager.isTerminalAvailable ? 160 : .infinity)

                if terminalManager.isTerminalAvailable {
                    Divider()
                    terminalSection
                }
            }

            // Git changes overlay
            if showGitChanges {
                GitChangesView(
                    card: card,
                    boardID: boardID,
                    onDismiss: { showGitChanges = false }
                )
                .zIndex(1)
            }

            // Dev server overlay
            if showDevServer {
                DevServerView(
                    card: card,
                    setupCommand: devServerSetupCommand,
                    devCommand: devServerDevCommand,
                    onDismiss: { showDevServer = false }
                )
                .zIndex(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .background(Color.cardBackground)
        .animation(.easeOut(duration: 0.15), value: showGitChanges)
        .animation(.easeOut(duration: 0.15), value: showDevServer)
        .onAppear {
            editedTitle = card.title
        }
        .onChange(of: card.id) {
            editedTitle = card.title
            isEditing = false
            showGitChanges = false
            showDevServer = false
        }
        .sheet(isPresented: $showDevServerCommand) {
            if let worktreePath = card.worktreePath {
                DevServerCommandSheet(
                    worktreePath: worktreePath,
                    boardID: boardID,
                    isPresented: $showDevServerCommand,
                    onStart: { setup, dev in
                        devServerSetupCommand = setup
                        devServerDevCommand = dev
                        showDevServerCommand = false
                        showDevServer = true
                    }
                )
            }
        }
    }

    private var cardInfoSection: some View {
        ScrollView {
            cardInfoContent
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
        }
    }

    private var cardInfoContent: some View {
        VStack(alignment: .leading, spacing: 24) {
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
                    if store.board(for: boardID)?.repositoryPath != nil && card.worktreePath != nil {
                        Button(action: { showGitChanges = true }) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 15))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("View Changes")

                        Button(action: startDevServer) {
                            Image(systemName: "play.circle")
                                .font(.system(size: 15))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Dev Server")
                        .contextMenu {
                            if store.board(for: boardID)?.devServerConfig != nil {
                                Button("Reconfigure") { showDevServerCommand = true }
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
                HStack(spacing: 2) {
                    ForEach(Column.allCases) { column in
                        Button(action: { moveToColumn(column) }) {
                            Text(column.rawValue)
                                .font(.callout)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(card.column == column ? column.accentColor : Color.clear)
                                .foregroundStyle(card.column == column ? .white : .secondary)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .disabled(card.column == column)
                    }
                }
                .padding(4)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))

                // Agent pills
                HStack(spacing: 2) {
                    ForEach(Agent.allCases) { agent in
                        Button(action: { switchAgent(to: agent) }) {
                            Text(agent.rawValue)
                                .font(.callout)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(currentAgent == agent ? Color.accentColor : Color.clear)
                                .foregroundStyle(currentAgent == agent ? .white : .secondary)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .disabled(currentAgent == agent)
                    }
                }
                .padding(4)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))

                Spacer()

                // Worktree indicator
                if store.board(for: boardID)?.repositoryPath != nil {
                    worktreeIndicator
                }
            }
        }
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
        card.agent ?? store.board(for: boardID)?.agent ?? .claude
    }

    private func switchAgent(to agent: Agent) {
        store.updateCardAgent(card.id, agent: agent, in: boardID)
        terminalManager.switchAgent(for: card.id, to: agent)
    }

    private var terminalSection: some View {
        VStack(spacing: 0) {
            terminalHeader
            if showTerminal {
                TerminalContainerView(cardID: card.id, boardID: boardID, cardTitle: card.title)
                    .id(card.id)
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
        // Check if config exists for this board
        if let config = store.board(for: boardID)?.devServerConfig {
            // Use saved config (always pass setupCommand, DevServerView checks per worktree)
            devServerSetupCommand = config.setupCommand
            devServerDevCommand = config.devCommand
            showDevServer = true
        } else {
            // Show configuration sheet
            showDevServerCommand = true
        }
    }
}
