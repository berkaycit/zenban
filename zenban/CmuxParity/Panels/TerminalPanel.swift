import Foundation
import Combine
import AppKit
import Bonsplit

/// TerminalPanel wraps an existing TerminalSurface and conforms to the Panel protocol.
/// This allows TerminalSurface to be used within the bonsplit-based layout system.
@MainActor
final class TerminalPanel: Panel, ObservableObject {
    enum MountState: String {
        case suspended
        case waitingForWindow
        case waitingForLayout
        case mounted
        case detaching
    }

    let id: UUID
    let panelType: PanelType = .terminal

    /// The underlying terminal surface
    let surface: TerminalSurface

    /// The workspace ID this panel belongs to
    private(set) var workspaceId: UUID

    /// Published title from the terminal process
    @Published private(set) var title: String = "Terminal"

    /// Published directory from the terminal
    @Published private(set) var directory: String = ""

    /// Search state for find functionality
    @Published var searchState: TerminalSurface.SearchState? {
        didSet {
            surface.searchState = searchState
        }
    }

    /// Mount revision for the hosted view. Bump only when a terminal transitions back into a
    /// mounted state and the portal binding actually needs to be refreshed.
    @Published var viewReattachToken: UInt64 = 0
    @Published private(set) var mountState: MountState = .waitingForWindow

    private var cancellables = Set<AnyCancellable>()
    private var lastMountRevisionSignature: String?

    var displayTitle: String {
        title.isEmpty ? "Terminal" : title
    }

    var displayIcon: String? {
        "terminal.fill"
    }

    var isDirty: Bool {
        // Bonsplit's "dirty" indicator is a very small dot in the tab strip.
        //
        // For terminals, `ghostty_surface_needs_confirm_quit` is driven by shell integration
        // heuristics and can be transiently (or permanently) wrong, which results in a dot
        // showing on every new terminal. That reads as a notification/alert and is misleading.
        //
        // We still honor `needsConfirmClose()` when actually closing a panel; we just don't
        // surface it as a tab-level dirty indicator.
        false
    }

    /// The hosted NSView for embedding in SwiftUI
    var hostedView: GhosttySurfaceScrollView {
        surface.hostedView
    }

    var tmuxSessionID: String {
        surface.tmuxSessionID
    }

    private var hasUsablePortalLayout: Bool {
        hostedView.bounds.width > 1 && hostedView.bounds.height > 1
    }

    init(workspaceId: UUID, surface: TerminalSurface) {
        self.id = surface.id
        self.workspaceId = workspaceId
        self.surface = surface

        // Subscribe to surface's search state changes
        surface.$searchState
            .sink { [weak self] state in
                if self?.searchState !== state {
                    self?.searchState = state
                }
            }
            .store(in: &cancellables)
    }

    /// Create a new terminal panel with a fresh surface
    convenience init(
        workspaceId: UUID,
        context: ghostty_surface_context_e = GHOSTTY_SURFACE_CONTEXT_SPLIT,
        configTemplate: ghostty_surface_config_s? = nil,
        workingDirectory: String? = nil,
        additionalEnvironment: [String: String] = [:],
        portOrdinal: Int = 0
    ) {
        let surface = TerminalSurface(
            tabId: workspaceId,
            context: context,
            configTemplate: configTemplate,
            workingDirectory: workingDirectory,
            additionalEnvironment: additionalEnvironment
        )
        surface.portOrdinal = portOrdinal
        self.init(workspaceId: workspaceId, surface: surface)
    }

    func updateTitle(_ newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && title != trimmed {
            title = trimmed
        }
    }

    func updateDirectory(_ newDirectory: String) {
        let trimmed = newDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && directory != trimmed {
            directory = trimmed
        }
    }

    func updateWorkspaceId(_ newWorkspaceId: UUID) {
        workspaceId = newWorkspaceId
        surface.updateWorkspaceId(newWorkspaceId)
    }

    func focus() {
#if DEBUG
        dlog(
            "panel.focus panel=\(id.uuidString.prefix(5)) workspace=\(workspaceId.uuidString.prefix(5)) " +
            "tmux=\(tmuxSessionID.prefix(8)) suspended=\(surface.isSuspended ? 1 : 0) " +
            "inWindow=\(hostedView.window != nil ? 1 : 0) hidden=\(hostedView.isHidden ? 1 : 0)"
        )
#endif
        surface.setFocus(true)
        // `unfocus()` force-disables active state to stop stale retries from stealing focus.
        // Re-enable it immediately for explicit focus requests (socket/UI) so ensureFocus can run.
        hostedView.setActive(true)
        hostedView.ensureFocus(for: workspaceId, surfaceId: id)
    }

