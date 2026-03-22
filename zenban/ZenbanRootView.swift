//
//  ContentView.swift
//  zenban
//
//  Created by Berkay Cit on 25.12.2025.
//

import AppKit
import SwiftUI

enum ZenbanRootContentMode: Equatable {
    case splitView
    case terminalFullscreenCardDetail
}

struct ZenbanRootView: View {
    @Environment(BoardStore.self) private var store
    @Environment(CmuxHostStore.self) private var cmuxHost
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var devServerSidebarRestoreVisibility: NavigationSplitViewVisibility?
    @State private var devServerReconfigureRestartInFlight = false

    var body: some View {
        @Bindable var store = store

        Group {
            if let fullscreenContext = terminalFullscreenContext {
                CardDetailView(card: fullscreenContext.card, boardID: fullscreenContext.boardID)
            } else {
                navigationSplitContent
            }
        }
        .onChange(of: store.selectedBoardID) {
            store.clearSelectedCardIfNeededForSelectedBoardChange()
            store.draggedCardID = nil
            store.stopOverlays()
            cmuxHost.syncSelection(card: store.selectedCard, boardID: store.selectedBoardID)
        }
        .onChange(of: store.selectedCardID) {
            cmuxHost.syncSelection(card: store.selectedCard, boardID: store.selectedBoardID)
        }
        .onChange(of: store.showDevServer) { wasShowing, isShowing in
            handleDevServerVisibilityChange(wasShowing: wasShowing, isShowing: isShowing)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .frame(minWidth: 1200, minHeight: 600)
        .background(
            WindowAccessor { window in
                cmuxHost.registerMainWindow(window)
            }
        )
        .onAppear {
            cmuxHost.syncSelection(card: store.selectedCard, boardID: store.selectedBoardID)
        }
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
        .alert(item: $store.deleteConfirmationRequest) { request in
            Alert(
                title: Text(request.content.title),
                message: Text(request.content.informativeText),
                primaryButton: .destructive(
                    Text(String(localized: "Delete", defaultValue: "Delete")),
                    action: store.confirmDeleteRequest
                ),
                secondaryButton: .cancel(
                    Text(String(localized: "common.cancel", defaultValue: "Cancel")),
                    action: store.cancelDeleteRequest
                )
            )
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

    @ViewBuilder
    private var navigationSplitContent: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            BoardListView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 220)
        } content: {
            Group {
                if store.showDevServer, let card = store.devServerCard {
                    DevServerView(
                        card: card,
                        boardID: store.selectedBoardID,
                        setupCommand: store.devServerSetupCommand,
                        devCommand: store.devServerDevCommand,
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
    }

    private var terminalFullscreenContext: (card: Card, boardID: UUID)? {
        guard Self.rootContentMode(
            selectedBoard: store.selectedBoard,
            selectedCard: store.selectedCard,
            terminalFullscreenCardID: store.terminalFullscreenCardID
        ) == .terminalFullscreenCardDetail,
        let board = store.selectedBoard,
        let card = store.selectedCard else {
            return nil
        }

        return (card, board.id)
    }

    static func rootContentMode(
        selectedBoard: Board?,
        selectedCard: Card?,
        terminalFullscreenCardID: UUID?
    ) -> ZenbanRootContentMode {
        guard selectedBoard != nil,
              let selectedCard,
              terminalFullscreenCardID == selectedCard.id else {
            return .splitView
        }

        return .terminalFullscreenCardDetail
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
    ZenbanRootView()
        .environment(BoardStore())
        .environment(CmuxHostStore())
}
