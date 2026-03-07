import SwiftUI
import WebKit

struct CardWorkspaceDeckView: View {
    let cardID: UUID
    let boardID: UUID
    let cardTitle: String

    @Environment(TerminalManager.self) private var terminalManager

    @State private var mountedCardIds: [UUID]
    @State private var previousSelectedCardId: UUID?
    @State private var retiringCardId: UUID?
    @State private var handoffGeneration: UInt64 = 0
    @State private var handoffFallbackTask: Task<Void, Never>?

    init(cardID: UUID, boardID: UUID, cardTitle: String) {
        self.cardID = cardID
        self.boardID = boardID
        self.cardTitle = cardTitle
        _mountedCardIds = State(initialValue: [cardID])
        _previousSelectedCardId = State(initialValue: cardID)
    }

    var body: some View {
        let currentRecord = terminalManager.workspaceRecord(for: cardID, boardID: boardID, cardTitle: cardTitle)
        let effectiveRetiringCardId = retiringCardId ?? inferredRetiringCardId

        ZStack {
            ForEach(mountedRecords(currentRecord: currentRecord), id: \.record.cardID) { entry in
                let isSelected = entry.record.cardID == cardID
                let isRetiring = effectiveRetiringCardId == entry.record.cardID
                let isVisible = isSelected || isRetiring

                TerminalContainerView(
                    cardID: entry.record.cardID,
                    boardID: entry.record.boardID,
                    cardTitle: entry.record.cardTitle,
                    isWorkspaceVisible: isVisible,
                    isWorkspaceInputActive: isSelected && (NSApp?.isActive ?? false),
                    workspacePortalPriority: isSelected ? 2 : (isRetiring ? 1 : 0)
                )
                .opacity(isVisible ? 1 : 0)
                .allowsHitTesting(isSelected)
                .accessibilityHidden(!isVisible)
                .zIndex(isSelected ? 2 : (isRetiring ? 1 : 0))
            }
        }
        .onAppear {
            terminalManager.activateWorkspace(for: currentRecord.cardID)
            terminalManager.completeCardHandoff(
                retiringCardID: nil,
                selectedCardID: currentRecord.cardID,
                reason: "deck_appear"
            )
            reconcileMountedCardIds(selectedCardID: currentRecord.cardID)
        }
        .onChange(of: cardID) { _, newValue in
            _ = terminalManager.workspaceRecord(for: newValue, boardID: boardID, cardTitle: cardTitle)
            startCardHandoffIfNeeded(newSelectedCardID: newValue)
            reconcileMountedCardIds(selectedCardID: newValue)
        }
        .onChange(of: cardTitle) { _, newValue in
            _ = terminalManager.workspaceRecord(for: cardID, boardID: boardID, cardTitle: newValue)
        }
        .onDisappear {
            teardownDeck()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyDidFocusSurface)) { notification in
            guard let focusedCardId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID else { return }
            completeCardHandoffIfNeeded(focusedCardID: focusedCardId, reason: "focus")
        }
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyDidBecomeFirstResponderSurface)) { notification in
            guard let focusedCardId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID else { return }
            completeCardHandoffIfNeeded(focusedCardID: focusedCardId, reason: "first_responder")
        }
        .onReceive(NotificationCenter.default.publisher(for: .browserDidBecomeFirstResponderWebView)) { notification in
            guard let webView = notification.object as? WKWebView,
                  let record = terminalManager.record(forWorkspaceID: cardID),
                  let focusedPanelId = record.workspace.focusedPanelId,
                  let focusedBrowser = record.workspace.browserPanel(for: focusedPanelId),
                  focusedBrowser.webView === webView else { return }
            completeCardHandoffIfNeeded(focusedCardID: cardID, reason: "browser_first_responder")
        }
        .onReceive(NotificationCenter.default.publisher(for: .browserDidFocusAddressBar)) { notification in
            guard let panelId = notification.object as? UUID,
                  let record = terminalManager.record(forWorkspaceID: cardID),
                  record.workspace.focusedPanelId == panelId,
                  record.workspace.browserPanel(for: panelId) != nil else { return }
            completeCardHandoffIfNeeded(focusedCardID: cardID, reason: "browser_address_bar")
        }
    }

    private func mountedRecords(currentRecord: TerminalManager.WorkspaceRecord) -> [MountedRecord] {
        let selectedCardID = currentRecord.cardID
        var resolved: [MountedRecord] = []
        var seenCardIds: Set<UUID> = []

        for mountedCardID in mountedCardIds {
            let record: TerminalManager.WorkspaceRecord? = if mountedCardID == selectedCardID {
                currentRecord
            } else {
                terminalManager.record(forWorkspaceID: mountedCardID)
            }

            guard let record, seenCardIds.insert(record.cardID).inserted else { continue }
            resolved.append(MountedRecord(record: record))
        }

        if seenCardIds.insert(selectedCardID).inserted {
            resolved.insert(MountedRecord(record: currentRecord), at: 0)
        }

        return resolved
    }

    private var inferredRetiringCardId: UUID? {
        guard retiringCardId == nil else { return nil }
        guard let previousSelectedCardId, previousSelectedCardId != cardID else { return nil }
        return previousSelectedCardId
    }

    private func startCardHandoffIfNeeded(newSelectedCardID: UUID) {
        let oldSelectedCardID = previousSelectedCardId
        previousSelectedCardId = newSelectedCardID

        guard let oldSelectedCardID, oldSelectedCardID != newSelectedCardID else {
            handoffFallbackTask?.cancel()
            handoffFallbackTask = nil
            retiringCardId = nil
            terminalManager.activateWorkspace(for: newSelectedCardID)
            terminalManager.completeCardHandoff(
                retiringCardID: nil,
                selectedCardID: newSelectedCardID,
                reason: "no_handoff"
            )
            return
        }

        handoffGeneration &+= 1
        let generation = handoffGeneration
        retiringCardId = oldSelectedCardID
        terminalManager.startCardHandoff(from: oldSelectedCardID, to: newSelectedCardID)

        handoffFallbackTask?.cancel()
        handoffFallbackTask = Task { [generation] in
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
            } catch {
                return
            }

            await MainActor.run {
                guard handoffGeneration == generation else { return }
                completeCardHandoff(reason: "timeout")
            }
        }
    }

    private func completeCardHandoffIfNeeded(focusedCardID: UUID, reason: String) {
        guard focusedCardID == cardID else { return }
        guard retiringCardId != nil else { return }
        completeCardHandoff(reason: reason)
    }

    private func completeCardHandoff(reason: String) {
        handoffFallbackTask?.cancel()
        handoffFallbackTask = nil

        let retiring = retiringCardId
        terminalManager.completeCardHandoff(
            retiringCardID: retiring,
            selectedCardID: cardID,
            reason: reason
        )
        retiringCardId = nil
        reconcileMountedCardIds(selectedCardID: cardID)
    }

    private func reconcileMountedCardIds(selectedCardID: UUID) {
        var nextMountedCardIds = [selectedCardID]

        if let retiringCardId,
           retiringCardId != selectedCardID,
           terminalManager.record(forWorkspaceID: retiringCardId) != nil {
            nextMountedCardIds.append(retiringCardId)
        }

        mountedCardIds = nextMountedCardIds
    }

    private func teardownDeck() {
        handoffFallbackTask?.cancel()
        handoffFallbackTask = nil

        for mountedCardID in mountedCardIds {
            terminalManager.hidePortalViews(for: mountedCardID)
        }

        terminalManager.completeCardHandoff(
            retiringCardID: nil,
            selectedCardID: nil,
            reason: "deck_disappear"
        )
        terminalManager.clearActiveWorkspace()

        mountedCardIds = []
        previousSelectedCardId = nil
        retiringCardId = nil
    }
}

private extension CardWorkspaceDeckView {
    struct MountedRecord {
        let record: TerminalManager.WorkspaceRecord
    }
}