    func unfocus() {
#if DEBUG
        dlog(
            "panel.unfocus panel=\(id.uuidString.prefix(5)) workspace=\(workspaceId.uuidString.prefix(5)) " +
            "tmux=\(tmuxSessionID.prefix(8)) firstResponder=\(hostedView.isSurfaceViewFirstResponder() ? 1 : 0)"
        )
#endif
        surface.setFocus(false)
        // Cancel any pending focus work items so an inactive terminal can't steal first responder
        // back from another surface (notably WKWebView) during rapid focus changes in tests.
        //
        // Also flip the hosted view's active state immediately: SwiftUI focus propagation can lag
        // by a runloop tick, and `requestFocus` retries that are already executing can otherwise
        // schedule new work items that fire after we navigate away.
        hostedView.setActive(false)
    }

    func close() {
        // The surface will be cleaned up by its deinit
        // Detach from the window portal on real close so stale hosted views
        // cannot remain above browser panes after split close.
        surface.beginPortalCloseLifecycle(reason: "panel.close")
#if DEBUG
        let frame = String(format: "%.1fx%.1f", hostedView.frame.width, hostedView.frame.height)
        let bounds = String(format: "%.1fx%.1f", hostedView.bounds.width, hostedView.bounds.height)
        dlog(
            "surface.panel.close.begin panel=\(id.uuidString.prefix(5)) " +
            "workspace=\(workspaceId.uuidString.prefix(5)) runtimeSurface=\(surface.surface != nil ? 1 : 0) " +
            "inWindow=\(hostedView.window != nil ? 1 : 0) hasSuperview=\(hostedView.superview != nil ? 1 : 0) " +
            "hidden=\(hostedView.isHidden ? 1 : 0) frame=\(frame) bounds=\(bounds)"
        )
#endif
        unfocus()
        hostedView.setVisibleInUI(false)
        _ = requestMountTransition(to: .detaching, reason: "panel.close")
        TerminalWindowPortalRegistry.detach(hostedView: hostedView)
#if DEBUG
        dlog(
            "surface.panel.close.end panel=\(id.uuidString.prefix(5)) " +
            "inWindow=\(hostedView.window != nil ? 1 : 0) hasSuperview=\(hostedView.superview != nil ? 1 : 0) " +
            "hidden=\(hostedView.isHidden ? 1 : 0)"
        )
#endif
        surface.closePermanently()
    }

    private func mountRevisionSignature(for state: MountState) -> String {
        [
            state.rawValue,
            "runtime=\(surface.runtimeState.rawValue)",
            "window=\(hostedView.window != nil ? 1 : 0)",
            "superview=\(hostedView.superview != nil ? 1 : 0)",
            "visible=\(hostedView.isVisibleInUI ? 1 : 0)",
            "layout=\(hasUsablePortalLayout ? 1 : 0)",
            "surface=\(surface.surface != nil ? 1 : 0)",
        ].joined(separator: "|")
    }

    func resolvedMountState(visibleInUI: Bool? = nil) -> MountState {
        let visible = visibleInUI ?? hostedView.isVisibleInUI
        if surface.runtimeState == .closing {
            return .detaching
        }
        if surface.isSuspended || !visible {
            return .suspended
        }
        if hostedView.window == nil {
            return .waitingForWindow
        }
        if !hasUsablePortalLayout {
            return .waitingForLayout
        }
        return .mounted
    }

    @discardableResult
    func requestMountTransition(
        to nextState: MountState? = nil,
        visibleInUI: Bool? = nil,
        reason: String,
        forcePortalRebind: Bool = false
    ) -> Bool {
        let resolvedState = nextState ?? resolvedMountState(visibleInUI: visibleInUI)
        let previousState = mountState
        let stateChanged = previousState != resolvedState
        if stateChanged {
            mountState = resolvedState
        }

        var didBumpRevision = false
        let shouldBumpRevision =
            forcePortalRebind &&
            resolvedState == .mounted &&
            surface.runtimeState == .live

        if shouldBumpRevision {
            let signature = mountRevisionSignature(for: resolvedState)
            if lastMountRevisionSignature != signature {
                lastMountRevisionSignature = signature
                viewReattachToken &+= 1
                didBumpRevision = true
            } else {
#if DEBUG
                dlog(
                    "panel.mount.skip panel=\(id.uuidString.prefix(5)) workspace=\(workspaceId.uuidString.prefix(5)) " +
                    "reason=\(reason) state=\(resolvedState.rawValue) skip=duplicateMountedSignature " +
                    "token=\(viewReattachToken) signature=\(signature)"
                )
#endif
            }
        } else if resolvedState != .mounted {
            lastMountRevisionSignature = nil
        }

#if DEBUG
        if stateChanged || didBumpRevision {
            dlog(
                "panel.mount panel=\(id.uuidString.prefix(5)) workspace=\(workspaceId.uuidString.prefix(5)) " +
                "reason=\(reason) state=\(previousState.rawValue)->\(resolvedState.rawValue) " +
                "token=\(viewReattachToken) rebind=\(didBumpRevision ? 1 : 0) tmux=\(tmuxSessionID.prefix(8)) " +
                "window=\(hostedView.window != nil ? 1 : 0) superview=\(hostedView.superview != nil ? 1 : 0) " +
                "visible=\(hostedView.isVisibleInUI ? 1 : 0) layout=\(hasUsablePortalLayout ? 1 : 0) " +
                "surfaceLoaded=\(surface.surface != nil ? 1 : 0)"
            )
        }
#endif
        return stateChanged || didBumpRevision
    }

