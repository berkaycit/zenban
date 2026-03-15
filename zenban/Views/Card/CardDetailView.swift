import AppKit
import SwiftUI

struct CardDetailView: View {
    let card: Card
    let boardID: UUID

    @Environment(BoardStore.self) private var store
    @Environment(CmuxHostStore.self) private var cmuxHost
    @State private var editedTitle = ""
    @State private var isEditing = false
    @State private var activeWorkspace: Workspace?
    @State private var retiringWorkspace: Workspace?
    @State private var workspaceHandoffGeneration: UInt64 = 0
    @State private var workspaceHandoffReadyTask: Task<Void, Never>?
    @State private var workspaceHandoffFallbackTask: Task<Void, Never>?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardInfoSection
                .frame(maxHeight: 180)

            Divider()

            terminalSection
                .frame(minHeight: 220)
                .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .background(Color.cardBackground.ignoresSafeArea(.container, edges: .top))
        .onAppear {
            editedTitle = card.title
            syncDisplayedWorkspace()
        }
        .onDisappear(perform: teardownDisplayedWorkspaces)
        .onChange(of: card.id) {
            editedTitle = card.title
            isEditing = false
            syncDisplayedWorkspace()
        }
        .onChange(of: card.worktreePath) {
            syncDisplayedWorkspace()
        }
        .onChange(of: card.column) {
            syncDisplayedWorkspace()
        }
        .onChange(of: card.agent) {
            cmuxHost.updateAgentLaunch(for: card, boardID: boardID)
        }
        .onChange(of: card.title) {
            cmuxHost.updateTitle(for: card.id, title: card.title)
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
    private var agentSummary: String? {
        cmuxHost.agentSummary(for: card.id) ?? card.agentSummary
    }
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
                    if let agentSummary {
                        Text(agentSummary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

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
                        .accessibilityLabel("View Changes")

                        Button(action: { store.toggleFileBrowser() }) {
                            Image(systemName: "folder")
                                .font(.system(size: 15))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("File Browser")
                        .accessibilityLabel("File Browser")

                        Button(action: startDevServer) {
                            Image(systemName: "play.circle")
                                .font(.system(size: 15))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Dev Server")
                        .accessibilityLabel("Dev Server")
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
                    .accessibilityLabel("Delete card")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.pillBackground)
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
        .background(Color.pillBackground)
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

                Button {
                    openWorktreeFolder(path)
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Open Worktree Folder")
                .accessibilityLabel("Open worktree folder")
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

    private func openWorktreeFolder(_ path: String) {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        _ = NSWorkspace.shared.open(url)
    }

    private var currentAgent: Agent {
        card.agent ?? board?.agent ?? .claude
    }

    private func switchAgent(to agent: Agent) {
        store.updateCardAgent(card.id, agent: agent, in: boardID)
    }

    @ViewBuilder
    private var terminalSection: some View {
        if activeWorkspace != nil || retiringWorkspace != nil {
            ZStack {
                if let retiringWorkspace, retiringWorkspace.id != activeWorkspace?.id {
                    workspaceContent(
                        retiringWorkspace,
                        isVisible: true,
                        isInputActive: false,
                        portalPriority: 0
                    )
                    .allowsHitTesting(false)
                    .zIndex(0)
                }

                if let activeWorkspace {
                    workspaceContent(
                        activeWorkspace,
                        isVisible: true,
                        isInputActive: true,
                        portalPriority: 1
                    )
                    .zIndex(1)
                }
            }
        } else if showsDoneTerminalPlaceholder {
            doneTerminalPlaceholder
        } else {
            workspacePlaceholder
        }
    }

    private func workspaceContent(
        _ workspace: Workspace,
        isVisible: Bool,
        isInputActive: Bool,
        portalPriority: Int
    ) -> some View {
        WorkspaceContentView(
            workspace: workspace,
            isWorkspaceVisible: isVisible,
            isWorkspaceInputActive: isInputActive,
            workspacePortalPriority: portalPriority,
            onThemeRefreshRequest: nil
        )
        .id(workspace.id)
        .environmentObject(cmuxHost.notificationStore)
    }

    private func syncDisplayedWorkspace() {
        cmuxHost.syncSelection(card: card, boardID: boardID)
        if card.column == .done {
            transitionToWorkspace(nil)
        } else {
            transitionToWorkspace(cmuxHost.workspace(for: card.id))
        }
    }

    private func transitionToWorkspace(_ targetWorkspace: Workspace?) {
        let previousActiveWorkspace = activeWorkspace
        let previousRetiringWorkspace = retiringWorkspace

        guard let targetWorkspace else {
            cancelWorkspaceHandoffTasks()
            hidePortalViews(for: previousActiveWorkspace, previousRetiringWorkspace)
            activeWorkspace = nil
            retiringWorkspace = nil
            return
        }

        if previousActiveWorkspace == nil {
            cancelWorkspaceHandoffTasks()
            if previousRetiringWorkspace?.id != targetWorkspace.id {
                hidePortalViews(for: previousRetiringWorkspace)
            }
            activeWorkspace = targetWorkspace
            retiringWorkspace = nil
            return
        }

        guard previousActiveWorkspace?.id != targetWorkspace.id else {
            activeWorkspace = targetWorkspace
            return
        }

        cancelWorkspaceHandoffTasks()

        if let previousRetiringWorkspace,
           previousRetiringWorkspace.id != targetWorkspace.id,
           previousRetiringWorkspace.id != previousActiveWorkspace?.id {
            hidePortalViews(for: previousRetiringWorkspace)
        }

        activeWorkspace = targetWorkspace
        retiringWorkspace = previousActiveWorkspace
        scheduleWorkspaceHandoffCompletion(for: targetWorkspace)
    }

    private func scheduleWorkspaceHandoffCompletion(for workspace: Workspace) {
        guard retiringWorkspace != nil else { return }

        workspaceHandoffGeneration &+= 1
        let generation = workspaceHandoffGeneration
        let workspaceID = workspace.id

        workspaceHandoffReadyTask = Task { @MainActor in
            for delay in [0, 20_000_000, 40_000_000, 60_000_000] {
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay))
                }
                if Task.isCancelled { return }

                guard workspaceHandoffGeneration == generation,
                      retiringWorkspace != nil,
                      activeWorkspace?.id == workspaceID,
                      let activeWorkspace,
                      canCompleteWorkspaceHandoffImmediately(for: activeWorkspace) else {
                    continue
                }

                completeWorkspaceHandoff()
                return
            }
        }

        workspaceHandoffFallbackTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { return }

            guard workspaceHandoffGeneration == generation,
                  retiringWorkspace != nil,
                  activeWorkspace?.id == workspaceID else {
                return
            }

            completeWorkspaceHandoff()
        }
    }

    private func canCompleteWorkspaceHandoffImmediately(for workspace: Workspace) -> Bool {
        if let focusedPanelId = workspace.focusedPanelId,
           workspace.browserPanel(for: focusedPanelId) != nil {
            return true
        }
        return workspace.hasLoadedTerminalSurface()
    }

    private func completeWorkspaceHandoff() {
        cancelWorkspaceHandoffTasks()
        hidePortalViews(for: retiringWorkspace)
        retiringWorkspace = nil
    }

    private func teardownDisplayedWorkspaces() {
        cancelWorkspaceHandoffTasks()
        hidePortalViews(for: activeWorkspace, retiringWorkspace)
        activeWorkspace = nil
        retiringWorkspace = nil
    }

    private func cancelWorkspaceHandoffTasks() {
        workspaceHandoffGeneration &+= 1
        workspaceHandoffReadyTask?.cancel()
        workspaceHandoffReadyTask = nil
        workspaceHandoffFallbackTask?.cancel()
        workspaceHandoffFallbackTask = nil
    }

    private func hidePortalViews(for workspaces: Workspace?...) {
        var hiddenWorkspaceIds = Set<UUID>()
        for workspace in workspaces.compactMap({ $0 }) {
            guard hiddenWorkspaceIds.insert(workspace.id).inserted else { continue }
            workspace.hideAllTerminalPortalViews()
            workspace.hideAllBrowserPortalViews()
        }
    }

    private var workspacePlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)

