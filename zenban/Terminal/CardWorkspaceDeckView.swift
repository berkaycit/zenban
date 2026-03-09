import SwiftUI
import WebKit
#if DEBUG
import Bonsplit
#endif

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
    @State private var cardSwitchDebounceTask: Task<Void, Never>?
    /// Cached record for the currently selected card. Updated in onAppear/onChange,
    /// read in body via the read-only path to avoid mutating @Observable during evaluation.
    @State private var cachedRecord: TerminalManager.WorkspaceRecord?

#if DEBUG
    private func debugMountedSummary(_ currentRecord: TerminalManager.WorkspaceRecord? = nil) -> String {
        let mounted = mountedCardIds.map { String($0.uuidString.prefix(5)) }.joined(separator: ",")
        return
            "selected=\(cardID.uuidString.prefix(5)) previous=\(previousSelectedCardId?.uuidString.prefix(5) ?? "nil") " +
            "retiring=\(retiringCardId?.uuidString.prefix(5) ?? inferredRetiringCardId?.uuidString.prefix(5) ?? "nil") " +
            "mounted=[\(mounted)] gen=\(handoffGeneration) currentWorkspace=\(currentRecord?.workspace.id.uuidString.prefix(5) ?? "nil")"
    }
#endif

    init(cardID: UUID, boardID: UUID, cardTitle: String) {
        self.cardID = cardID
        self.boardID = boardID
        self.cardTitle = cardTitle
        _mountedCardIds = State(initialValue: [cardID])
        _previousSelectedCardId = State(initialValue: cardID)
    }

    var body: some View {
        // Use the read-only lookup to avoid mutating @Observable state during body evaluation.
        // The record is created in onAppear/onChange and cached in cachedRecord.
        let currentRecord = cachedRecord ?? terminalManager.existingWorkspaceRecord(for: cardID)
        let effectiveRetiringCardId = retiringCardId ?? inferredRetiringCardId

        ZStack {
            if let currentRecord {
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
        }
        .onAppear {
            // Create the record outside of body evaluation to avoid @Observable mutation cascades
            let record = terminalManager.workspaceRecord(for: cardID, boardID: boardID, cardTitle: cardTitle)
            cachedRecord = record
#if DEBUG
            dlog("deck.appear \(debugMountedSummary(record))")
#endif
            terminalManager.activateWorkspace(for: record.cardID)
            terminalManager.completeCardHandoff(
                retiringCardID: nil,
                selectedCardID: record.cardID,
                reason: "deck_appear"
            )
            reconcileMountedCardIds(selectedCardID: record.cardID)
        }
        .onChange(of: cardID) { _, newValue in
#if DEBUG
            dlog(
                "deck.cardChange from=\(previousSelectedCardId?.uuidString.prefix(5) ?? "nil") " +
                "to=\(newValue.uuidString.prefix(5)) mounted=\(mountedCardIds.map { String($0.uuidString.prefix(5)) })"
            )
#endif

            // If a previous handoff is still pending, cancel it without running
            // the full completeCardHandoff (which would hide portals and suspend
            // surfaces that may be needed moments later). The debounced task will
            // start a fresh handoff from the correct previous card.
            if retiringCardId != nil {
                handoffFallbackTask?.cancel()
                handoffFallbackTask = nil
                retiringCardId = nil
            }

            // Defer ALL work (including workspace record creation) behind a debounce.
            // Creating a workspace record eagerly for every intermediate card during rapid
            // switching spawns terminal surfaces that are immediately suspended, causing
            // Ghostty to destroy and recreate shells in a tight loop until SIGTERM.
            cardSwitchDebounceTask?.cancel()
            cardSwitchDebounceTask = Task {
                try? await Task.sleep(nanoseconds: 16_000_000) // ~1 frame
                guard !Task.isCancelled else { return }
                let record = terminalManager.workspaceRecord(for: newValue, boardID: boardID, cardTitle: cardTitle)
                cachedRecord = record
                startCardHandoffIfNeeded(newSelectedCardID: newValue)
                reconcileMountedCardIds(selectedCardID: newValue)
            }
        }
        .onChange(of: cardTitle) { _, newValue in
            let record = terminalManager.workspaceRecord(for: cardID, boardID: boardID, cardTitle: newValue)
            cachedRecord = record
        }
        .onDisappear {
#if DEBUG
            dlog("deck.disappear \(debugMountedSummary(cachedRecord))")
#endif
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
#if DEBUG
            dlog("deck.handoff.skip \(debugMountedSummary()) reason=no_handoff")
#endif
            return
        }

        handoffGeneration &+= 1
        let generation = handoffGeneration
        retiringCardId = oldSelectedCardID
#if DEBUG
        dlog(
            "deck.handoff.start from=\(oldSelectedCardID.uuidString.prefix(5)) to=\(newSelectedCardID.uuidString.prefix(5)) " +
            "\(debugMountedSummary())"
        )
#endif
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
#if DEBUG
                dlog("deck.handoff.timeout \(debugMountedSummary()) generation=\(generation)")
#endif
                completeCardHandoff(reason: "timeout")
            }
        }
    }

    private func completeCardHandoffIfNeeded(focusedCardID: UUID, reason: String) {
        guard focusedCardID == cardID else { return }
        guard retiringCardId != nil else { return }
#if DEBUG
        dlog(
            "deck.handoff.completeIfNeeded focused=\(focusedCardID.uuidString.prefix(5)) " +
            "reason=\(reason) \(debugMountedSummary())"
        )
#endif
        completeCardHandoff(reason: reason)
    }

    private func completeCardHandoff(reason: String) {
        handoffFallbackTask?.cancel()
        handoffFallbackTask = nil

        let retiring = retiringCardId
#if DEBUG
        dlog(
            "deck.handoff.complete.begin retiring=\(retiring?.uuidString.prefix(5) ?? "nil") " +
            "reason=\(reason) \(debugMountedSummary())"
        )
#endif
        terminalManager.completeCardHandoff(
            retiringCardID: retiring,
            selectedCardID: cardID,
            reason: reason
        )
        retiringCardId = nil
        reconcileMountedCardIds(selectedCardID: cardID)
#if DEBUG
        dlog("deck.handoff.complete.end reason=\(reason) \(debugMountedSummary())")
#endif
    }

    private func reconcileMountedCardIds(selectedCardID: UUID) {
        var nextMountedCardIds = [selectedCardID]

        if let retiringCardId,
           retiringCardId != selectedCardID,
           terminalManager.record(forWorkspaceID: retiringCardId) != nil {
            nextMountedCardIds.append(retiringCardId)
        }

        mountedCardIds = nextMountedCardIds
#if DEBUG
        let mounted = nextMountedCardIds.map { String($0.uuidString.prefix(5)) }.joined(separator: ",")
        dlog(
            "deck.mounted.reconcile selected=\(selectedCardID.uuidString.prefix(5)) " +
            "retiring=\(retiringCardId?.uuidString.prefix(5) ?? "nil") mounted=[\(mounted)]"
        )
#endif
    }

    private func teardownDeck() {
        cardSwitchDebounceTask?.cancel()
        cardSwitchDebounceTask = nil
        handoffFallbackTask?.cancel()
        handoffFallbackTask = nil
#if DEBUG
        dlog("deck.teardown.begin \(debugMountedSummary())")
#endif

        for mountedCardID in mountedCardIds {
            terminalManager.hidePortalViews(for: mountedCardID)
            terminalManager.suspendWorkspaceIfPossible(for: mountedCardID)
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
#if DEBUG
        dlog("deck.teardown.end \(debugMountedSummary())")
#endif
    }
}

private extension CardWorkspaceDeckView {
    struct MountedRecord {
        let record: TerminalManager.WorkspaceRecord
    }
}