    @discardableResult
    func requestMountedPortalRebind(reason: String, visibleInUI: Bool? = nil) -> Bool {
        requestMountTransition(
            visibleInUI: visibleInUI,
            reason: reason,
            forcePortalRebind: true
        )
    }

    // MARK: - Terminal-specific methods

    func sendText(_ text: String) {
        surface.sendText(text)
    }

    func performBindingAction(_ action: String) -> Bool {
        surface.performBindingAction(action)
    }

    func hasSelection() -> Bool {
        surface.hasSelection()
    }

    func needsConfirmClose() -> Bool {
        surface.needsConfirmClose()
    }

    func triggerFlash() {
        hostedView.triggerFlash()
    }

    func applyWindowBackgroundIfActive() {
        surface.applyWindowBackgroundIfActive()
    }

    func suspend() {
#if DEBUG
        dlog(
            "panel.suspend.begin panel=\(id.uuidString.prefix(5)) workspace=\(workspaceId.uuidString.prefix(5)) " +
            "tmux=\(tmuxSessionID.prefix(8)) inWindow=\(hostedView.window != nil ? 1 : 0) " +
            "hasSuperview=\(hostedView.superview != nil ? 1 : 0) hidden=\(hostedView.isHidden ? 1 : 0) " +
            "surfaceLoaded=\(surface.surface != nil ? 1 : 0)"
        )
#endif
        hostedView.setActive(false)
        hostedView.setVisibleInUI(false)
        _ = requestMountTransition(to: .suspended, reason: "panel.suspend")
        surface.suspendRuntimeSurface()
        TerminalWindowPortalRegistry.detach(hostedView: hostedView)
#if DEBUG
        dlog(
            "panel.suspend.end panel=\(id.uuidString.prefix(5)) workspace=\(workspaceId.uuidString.prefix(5)) " +
            "tmux=\(tmuxSessionID.prefix(8)) inWindow=\(hostedView.window != nil ? 1 : 0) " +
            "hasSuperview=\(hostedView.superview != nil ? 1 : 0) hidden=\(hostedView.isHidden ? 1 : 0) " +
            "surfaceLoaded=\(surface.surface != nil ? 1 : 0)"
        )
#endif
    }

    func resume() {
        let hostedView = self.hostedView
#if DEBUG
        dlog(
            "panel.resume.begin panel=\(id.uuidString.prefix(5)) workspace=\(workspaceId.uuidString.prefix(5)) " +
            "tmux=\(tmuxSessionID.prefix(8)) inWindow=\(hostedView.window != nil ? 1 : 0) " +
            "hasSuperview=\(hostedView.superview != nil ? 1 : 0) hidden=\(hostedView.isHidden ? 1 : 0) " +
            "surfaceLoaded=\(surface.surface != nil ? 1 : 0)"
        )
#endif
        hostedView.suppressReparentFocus()
        surface.resumeRuntimeSurfaceIfNeeded()
        let shouldRequestPortalRebind =
            hostedView.window != nil &&
            hasUsablePortalLayout &&
            (hostedView.superview == nil || surface.surface == nil)
        _ = requestMountTransition(
            reason: "panel.resume",
            forcePortalRebind: shouldRequestPortalRebind
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            hostedView.clearSuppressReparentFocus()
#if DEBUG
            dlog(
                "panel.resume.clearSuppress panel=\(self.id.uuidString.prefix(5)) " +
                "workspace=\(self.workspaceId.uuidString.prefix(5)) tmux=\(self.tmuxSessionID.prefix(8))"
            )
#endif
        }
#if DEBUG
        dlog(
            "panel.resume.end panel=\(id.uuidString.prefix(5)) workspace=\(workspaceId.uuidString.prefix(5)) " +
            "tmux=\(tmuxSessionID.prefix(8)) token=\(viewReattachToken) " +
            "surfaceLoaded=\(surface.surface != nil ? 1 : 0)"
        )
#endif
    }
}
