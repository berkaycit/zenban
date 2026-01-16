//
//  GhosttyTerminalView.swift
//  aizen
//
//  NSView subclass that integrates Ghostty terminal rendering
//

import AppKit
import Metal
import OSLog
import UniformTypeIdentifiers

/// NSView that embeds a Ghostty terminal surface with Metal rendering
///
/// This view handles:
/// - Metal layer setup for terminal rendering
/// - Input forwarding (keyboard, mouse, scroll)
/// - Focus management
/// - Surface lifecycle management
@MainActor
class GhosttyTerminalView: NSView {
    // MARK: - Properties

    private var ghosttyApp: ghostty_app_t?
    private weak var ghosttyAppWrapper: Ghostty.App?
    internal var surface: Ghostty.Surface?
    private var surfaceReference: Ghostty.SurfaceReference?
    private let worktreePath: String
    private let paneId: String?
    private let initialCommand: String?

    var cardID: UUID?
    var boardID: UUID?
    var cardTitle: String = ""

    /// Callback invoked when the terminal process exits
    var onProcessExit: (() -> Void)?

    /// Callback invoked when the terminal title changes
    var onTitleChange: ((String) -> Void)?
    
    /// Callback when the surface has produced its first layout/draw (used to hide loading UI)
    var onReady: (() -> Void)?
    
    /// Callback for OSC 9;4 progress reports
    var onProgressReport: ((GhosttyProgressState, Int?) -> Void)?
    private var didSignalReady = false

    /// Callback when agent task completes
    var onTaskCompleted: ((UUID, UUID) -> Void)?

    /// Callback when agent resumes from idle
    var onAgentResumed: ((UUID, UUID) -> Void)?

    /// Whether the shell is ready to receive input
    private var isShellReady = false

    /// Command to send when shell becomes ready
    private var pendingCommand: String?

    /// Whether terminal has been focused (prevents false positives on init)
    private var hasBeenFocused = false

    // MARK: - State Machine

    enum TerminalState: Equatable {
        case shell
        case agentActive
        case agentIdle
    }

    enum TerminalEvent {
        case agentLaunched
        case commandFinished
        case newMessageSent
        case agentExited
    }

    private(set) var state: TerminalState = .shell

    /// Cell size in points for row-to-pixel conversion (used by scroll view)
    var cellSize: NSSize = .zero

