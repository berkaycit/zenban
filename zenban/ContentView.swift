//
//  ContentView.swift
//  zenban
//
//  Created by Berkay Cit on 25.12.2025.
//

import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(BoardStore.self) private var store
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var devServerSidebarRestoreVisibility: NavigationSplitViewVisibility?
    @State private var devServerReconfigureRestartInFlight = false

    var body: some View {
        @Bindable var store = store

        NavigationSplitView(columnVisibility: $columnVisibility) {
            // Sidebar
            BoardListView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 220)
        } content: {
            // Board content, Dev server, or Git changes
            Group {
                if store.showDevServer, let card = store.devServerCard {
                    DevServerView(
                        card: card,
                        setupCommand: store.devServerSetupCommand,
                        devCommand: store.devServerDevCommand,
                        autoOpenConsole: store.selectedBoard?.devServerConfig?.autoOpenConsole ?? false,
                        onDismiss: stopDevServerAndRestoreSidebarIfNeeded,
                        onReconfigure: store.openReconfigure
                    )
                    .id(card.id)
                } else if store.showGitChanges, let card = store.gitChangesCard, let board = store.selectedBoard {
                    GitChangesView(
                        card: card,
                        boardID: board.id,
                        onDismiss: store.stopGitChanges
                    )
                    .id(card.id)
                } else if store.showFileBrowser, let card = store.fileBrowserCard, let board = store.selectedBoard {
                    FileBrowserOverlayView(card: card, boardID: board.id)
                        .id(card.id)
                } else if let board = store.selectedBoard {
                    BoardView(board: board)
                } else {
                    EmptyStateView(
                        icon: "square.stack.3d.up",
                        title: "No Board Selected",
                        subtitle: "Select a board from the sidebar or create a new one"
                    )
                }
            }
            .navigationSplitViewColumnWidth(min: 600, ideal: 800, max: 1000)
        } detail: {
            // Card detail
            if let board = store.selectedBoard, let card = store.selectedCard {
                CardDetailView(card: card, boardID: board.id)
            } else {
                EmptyStateView(
                    icon: "rectangle.on.rectangle",
                    title: "No Card Selected",
                    subtitle: "Select a card to view its details"
                )
            }
        }
        .onChange(of: store.selectedBoardID) {
            store.clearSelectedCardIfNeededForSelectedBoardChange()
            store.draggedCardID = nil
            store.stopOverlays()
        }
        .onChange(of: store.selectedCardID) { _, newValue in
            guard let newValue else { return }
            NotificationService.shared.clearNotifications(for: newValue)
        }
        .onChange(of: store.showDevServer) { wasShowing, isShowing in
            handleDevServerVisibilityChange(wasShowing: wasShowing, isShowing: isShowing)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .frame(minWidth: 1200, minHeight: 600)
        .sheet(isPresented: $store.showDevServerConfig) {
            if let card = store.devServerCard,
               let worktreePath = card.worktreePath,
               let board = store.selectedBoard {
                DevServerCommandSheet(
                    worktreePath: worktreePath,
                    boardID: board.id,
                    isPresented: $store.showDevServerConfig,
                    onStart: { setup, dev in
                        handleDevServerCommandStart(setup: setup, dev: dev)
                    }
                )
            }
        }
        .sheet(isPresented: $store.showKeyboardShortcuts) {
            KeyboardShortcutsView()
        }
        .overlay {
            if store.showDeleteConfirmation, let card = store.selectedCard {
                ZStack {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                        .onTapGesture { store.cancelDeleteSelectedCard() }

                    DeleteConfirmationView(
                        cardTitle: card.title,
                        onDelete: store.confirmDeleteSelectedCard,
                        onCancel: store.cancelDeleteSelectedCard
                    )
                }
            }
        }
        .overlay {
            if store.showDependencySetup {
                ZStack {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()

                    DependencySetupView()
                }
            }
        }
    }

    private func handleDevServerCommandStart(setup: String?, dev: String) {
        if case .devServerReconfiguring = store.overlayState {
            devServerReconfigureRestartInFlight = true
        }
        store.confirmDevServerConfig(setup: setup, dev: dev)
    }

    private func stopDevServerAndRestoreSidebarIfNeeded() {
        devServerReconfigureRestartInFlight = false
        store.stopDevServer()
    }

    private func handleDevServerVisibilityChange(wasShowing: Bool, isShowing: Bool) {
        guard wasShowing != isShowing else { return }

        if isShowing {
            if devServerReconfigureRestartInFlight {
                devServerReconfigureRestartInFlight = false
                return
            }

            if isBoardListVisible(columnVisibility) {
                devServerSidebarRestoreVisibility = columnVisibility
                transitionBoardList(to: .doubleColumn)
            } else {
                devServerSidebarRestoreVisibility = nil
            }
            return
        }

        guard !devServerReconfigureRestartInFlight else { return }
        guard let restoreVisibility = devServerSidebarRestoreVisibility else { return }
        transitionBoardList(to: restoreVisibility)
        devServerSidebarRestoreVisibility = nil
    }

    private func isBoardListVisible(_ visibility: NavigationSplitViewVisibility) -> Bool {
        visibility != .doubleColumn && visibility != .detailOnly
    }

    private func transitionBoardList(to visibility: NavigationSplitViewVisibility) {
        guard columnVisibility != visibility else { return }

        if toggleSidebarWithSystemAnimation(from: columnVisibility, to: visibility) {
            return
        }

        withAnimation(.easeInOut(duration: 0.2)) {
            columnVisibility = visibility
        }
    }

    private func toggleSidebarWithSystemAnimation(
        from currentVisibility: NavigationSplitViewVisibility,
        to targetVisibility: NavigationSplitViewVisibility
    ) -> Bool {
        guard shouldUseSystemSidebarToggle(from: currentVisibility, to: targetVisibility) else { return false }

        let action = #selector(NSSplitViewController.toggleSidebar(_:))
        let targetWindow = NSApp.keyWindow ?? NSApp.mainWindow
        let dispatched = targetWindow?.firstResponder?.tryToPerform(action, with: nil) == true
            || NSApp.sendAction(action, to: nil, from: nil)
        guard dispatched else { return false }

        DispatchQueue.main.async {
            if columnVisibility != targetVisibility {
                columnVisibility = targetVisibility
            }
        }
        return true
    }

    private func shouldUseSystemSidebarToggle(
        from currentVisibility: NavigationSplitViewVisibility,
        to targetVisibility: NavigationSplitViewVisibility
    ) -> Bool {
        switch (currentVisibility, targetVisibility) {
        case (.all, .doubleColumn),
             (.automatic, .doubleColumn),
             (.doubleColumn, .all),
             (.doubleColumn, .automatic):
            true
        default:
            false
        }
    }
}

#Preview {
    ContentView()
        .environment(BoardStore())
}