            Text(cmuxHost.isWaitingForWorktree(for: card, boardID: boardID) ? "Preparing workspace..." : "Preparing terminal...")
                .font(.headline)

            Text(placeholderSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.codeBackground)
    }

    private var doneTerminalPlaceholder: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)

            Text(String(localized: "done.terminal.closed.title", defaultValue: "Terminal is closed"))
                .font(.headline)

            Text(
                String(
                    localized: "done.terminal.closed.message",
                    defaultValue: "Done cards keep their terminal closed until you choose to reopen it."
                )
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 360)

            Button(String(localized: "done.terminal.open", defaultValue: "Open Terminal"), action: openTerminal)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.codeBackground)
    }

    private var placeholderSubtitle: String {
        if cmuxHost.isWaitingForWorktree(for: card, boardID: boardID) {
            return "The card worktree is still being created. The Zenban workspace will appear here as soon as it is ready."
        }
        return "The Zenban workspace is starting up for this card."
    }

    private var showsDoneTerminalPlaceholder: Bool {
        card.column == .done && !cmuxHost.isWaitingForWorktree(for: card, boardID: boardID)
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

    private func openTerminal() {
        cmuxHost.openTerminal(for: card, boardID: boardID)
        transitionToWorkspace(cmuxHost.workspace(for: card.id))
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