    /// Current scrollbar state from Ghostty core (used by scroll view)
    var scrollbar: Ghostty.Action.Scrollbar?

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "win.aizen.app", category: "GhosttyTerminal")

    // MARK: - Handler Components

    private var inputHandler: GhosttyInputHandler!
    private let renderingSetup = GhosttyRenderingSetup()

    /// Observation for appearance changes
    private var appearanceObservation: NSKeyValueObservation?

    // MARK: - Initialization

    /// Create a new Ghostty terminal view
    ///
    /// - Parameters:
    ///   - frame: The initial frame for the view
    ///   - worktreePath: Working directory for the terminal session
    ///   - ghosttyApp: The shared Ghostty app instance (C pointer)
    ///   - appWrapper: The Ghostty.App wrapper for surface tracking (optional)
    ///   - paneId: Unique identifier for this pane (used for tmux session persistence)
    ///   - command: Optional command to run instead of default shell
    init(frame: NSRect, worktreePath: String, ghosttyApp: ghostty_app_t, appWrapper: Ghostty.App? = nil, paneId: String? = nil, command: String? = nil) {
        self.worktreePath = worktreePath
        self.ghosttyApp = ghosttyApp
        self.ghosttyAppWrapper = appWrapper
        self.paneId = paneId
        self.initialCommand = command

        // Use a reasonable default size if frame is zero
        let initialFrame = frame.width > 0 && frame.height > 0 ? frame : NSRect(x: 0, y: 0, width: 800, height: 600)
        super.init(frame: initialFrame)

        // Register this view as valid for callback safety
        Ghostty.App.registerTerminalView(self)

        // Initialize handlers before setup
        self.inputHandler = GhosttyInputHandler(view: self, surface: nil)

        setupLayer()
        setupSurface()
        setupTrackingArea()
        setupAppearanceObservation()
        setupFrameObservation()
        registerForDraggedTypes([.fileURL])

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self, !self.isShellReady else { return }
            Ghostty.logger.info("Shell readiness fallback triggered")
            self.handleShellReady()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    deinit {
        // Unregister from validity registry (thread-safe, can be called from deinit)
        Ghostty.App.unregisterTerminalView(self)

        // Surface cleanup happens via Surface's deinit
        // Note: Cannot access @MainActor properties in deinit
        // Tracking areas are automatically cleaned up by NSView
        // Appearance observation is automatically invalidated

        // Surface reference cleanup needs to happen on main actor
        // We capture the values before the Task to avoid capturing self
        let wrapper = self.ghosttyAppWrapper
        let ref = self.surfaceReference
        if let wrapper = wrapper, let ref = ref {
            Task { @MainActor in
                wrapper.unregisterSurface(ref)
            }
        }
    }

    // MARK: - Setup

    /// Configure the Metal-backed layer for terminal rendering
    private func setupLayer() {
        renderingSetup.setupLayer(for: self)
    }

    /// Create and configure the Ghostty surface
    private func setupSurface() {
        guard let app = ghosttyApp else {
            Self.logger.error("Cannot create surface: ghostty_app_t is nil")
            return
        }

        guard let cSurface = renderingSetup.setupSurface(
            view: self,
            ghosttyApp: app,
            worktreePath: worktreePath,
            initialBounds: bounds,
            window: window,
            paneId: paneId,
            command: initialCommand
        ) else {
            return
        }

        // Wrap in Swift Surface class
        self.surface = Ghostty.Surface(cSurface: cSurface)

        // Update handlers with surface
        inputHandler.updateSurface(self.surface)

        // Register surface with app wrapper for config update tracking
        if let wrapper = ghosttyAppWrapper {
            self.surfaceReference = wrapper.registerSurface(cSurface)
        }
    }

    /// Setup mouse tracking area for the entire view
    private func setupTrackingArea() {
        let options: NSTrackingArea.Options = [
            .mouseEnteredAndExited,
            .mouseMoved,
            .inVisibleRect,
            .activeAlways  // Track even when not focused
        ]

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: options,
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }

    /// Setup observation for system appearance changes (light/dark mode)
    private func setupAppearanceObservation() {
        appearanceObservation = renderingSetup.setupAppearanceObservation(for: self, surface: surface)
    }

    private func setupFrameObservation() {
        // We rely on layout() + updateLayout to resize the surface.
        self.postsFrameChangedNotifications = false
    }

    // MARK: - NSView Overrides

    override var acceptsFirstResponder: Bool {
        return true
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            hasBeenFocused = true
            if let surface = surface?.unsafeCValue {
                ghostty_surface_set_focus(surface, true)
            }
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result, let surface = surface?.unsafeCValue {
            ghostty_surface_set_focus(surface, false)
        }
        return result
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        // Remove old tracking areas
        trackingAreas.forEach { removeTrackingArea($0) }

        // Recreate with current bounds
        setupTrackingArea()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        renderingSetup.updateBackingProperties(view: self, surface: surface?.unsafeCValue, window: window)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Single refresh when view moves to window
        if window != nil {
            DispatchQueue.main.async { [weak self] in
                self?.forceRefresh()
            }
        }
    }

    // Track last size sent to Ghostty to avoid redundant updates
    private var lastSurfaceSize: CGSize = .zero

    // Override safe area insets to use full available space, including rounded corners
    // This matches Ghostty's SurfaceScrollView implementation
    override var safeAreaInsets: NSEdgeInsets {
        return NSEdgeInsetsZero
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)

        // Force layout to be called to fix up subviews
        // This matches Ghostty's SurfaceScrollView.setFrameSize
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let didUpdate = renderingSetup.updateLayout(
            view: self,
            metalLayer: layer as? CAMetalLayer,
            surface: surface?.unsafeCValue,
            lastSize: &lastSurfaceSize
        )
        if didUpdate && !didSignalReady {
            didSignalReady = true
            onReady?()
        }
    }

    // MARK: - Keyboard Input

    override func keyDown(with event: NSEvent) {
        inputHandler.handleKeyDown(with: event) { [weak self] events in
            self?.interpretKeyEvents(events)
        }
    }

    override func keyUp(with event: NSEvent) {
        inputHandler.handleKeyUp(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        inputHandler.handleFlagsChanged(with: event)
    }

    override func doCommand(by selector: Selector) {
        // Override to suppress NSBeep when interpretKeyEvents encounters unhandled commands
        // Without this, keys like delete at beginning of line, cmd+c with no selection, etc. cause beeps
        // Terminal handles all input via Ghostty, so we silently ignore unhandled commands
    }

    // MARK: - Mouse Input

    override func mouseDown(with event: NSEvent) {
        inputHandler.handleMouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        inputHandler.handleMouseUp(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        inputHandler.handleRightMouseDown(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        inputHandler.handleRightMouseUp(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        inputHandler.handleOtherMouseDown(with: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        inputHandler.handleOtherMouseUp(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        inputHandler.handleMouseMoved(with: event, viewFrame: frame) { [weak self] point, view in
            self?.convert(point, from: view) ?? .zero
        }
    }

    override func mouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        inputHandler.handleMouseEntered(with: event, viewFrame: frame) { [weak self] point, view in
            self?.convert(point, from: view) ?? .zero
        }
    }

    override func mouseExited(with event: NSEvent) {
        inputHandler.handleMouseExited(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        inputHandler.handleScrollWheel(with: event)
    }

    // MARK: - Public Methods

    func send(text: String) {
        guard let surface = surface else { return }
        surface.sendText(text)
    }

    func sendWhenReady(_ command: String) {
        if isShellReady {
            send(text: command)
        } else {
            pendingCommand = command
        }
    }

    func terminate() {
        guard let surface = surface?.unsafeCValue else { return }
        ghostty_surface_request_close(surface)
    }

    // MARK: - Signal Handlers (called from Ghostty.App)

    func handleCommandFinished() {
        guard state == .agentActive else { return }
        transition(event: .commandFinished)
    }

    func handleShellReady() {
        guard !isShellReady else { return }
        isShellReady = true
        executePendingCommandIfNeeded()
    }

    // MARK: - Agent Notification (called from TerminalManager)

    func notifyAgentLaunched() {
        transition(event: .agentLaunched)
    }

    func notifyNewMessageSent() {
        transition(event: .newMessageSent)
    }

    func notifyAgentExited() {
        transition(event: .agentExited)
    }

    // MARK: - State Machine

    private func transition(event: TerminalEvent) {
        let newState: TerminalState? = switch (state, event) {
        case (.shell, .agentLaunched): .agentActive
        case (.agentActive, .commandFinished): .agentIdle
        case (.agentActive, .agentExited): .shell
        case (.agentIdle, .newMessageSent): .agentActive
        case (.agentIdle, .agentExited): .shell
        default: nil
        }

        if let newState = newState, newState != state {
            let oldState = state
            state = newState
            handleStateChange(from: oldState, to: newState)
        }
    }

    private func handleStateChange(from oldState: TerminalState, to newState: TerminalState) {
        switch (oldState, newState) {
        case (.agentActive, .agentIdle):
            triggerTaskCompleted()
        case (.agentIdle, .agentActive):
            triggerAgentResumed()
        default:
            break
        }
    }

    private func triggerTaskCompleted() {
        guard hasBeenFocused else { return }
        guard let cardID = cardID, let boardID = boardID else { return }
        onTaskCompleted?(cardID, boardID)
    }

    private func triggerAgentResumed() {
        guard let cardID = cardID, let boardID = boardID else { return }
        onAgentResumed?(cardID, boardID)
    }

    private func executePendingCommandIfNeeded() {
        guard let command = pendingCommand else { return }
        pendingCommand = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.send(text: command)
        }
    }

    // MARK: - Process Lifecycle

    /// Check if the terminal process has exited
    var processExited: Bool {
        guard let surface = surface?.unsafeCValue else { return true }
        return ghostty_surface_process_exited(surface)
    }

    /// Check if closing this terminal needs confirmation
    var needsConfirmQuit: Bool {
        guard let surface = surface else { return false }
        return surface.needsConfirmQuit
    }

    /// Get current terminal grid size
    func terminalSize() -> Ghostty.Surface.TerminalSize? {
        guard let surface = surface else { return nil }
        return surface.terminalSize()
    }

    /// Force the terminal surface to refresh/redraw
    /// Useful after tmux reattaches or when view becomes visible
    func forceRefresh() {
        guard let surface = surface?.unsafeCValue else { return }

        // Force a size update to trigger tmux redraw
        let scaledSize = convertToBacking(bounds.size)
        ghostty_surface_set_size(
            surface,
            UInt32(scaledSize.width),
            UInt32(scaledSize.height)
        )

        ghostty_surface_refresh(surface)
        ghostty_surface_draw(surface)

        // Trigger app tick to process any pending updates
        ghosttyAppWrapper?.appTick()

        // Force Metal layer to redraw
        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.setNeedsDisplay()
        }
        layer?.setNeedsDisplay()
        needsDisplay = true
        needsLayout = true
        displayIfNeeded()
    }
}

// MARK: - NSTextInputClient Implementation

/// NSTextInputClient protocol conformance for basic text input
extension GhosttyTerminalView: NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        guard let str = string as? String else { return }
        send(text: str)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        // IME not supported
    }

    func unmarkText() {
        // IME not supported
    }

    func selectedRange() -> NSRange {
        return NSRange(location: NSNotFound, length: 0)
    }

    func markedRange() -> NSRange {
        return NSRange(location: NSNotFound, length: 0)
    }

    func hasMarkedText() -> Bool {
        return false
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        return nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        return []
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        return .zero
    }

    func characterIndex(for point: NSPoint) -> Int {
        return 0
    }
}

// MARK: - Drag and Drop

extension GhosttyTerminalView {

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) else {
            return []
        }
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) else {
            return []
        }
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty else {
            return false
        }

        let escapedPaths = urls.map { shellEscapedPath($0.path) }
        let text = escapedPaths.joined(separator: " ")

        send(text: text)
        return true
    }

    private func shellEscapedPath(_ path: String) -> String {
        let specialChars = CharacterSet(charactersIn: " \t'\"\\$`!#&*()[]{}|;<>?~")
        if path.unicodeScalars.allSatisfy({ !specialChars.contains($0) }) {
            return path
        }
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}
