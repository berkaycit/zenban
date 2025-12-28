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
                    .frame(height: showTerminal && terminalManager.isTerminalAvailable ? 240 : nil)
                    .frame(maxHeight: showTerminal && terminalManager.isTerminalAvailable ? 240 : .infinity)

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
                .padding(20)
        }
    }

    private var cardInfoContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(card.column.rawValue)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(card.column.accentColor)
                    .clipShape(Capsule())

                Spacer()

                Button(action: deleteCard) {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }

            if isEditing {
                TextField("Card title", text: $editedTitle, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.title2)
                    .lineLimit(1...10)
                    .focused($isFocused)
                    .onSubmit(saveTitle)
                    .onExitCommand(perform: cancelEdit)

                HStack {
                    Button("Cancel", action: cancelEdit)
                        .keyboardShortcut(.cancelAction)
                    Button("Save", action: saveTitle)
                        .keyboardShortcut(.defaultAction)
                        .disabled(editedTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } else {
                Text(card.title)
                    .font(.title2)
                    .fontWeight(.medium)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        startEditing()
                    }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text("Created \(card.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "calendar")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }

            if store.board(for: boardID)?.repositoryPath != nil {
                worktreeSection
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Move to")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    ForEach(Column.allCases) { column in
                        Button(action: { moveToColumn(column) }) {
                            Text(column.rawValue)
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(card.column == column ? column.accentColor : Color.secondary.opacity(0.2))
                                .foregroundStyle(card.column == column ? .white : .primary)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .disabled(card.column == column)
                    }
                }
            }

            agentPickerSection
        }
    }

    private var currentAgent: Agent {
        card.agent ?? store.board(for: boardID)?.agent ?? .claude
    }

    private var agentPickerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Agent")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                ForEach(Agent.allCases) { agent in
                    Button(action: { switchAgent(to: agent) }) {
                        Text(agent.rawValue)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(currentAgent == agent ? Color.accentColor : Color.secondary.opacity(0.2))
                            .foregroundStyle(currentAgent == agent ? .white : .primary)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .disabled(currentAgent == agent)
                }
            }
        }
    }

    @ViewBuilder
    private var worktreeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Worktree")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Image(systemName: card.worktreePath != nil ? "checkmark.circle.fill" : "clock")
                    .foregroundStyle(card.worktreePath != nil ? .green : .orange)

                if let path = card.worktreePath {
                    Text((path as NSString).lastPathComponent)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("Creating...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
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

            if card.worktreePath != nil {
                HStack(spacing: 8) {
                    Button(action: { showGitChanges = true }) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.triangle.branch")
                            Text("View Changes")
                        }
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.accentColor.opacity(0.1))
                        .foregroundStyle(Color.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)

                    Button(action: startDevServer) {
                        HStack(spacing: 6) {
                            Image(systemName: "play.circle")
                            Text("Start Dev Server")
                        }
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.green.opacity(0.1))
                        .foregroundStyle(Color.green)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if store.board(for: boardID)?.devServerConfig != nil {
                            Button("Reconfigure Dev Server") {
                                showDevServerCommand = true
                            }
                        }
                    }
                }
            }
        }
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
